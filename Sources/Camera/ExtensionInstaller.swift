import AppKit
import Observation
import SystemExtensions
import os

/// Installs Vaux Camera, the camera extension bundled in
/// Contents/Library/SystemExtensions, and tracks it: installed or not,
/// approved by the user, and the same build as this app's.
@MainActor @Observable
final class ExtensionInstaller: NSObject {
    enum State: Equatable {
        case checking
        case notInstalled
        /// An install, update or uninstall is in flight.
        case working(String)
        /// Installed; the user has to turn it on in System Settings.
        case awaitingApproval
        /// The user turned it off in System Settings.
        case disabled
        case ready
        case restartNeeded
        case failed(String)
    }

    /// Vaux's own ID plus ".camera": Vaux Dev installs its own.
    nonisolated static let extensionID = (Bundle.main.bundleIdentifier ?? "dev.imathis.vaux") + ".camera"

    /// Login Items & Extensions → Camera Extensions.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.cmio.extension-point")!

    /// The extension build inside this copy of Vaux.
    static let bundledBuild: String = {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(extensionID).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }()

    /// macOS only activates extensions from apps in /Applications.
    static let isInApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")

    private(set) var state = State.checking
    /// The build macOS has installed, if any.
    private(set) var installedBuild: String?
    /// This process installed or updated Vaux Camera. It can't see the
    /// new device (only processes started afterward can), so Vaux
    /// relaunches.
    private(set) var changedExtension = false

    var needsUpdate: Bool { installedBuild.map { $0 != Self.bundledBuild } ?? false }

    /// Asking macOS, or installing, updating or uninstalling.
    var isBusy: Bool {
        switch state {
        case .checking, .working: true
        default: false
        }
    }

    @ObservationIgnored private let log = Logger(subsystem: "dev.imathis.vaux", category: "installer")
    /// The install or uninstall in flight. Its callbacks own the state until
    /// it ends; status checks in the meantime only note the installed build.
    @ObservationIgnored private var pending: OSSystemExtensionRequest?
    /// The pending request installs or updates (rather than uninstalls).
    @ObservationIgnored private var pendingIsActivation = false
    @ObservationIgnored private var statusRequest: OSSystemExtensionRequest?
    /// Called once an uninstall ends: true if it went (or goes at restart).
    @ObservationIgnored private var uninstalled: ((Bool) -> Void)?
    /// The pending activation brings an older build up to date only so it
    /// can be removed.
    @ObservationIgnored private var replacingToRemove = false

    override init() {
        super.init()
        do {
            try OSSystemExtensionsWorkspace.shared.addObserver(self)
        } catch {
            log.error("Can't watch for approval: \(error)")
        }
        refresh()
    }

    /// Installs Vaux Camera, or replaces it with this app's build.
    func install() {
        guard Self.isInApplications else {
            state = .failed(Self.notInApplications)
            return
        }
        submit(
            .activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main),
            installedBuild == nil ? "Installing \(CameraSpec.name)…" : "Updating \(CameraSpec.name)…",
            activation: true
        )
    }

    /// Removes Vaux Camera; `done` hears whether it went. macOS removes only
    /// the build inside this app, so an older one installed (an update not
    /// taken) is replaced with it first; replacing needs no approval.
    func uninstall(then done: @escaping (Bool) -> Void) {
        uninstalled = done
        if needsUpdate {
            replacingToRemove = true
            submit(
                .activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main),
                "Uninstalling \(CameraSpec.name)…",
                activation: true
            )
        } else {
            submitRemoval()
        }
    }

    private func submitRemoval() {
        submit(
            .deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main),
            "Uninstalling \(CameraSpec.name)…",
            activation: false
        )
    }

    /// Opens Camera Extensions in System Settings, where the user turns
    /// Vaux on.
    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    /// Asks macOS for the extension's state.
    private func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        statusRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func submit(_ request: OSSystemExtensionRequest, _ message: String, activation: Bool) {
        log.info("\(message, privacy: .public)")
        state = .working(message)
        request.delegate = self
        pending = request
        pendingIsActivation = activation
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private static let notInApplications = "\(VauxCamera.appName) has to be in the Applications folder to install its camera. Move it there and open it again."

    private static func message(for error: any Error) -> String {
        let code = (error as NSError).code
        let text = switch (error as? OSSystemExtensionError)?.code {
        case .unsupportedParentBundleLocation: notInApplications
        case .forbiddenBySystemPolicy: "This Mac's settings don't allow camera extensions, possibly because of a management profile."
        case .authorizationRequired: "macOS needs an administrator to approve this."
        case .missingEntitlement, .codeSignatureInvalid, .validationFailed: "This build of \(VauxCamera.appName) isn't signed to install a camera extension."
        case .extensionNotFound: "\(CameraSpec.name) is missing from this copy of \(VauxCamera.appName). Reinstall \(VauxCamera.appName)."
        default: error.localizedDescription
        }
        return "\(text) (error \(code))"
    }
}

// Requests are made with the main queue, so the delegate is called there.
extension ExtensionInstaller: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        // Replaced builds linger while they uninstall; the live one is the rest.
        let current = properties.first { !$0.isUninstalling }
        installedBuild = current?.bundleVersion
        guard pending == nil else { return }
        guard let current else {
            state = .notInstalled
            return
        }
        // A newer extension in this build isn't installed here: updating
        // restarts Vaux Camera, which drops it from video apps already
        // open, so it's the user's call (see needsUpdate).
        if current.isEnabled {
            state = .ready
        } else if current.isAwaitingUserApproval {
            state = .awaitingApproval
        } else {
            state = .disabled
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing build \(existing.bundleVersion, privacy: .public) with \(replacement.bundleVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .awaitingApproval
        openSettings()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        // Status checks finish here too; only installs and uninstalls matter.
        guard request === pending else { return }
        pending = nil
        if replacingToRemove {
            replacingToRemove = false
            submitRemoval()
            return
        }
        if !pendingIsActivation, let uninstalled {
            self.uninstalled = nil
            uninstalled(true)
        }
        if result == .willCompleteAfterReboot {
            state = .restartNeeded
            return
        }
        if pendingIsActivation { changedExtension = true }
        refresh()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        if request === statusRequest {
            // Never installed: nothing to report.
            log.info("No status: \(error)")
            if pending == nil { state = .notInstalled }
            return
        }
        // A request replaced by a newer one fails too; the newer one reports.
        guard request === pending else { return }
        pending = nil
        log.error("Request failed: \(error)")
        if replacingToRemove, let uninstalled {
            replacingToRemove = false
            self.uninstalled = nil
            uninstalled(false)
            refresh()
            return
        }
        if !pendingIsActivation, let uninstalled {
            // Not installed after all: as good as uninstalled.
            let gone = (error as? OSSystemExtensionError)?.code == .extensionNotFound
            self.uninstalled = nil
            uninstalled(gone)
            if !gone { refresh() }
            return
        }
        state = .failed(Self.message(for: error))
    }
}

// Sees the user turn Vaux Camera on or off in System Settings.
extension ExtensionInstaller: OSSystemExtensionsWorkspaceObserver {
    nonisolated func systemExtensionWillBecomeEnabled(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == Self.extensionID else { return }
        Task { @MainActor in
            self.installedBuild = info.bundleVersion
            if self.pending == nil || self.state == .awaitingApproval { self.state = .ready }
        }
    }

    nonisolated func systemExtensionWillBecomeDisabled(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == Self.extensionID else { return }
        // Also sent when it's first installed, before the user approves.
        Task { @MainActor in
            guard self.pending == nil else { return }
            self.state = self.state == .ready ? .disabled : .awaitingApproval
        }
    }

    nonisolated func systemExtensionWillBecomeInactive(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == Self.extensionID else { return }
        Task { @MainActor in
            guard self.pending == nil else { return }
            self.installedBuild = nil
            self.state = .notInstalled
        }
    }
}
