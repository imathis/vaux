import AppKit
import KeyboardShortcuts
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
    /// Effects and their keys: no camera API, so ready as
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

/// Effects and the keys that trigger them (with Mute), the Quick Menu, the
/// Live panel, and the effect on while you dictate.
@MainActor
final class Effects {
    let library = EffectLibrary()
    let triggers: Triggers
    let quickMenu: QuickMenu
    let live: LivePanel
    let preview: EffectsPreview
    private let appState: AppState
    private var dictating = false
    /// An effect that mutes is on.
    private var muting = false
    /// It muted the mic, and you haven't unmuted it since.
    private var mutedByEffect = false

    init(appState: AppState) {
        self.appState = appState
        triggers = Triggers(appState: appState, library: library)
        quickMenu = QuickMenu(triggers: triggers)
        live = LivePanel(library: library)
        preview = EffectsPreview(library: library)
        triggers.openLive = { [live] in live.show() }
        followSolo()
        followMuting()
    }

    /// Deletes an effect, undoably: undo puts it back in its place with its
    /// shortcut and Quick Menu key, the default or dictation effect again if
    /// it was. Effects built on it skip it meanwhile.
    func remove(_ id: UUID, undo: UndoManager?) {
        guard let index = library.effects.firstIndex(where: { $0.id == id }) else { return }
        let effect = library.effects[index]
        let triggerID = Triggers.id(of: .effect(id))
        let name = KeyboardShortcuts.Name(triggerID)
        let shortcut = KeyboardShortcuts.getShortcut(for: name)
        let key = triggers.customKeys[triggerID]
        let isDefault = library.defaultEffect == id
        let isDictation = library.dictationEffect == id
        library.remove(id)
        undo?.registerUndo(withTarget: self) { effects in
            effects.library.restore(effect, at: index, isDefault: isDefault, isDictation: isDictation)
            if let shortcut { KeyboardShortcuts.setShortcut(shortcut, for: name) }
            if let key { effects.triggers.setKey(key, for: triggerID) }
            // Redo.
            undo?.registerUndo(withTarget: effects) { $0.remove(id, undo: undo) }
            undo?.setActionName("Delete \(effect.name)")
        }
        undo?.setActionName("Delete \(effect.name)")
    }

    /// Solo mode is dictating: the dictation effect is on while it's on.
    /// An effect that mutes while it's on mutes the mic as it comes on, and
    /// unmutes it as it goes: only if it did the muting, and you haven't
    /// unmuted since (then the mic's yours again).
    private func followMuting() {
        let (wanted, muted) = withObservationTracking { (library.call.mutesMic, appState.muted) } onChange: { [weak self] in
            Task { @MainActor in self?.followMuting() }
        }
        if wanted, !muting {
            // Coming on: muted already stays yours.
            muting = true
            if !muted {
                mutedByEffect = true
                appState.setMuted(true)
            }
        } else if !wanted, muting {
            muting = false
            if mutedByEffect, muted { appState.setMuted(false) }
            mutedByEffect = false
        } else if mutedByEffect, !muted {
            // You unmuted while it was on.
            mutedByEffect = false
        }
    }

    private func followSolo() {
        let active = withObservationTracking { appState.soloActive } onChange: { [weak self] in
            Task { @MainActor in self?.followSolo() }
        }
        guard active != dictating else { return }
        dictating = active
        library.setDictating(active)
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
            library: effects.library
        )
        effects.preview.feeder = feeder
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
            let target = EffectLibrary.folder
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
