import AppKit
import Observation
import os

/// Vaux Camera, opt-in: nothing of it runs (no extension, no camera API, no
/// effect keys) until it's turned on. Turned on, Vaux installs the extension
/// and, once it's approved, relaunches, since a process running when the
/// extension starts never sees its device; the fresh Vaux starts the camera
/// side and finishes setup. Turned off, the extension is removed and Vaux
/// relaunches without any of it.
@MainActor @Observable
final class VauxCamera {
    private(set) var isOn = UserDefaults.standard.bool(forKey: AppStorageKey.cameraOn)
    private(set) var installer: ExtensionInstaller?
    /// Overlays, push-ins, combos and their keys: no camera API, so ready as
    /// soon as the camera is on.
    private(set) var effects: Effects?
    /// The camera itself, started once the extension is installed and current.
    private(set) var side: CameraSide?
    private(set) var turningOff = false
    /// Turning off didn't go (cancelled, or macOS refused).
    private(set) var turnOffFailed = false

    @ObservationIgnored private let appState: AppState
    /// Turned on just now: install (or update) once macOS says what's there.
    @ObservationIgnored private var installWhenChecked = false
    @ObservationIgnored private var relaunching = false

    /// What this copy is called, here and in System Settings.
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Vaux"

    /// Relaunched to carry on setting up: Settings reopens on the Camera tab,
    /// and camera access is asked for.
    static let continuingSetup = ProcessInfo.processInfo.arguments.contains(setupArgument)
    private static let setupArgument = "-continueCameraSetup"

    init(appState: AppState) {
        self.appState = appState
        if isOn { start() }
    }

    /// Snapshots: on as far as effects go, with nothing started.
    init(previewing effects: Effects, appState: AppState) {
        self.appState = appState
        isOn = true
        self.effects = effects
    }

    func turnOn() {
        guard !isOn else { return }
        FramesImport.runOnce()
        isOn = true
        UserDefaults.standard.set(true, forKey: AppStorageKey.cameraOn)
        installWhenChecked = true
        start()
    }

    /// Removes Vaux Camera, then relaunches without it. Effects and camera
    /// order are kept for next time.
    func turnOff() {
        guard isOn, !turningOff else { return }
        turningOff = true
        turnOffFailed = false
        let finish: (Bool) -> Void = { [weak self] gone in
            guard let self else { return }
            turningOff = false
            guard gone else {
                turnOffFailed = true
                return
            }
            UserDefaults.standard.set(false, forKey: AppStorageKey.cameraOn)
            Self.relaunch(continuingSetup: false)
        }
        guard let installer else { return finish(true) }
        // Not known yet, mid-install, or awaiting approval: ask macOS to
        // remove it (it says if there's nothing to remove).
        switch installer.state {
        case .notInstalled, .failed: installer.installedBuild == nil ? finish(true) : installer.uninstall(then: finish)
        default: installer.uninstall(then: finish)
        }
    }

    /// Opens a fresh Vaux, then quits this one.
    static func relaunch(continuingSetup: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = continuingSetup ? [setupArgument] : ["-settingsTab", "camera"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func start() {
        installer = ExtensionInstaller()
        effects = Effects(appState: appState)
        follow()
    }

    /// Installs once macOS has said what's there, relaunches after an
    /// install or update, and starts the camera side once it's current.
    private func follow() {
        guard let installer else { return }
        let (state, changed) = withObservationTracking {
            (installer.state, installer.changedExtension)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        if installWhenChecked, state != .checking {
            installWhenChecked = false
            if state == .notInstalled || installer.needsUpdate {
                installer.install()
                return
            }
        }
        guard state == .ready else { return }
        if changed {
            guard !relaunching else { return }
            relaunching = true
            Self.relaunch(continuingSetup: true)
        } else if side == nil, let effects, !Snapshot.isRunning {
            side = CameraSide(installer: installer, effects: effects)
            if Self.continuingSetup, side?.access.status == .notDetermined { side?.access.request() }
        }
    }
}

/// Effects: overlays, push-ins and combos, the keys that trigger them (with
/// Mute), the Quick Menu, the Live panel, and the overlay shown while you
/// dictate.
@MainActor
final class Effects {
    let overlays = OverlayLibrary()
    let zoomShortcuts = ZoomShortcuts()
    let combos = ComboLibrary()
    let triggers: Triggers
    let quickMenu: QuickMenu
    let live: LivePanel
    private let appState: AppState
    private var dictating = false

    init(appState: AppState) {
        self.appState = appState
        triggers = Triggers(appState: appState, overlays: overlays, zoom: zoomShortcuts, combos: combos)
        quickMenu = QuickMenu(triggers: triggers)
        live = LivePanel(overlays: overlays, zoom: zoomShortcuts)
        triggers.openLive = { [live] in live.show() }
        followSolo()
    }

    /// Solo mode is dictating: the "while dictating" overlay shows while it's
    /// on.
    private func followSolo() {
        let active = withObservationTracking { appState.soloActive } onChange: { [weak self] in
            Task { @MainActor in self?.followSolo() }
        }
        guard active != dictating else { return }
        dictating = active
        overlays.setDictating(active)
    }
}

/// The camera: access, the priority list, Vaux Camera's device, and the feed
/// between them.
@MainActor
final class CameraSide {
    let access = CameraAccess()
    let priority = CameraPriorityModel()
    let device = CameraDevice()
    let feeder: Feeder

    init(installer: ExtensionInstaller, effects: Effects) {
        feeder = Feeder(
            installer: installer,
            access: access,
            cameras: priority,
            device: device,
            overlays: effects.overlays,
            zoomShortcuts: effects.zoomShortcuts
        )
    }
}

/// Brings over Frames' setup, the spike Vaux Camera grew from, the first
/// time the camera is turned on: overlays and their graphics, camera order
/// and zoom, push-ins, combos, Quick Menu keys and shortcuts.
@MainActor
enum FramesImport {
    private static let frames = "dev.imathis.frames"
    private static let doneKey = "framesImported"
    private static let log = Logger(subsystem: "dev.imathis.vaux", category: "import")

    /// Frames' settings Vaux uses under the same names.
    private static let keys = ["preferredCameraOrder", "cameraZoom", "followsDocking", "zoomShortcuts", "combos", "quickMenuKeys"]
    /// Shortcuts: the Quick Menu's, Clear All's, and each overlay's, push-in's
    /// and combo's.
    private static let shortcutPrefixes = ["KeyboardShortcuts_quickMenu", "KeyboardShortcuts_clearAll", "KeyboardShortcuts_overlay-", "KeyboardShortcuts_zoom-", "KeyboardShortcuts_combo-"]

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        let source = URL.applicationSupportDirectory.appending(path: frames, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.appending(path: "overlays.json").path),
              let settings = defaults.persistentDomain(forName: frames)
        else { return }
        do {
            let target = OverlayLibrary.folder
            try? fileManager.removeItem(at: target)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        } catch {
            log.error("Couldn't bring over Frames' overlays: \(error)")
            return
        }
        for (key, value) in settings
        where keys.contains(key) || shortcutPrefixes.contains(where: key.hasPrefix) {
            defaults.set(value, forKey: key)
        }
        log.notice("Brought over Frames' setup")
    }
}
