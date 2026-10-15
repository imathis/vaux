import CoreAudio
import Foundation
import KeyboardShortcuts
import Observation
import os

/// Single source of truth for the mute action and the menu bar state.
///
/// Resolves the default input device live, mirrors its mute state into
/// `muted` (for the icon), and re-resolves automatically when the system
/// input changes. The hotkey and the menu item both route through `toggle()`.
@MainActor
@Observable
final class AppState {
    private(set) var muted = false
    private(set) var deviceName: String?
    private(set) var supportsMute = false

    /// Invoked on the main actor whenever `muted` / `deviceName` /
    /// `supportsMute` change, so the AppKit status item can refresh.
    @ObservationIgnored var onStateChange: (() -> Void)?

    var hasDevice: Bool { currentDevice != nil }

    @ObservationIgnored private var currentDevice: AudioDeviceID?
    @ObservationIgnored private var defaultDeviceListener: AudioPropertyListener?
    @ObservationIgnored private var muteListeners: [AudioPropertyListener] = []

    /// Unmute level for a device as a scalar 0.0...1.0: its own level if set
    /// in Settings, else the default. Read fresh from `UserDefaults`.
    private func unmuteVolume(for dev: AudioDeviceID) -> Float32 {
        Float32(UnmuteVolume.level(forUID: AudioController.deviceUID(dev)))
    }

    @ObservationIgnored private var muteIntentInitialized = false
    /// Just after switching inputs: the new device's own mute and volume
    /// changes are it settling, not someone changing them, so they don't
    /// overwrite the intent.
    @ObservationIgnored private var settlingUntil = Date.distantPast

    @ObservationIgnored private var deviceListListener: AudioPropertyListener?
    @ObservationIgnored private var enforceScheduled = false
    /// UIDs of the currently-connected input devices, to detect plug/unplug
    /// (the only event that triggers an automatic input switch).
    @ObservationIgnored private var lastInputUIDs: Set<String> = []

    private var enforcePreferred: Bool {
        UserDefaults.standard.bool(forKey: AppStorageKey.enforcePreferred)
    }

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleMicMute) { [weak self] in
            self?.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleSolo) { [weak self] in
            self?.toggleSolo()
        }
        keyMonitor = SoloKeyMonitor(
            onKey: { [weak self] in self?.toggleSolo(byKey: true) },
            onEscape: { [weak self] in self?.escapePressed() }
        )
        callWatcher.bundleIDs = Set(CallApp.all.map(\.bundleID))
        callWatcher.start { [weak self] id, inCall in
            guard let app = CallApp.all.first(where: { $0.bundleID == id }) else { return }
            self?.callStateChanged(app, inCall: inCall)
        }
        followWatcher.bundleIDs = Self.followApp
        followWatcher.start { [weak self] id, capturing in
            Self.log.notice("follow: \(id, privacy: .public) \(capturing ? "listening" : "stopped", privacy: .public)")
            self?.followAppChanged(capturing: capturing)
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWatcher.bundleIDs = Self.followApp }
        }
        startDefaultDeviceListener()
        lastInputUIDs = Set(AudioController.inputDevices().map(\.uid))
        startDeviceListListener()
        NotificationCenter.default.addObserver(
            forName: .enforcePreferredInput, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferredInput() }
        }
        refreshDevice()
    }

    /// Switch the system default input to the highest-priority connected device
    /// in the preferred order. No-op if none are present or it's already current.
    func applyPreferredInput() {
        let present = AudioController.inputDevices()
        let current = AudioController.defaultInputDevice()
        for entry in PreferredInput.order where !entry.uid.isEmpty {
            guard let match = present.first(where: { $0.uid == entry.uid }) else { continue }
            if match.id != current {
                AudioController.setDefaultInputDevice(match.id)
                // The default-input listener will enforce mute intent onto it.
            }
            return
        }
    }

    // MARK: Actions

    func toggle() {
        guard let dev = currentDevice ?? AudioController.defaultInputDevice() else { return }
        setMuted(AudioController.supportsMute(dev) ? !AudioController.isMuted(dev) : !muted)
    }

    /// Set the mute intent and write it to the current input, if any. A
    /// device that won't take it (no mute and no settable volume) keeps its
    /// state, and the icon shows that rather than the intent.
    private func setMuted(_ next: Bool) {
        muted = next
        if let dev = currentDevice ?? AudioController.defaultInputDevice(), !writeMuteIntent(to: dev) {
            muted = currentMutedState(dev)
        }
        notify()
    }

    // MARK: Solo mode
    //
    // For dictating during a call: mute the call apps through their own UI
    // (see CallMuter) and keep the mic live, optionally ducking speaker output
    // so less of the call bleeds into the mic. Everything solo changes is
    // recorded and put back on exit.

    private(set) var soloActive = false
    /// A solo transition is in flight (the Accessibility work runs off main).
    private(set) var soloBusy = false
    /// Call apps muted while solo is on, for the menu.
    private(set) var soloMutedApps: [String] = []
    /// Speaker level while ducked, for the menu.
    private(set) var soloDuckedTo: Float32?
    /// Anything that didn't go to plan, for the menu.
    private(set) var soloProblems: [String] = []

    private static let log = Logger(subsystem: "dev.imathis.vaux", category: "solo")

    @ObservationIgnored private var soloSnapshot: SoloSnapshot?
    /// A toggle that arrived mid-transition. Queued rather than dropped: a
    /// trigger shared with a dictation app must never be skipped, or the two
    /// fall out of step.
    @ObservationIgnored private var pendingSoloToggle = false
    /// Whether the queued toggle came from the key shared with dictation.
    @ObservationIgnored private var pendingToggleByKey = false
    /// Quitting: once the transition in flight lands, end solo and call this.
    @ObservationIgnored private var quitWhenSettled: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var keyMonitor: SoloKeyMonitor?
    @ObservationIgnored private let callWatcher = CaptureWatcher()
    /// Watches the app solo follows (e.g. a dictation app): solo turns on
    /// while it's listening.
    @ObservationIgnored private let followWatcher = CaptureWatcher()
    /// Solo was turned on by the followed app, so it ends when that stops.
    @ObservationIgnored private var soloStartedByFollow = false
    /// Solo was turned on by a key shared with dictation, so Escape, which
    /// ends dictation, ends solo too.
    @ObservationIgnored private var soloStartedByKey = false
    /// The followed app's state change that arrived mid-transition.
    @ObservationIgnored private var pendingFollow: Bool?
    @ObservationIgnored private let mediaPauser = MediaPauser()

    private static var followApp: Set<String> {
        let id = UserDefaults.standard.string(forKey: AppStorageKey.soloFollowApp) ?? ""
        return id.isEmpty ? [] : [id]
    }

    private var pauseMedia: Bool {
        UserDefaults.standard.object(forKey: AppStorageKey.soloPauseMedia) as? Bool ?? true
    }

    private struct SoloSnapshot {
        let wasMuted: Bool
        /// Only apps solo muted itself — ones already muted are left alone.
        let mutedApps: [CallApp]
        let duck: OutputDuck?
    }

    private struct OutputDuck {
        let device: AudioDeviceID
        let original: Float32
        let ducked: Float32
    }

    /// `byKey`: from the key shared with dictation, rather than the menu or a
    /// key combo of Vaux's own.
    func toggleSolo(byKey: Bool = false) {
        guard !soloBusy else {
            pendingSoloToggle.toggle()
            pendingToggleByKey = byKey
            return
        }
        if soloActive {
            endSolo()
        } else {
            soloStartedByFollow = false
            soloStartedByKey = byKey
            startSolo()
        }
    }

    /// Escape ends dictation, so it ends a solo the shared key started. A solo
    /// still starting ends as soon as it's on.
    private func escapePressed() {
        guard soloStartedByKey else { return }
        if soloActive, !soloBusy {
            endSolo()
        } else if !soloActive, soloBusy {
            pendingSoloToggle = true
        }
    }

    /// The followed app started or stopped listening. Starting turns solo on;
    /// stopping turns it off only if starting did — a manual solo is left be.
    private func followAppChanged(capturing: Bool) {
        guard !soloBusy else { pendingFollow = capturing; return }
        if capturing, !soloActive {
            soloStartedByFollow = true
            soloStartedByKey = false
            startSolo()
        } else if !capturing, soloActive, soloStartedByFollow {
            endSolo()
        }
    }

    private func finishSoloTransition() {
        soloBusy = false
        notify()
        if let done = quitWhenSettled {
            quitWhenSettled = nil
            pendingSoloToggle = false
            pendingFollow = nil
            endSolo(completion: done)
        } else if pendingSoloToggle {
            pendingSoloToggle = false
            toggleSolo(byKey: pendingToggleByKey)
        } else if let capturing = pendingFollow {
            pendingFollow = nil
            followAppChanged(capturing: capturing)
        }
    }

    /// Keep a call app's AX tree built while it's in a call, so solo can read
    /// and press its mute toggle at once (a cold tree takes ~2s).
    private func callStateChanged(_ app: CallApp, inCall: Bool) {
        guard CallMuter.isTrusted else { return }
        if !inCall { CallMuter.queue.async { CallMuter.forget(app) } }
        let mutedBySolo = soloSnapshot?.mutedApps.contains(app) ?? false
        guard inCall || !mutedBySolo else { return }
        CallMuter.queue.async { CallMuter.setTreeEnabled(inCall, for: app) }
    }

    private func startSolo() {
        guard CallMuter.isTrusted else {
            CallMuter.requestTrust()
            soloProblems = ["Allow Vaux in Privacy & Security → Accessibility, then try again"]
            soloStartedByKey = false
            notify()
            return
        }
        soloBusy = true
        soloProblems = []
        notify()
        // Apps on the mic that solo can't mute. Read now, before a dictation
        // app sharing the trigger starts listening too.
        let mine = Set(CallApp.all.map(\.bundleID)).union(Self.followApp).union([Bundle.main.bundleIdentifier ?? ""])
        let unmutable = AudioController.appsCapturingInput(ignoring: mine)
        CallMuter.queue.async { [weak self] in
            let outcomes = CallApp.all.map { (app: $0, outcome: CallMuter.mute($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishStartingSolo(outcomes, unmutable: unmutable) }
            }
        }
    }

    /// `unmutable`: other apps using the mic, which still hear you.
    private func finishStartingSolo(_ outcomes: [(app: CallApp, outcome: CallMuter.Outcome)], unmutable: [String]) {
        let mutedApps = outcomes.filter { $0.outcome == .muted }.map(\.app)
        let failures = outcomes.filter { $0.outcome == .failed }.map { "Couldn't mute \($0.app.name)" }

        // The mic is muted and a call couldn't be confirmed muted: don't open
        // the mic to it. Put back what we did mute and stay out of solo.
        if muted, !failures.isEmpty {
            soloProblems = failures + ["Solo not started — mic stays muted"]
            pendingSoloToggle = false
            CallMuter.queue.async { [weak self] in
                for app in mutedApps { _ = CallMuter.unmute(app) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.pendingSoloToggle = false
                        self?.pendingFollow = nil
                        self?.soloStartedByKey = false
                        self?.finishSoloTransition()
                    }
                }
            }
            notify()
            return
        }

        let duck = duckOutput()
        // macOS Dictation pauses and resumes media itself, and resumes as soon
        // as it stops listening, so a solo the Dictation key started leaves it be.
        let dictationKey = soloStartedByKey && SoloKeyMonitor.Key.current == .dictation
        if pauseMedia, !dictationKey {
            mediaPauser.pause(ignoring: Set(CallApp.all.map(\.bundleID)).union(Self.followApp))
        } else {
            mediaPauser.hold()
        }
        soloSnapshot = SoloSnapshot(wasMuted: muted, mutedApps: mutedApps, duck: duck)
        if muted { setMuted(false) }
        soloMutedApps = outcomes
            .filter { $0.outcome == .muted || $0.outcome == .alreadyMuted }
            .map(\.app.name)
        soloDuckedTo = duck?.ducked
        soloProblems = failures + unmutable.map { "\($0) can still hear you" }
        soloActive = true
        finishSoloTransition()
    }

    /// For quitting: end solo, waiting first for a transition in flight, and
    /// call `done` once the call apps are unmuted.
    func endSoloForQuit(_ done: @escaping @MainActor @Sendable () -> Void) {
        if soloBusy {
            quitWhenSettled = done
        } else {
            endSolo(completion: done)
        }
    }

    /// Restore everything solo changed. `completion` runs once the call apps
    /// are unmuted (used to delay quitting until then).
    func endSolo(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let snapshot = soloSnapshot, !soloBusy else { completion?(); return }
        soloBusy = true
        notify()
        if let duck = snapshot.duck { restoreOutput(duck) }
        mediaPauser.resume()
        // Re-mute the mic before the call apps go live again.
        if snapshot.wasMuted { setMuted(true) }
        let apps = snapshot.mutedApps
        CallMuter.queue.async { [weak self] in
            let failures = apps.filter { CallMuter.unmute($0) == .failed }
                .map { "Couldn't unmute \($0.name) — unmute it there" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self {
                        self.soloSnapshot = nil
                        self.soloActive = false
                        self.soloStartedByKey = false
                        self.soloMutedApps = []
                        self.soloDuckedTo = nil
                        self.soloProblems = failures
                        self.finishSoloTransition()
                    }
                    completion?()
                }
            }
        }
    }

    /// Lower the default output to the configured fraction of its level.
    private func duckOutput() -> OutputDuck? {
        let stored = UserDefaults.standard.object(forKey: AppStorageKey.soloSpeakerLevel) as? Double
        let level = Float32(stored ?? AppStorageKey.soloSpeakerLevelDefault)
        guard level < 0.995,
              let out = AudioController.defaultOutputDevice(),
              let original = AudioController.outputVolume(on: out) else { return nil }
        guard AudioController.setOutputVolume(original * level, on: out) else { return nil }
        // Read back: devices quantize volume (Bluetooth in 1/16 steps).
        let ducked = AudioController.outputVolume(on: out) ?? original * level
        return OutputDuck(device: out, original: original, ducked: ducked)
    }

    private func restoreOutput(_ duck: OutputDuck) {
        // Leave it if the volume was changed while ducked — that's a choice.
        guard let now = AudioController.outputVolume(on: duck.device),
              abs(now - duck.ducked) < 0.02 else { return }
        AudioController.setOutputVolume(duck.original, on: duck.device)
    }

    // MARK: Device tracking

    private func startDefaultDeviceListener() {
        defaultDeviceListener = AudioPropertyListener(
            objectID: AudioController.system,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            // Listener fires on the main queue (see AudioPropertyListener).
            MainActor.assumeIsolated { self?.refreshDevice() }
        }
    }

    /// Fires when devices are added/removed (plug/unplug).
    private func startDeviceListListener() {
        deviceListListener = AudioPropertyListener(
            objectID: AudioController.system,
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            MainActor.assumeIsolated { self?.handleDeviceListChanged() }
        }
    }

    /// Enforce only when the set of *input* devices changes — i.e. a plug or
    /// unplug, which is the only thing that makes macOS auto-select an input. A
    /// manual pick in System Settings doesn't change the device set, so it's
    /// left untouched.
    private func handleDeviceListChanged() {
        let uids = Set(AudioController.inputDevices().map(\.uid))
        guard uids != lastInputUIDs else { return }
        lastInputUIDs = uids
        if enforcePreferred { scheduleEnforce() }
    }

    /// Coalesce + debounce enforcement so we don't fight macOS mid-connect.
    private func scheduleEnforce() {
        guard !enforceScheduled else { return }
        enforceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.enforceScheduled = false
                self.applyPreferredInput()
            }
        }
    }

    /// Re-resolve the default input, refresh name/mute support/state, and
    /// re-point the mute listener at the new device.
    private func refreshDevice() {
        let dev = AudioController.defaultInputDevice()
        let previous = currentDevice
        currentDevice = dev

        guard let dev else {
            deviceName = nil
            supportsMute = false
            muteListeners = []
            // Keep `muted` as the standing intent so it re-applies when a
            // device returns.
            notify()
            return
        }

        deviceName = AudioController.deviceName(dev)
        supportsMute = AudioController.supportsMute(dev)

        if !muteIntentInitialized {
            // First resolve at launch: adopt the device's current state.
            muted = currentMutedState(dev)
            muteIntentInitialized = true
        } else if dev != previous {
            // Default input switched (manual pick, system change, or preferred-
            // input): enforce our mute intent onto the new device so muting
            // persists across input changes.
            applyMuteIntent(to: dev)
        } else {
            // Same device, refreshed for another reason: reflect actual state.
            muted = currentMutedState(dev)
        }

        startMuteListener(for: dev)
        notify()
    }

    /// Re-assert the current mute intent (`muted`) onto a device, then verify.
    private func applyMuteIntent(to dev: AudioDeviceID) {
        settlingUntil = Date().addingTimeInterval(1)
        writeMuteIntent(to: dev)
        // A just-switched or hot-plugged device may not accept the write
        // immediately; re-check after a short delay and re-apply once if the
        // state didn't stick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.currentDevice == dev else { return }
                if !self.muteIntentSatisfied(on: dev) {
                    self.writeMuteIntent(to: dev)
                    self.notify()
                }
            }
        }
    }

    /// Write the mute intent. Unmuting restores the unmute volume; a device
    /// that's live already keeps its own level. False if the write failed.
    @discardableResult
    private func writeMuteIntent(to dev: AudioDeviceID) -> Bool {
        if AudioController.supportsMute(dev) {
            if muted { return AudioController.setMuted(true, on: dev) }
            guard AudioController.isMuted(dev) else { return true }
            AudioController.setVolume(unmuteVolume(for: dev), on: dev)
            return AudioController.setMuted(false, on: dev)
        }
        if muted { return AudioController.setVolume(0, on: dev) }
        guard (AudioController.volume(on: dev) ?? 1) <= 0.0001 else { return true }
        return AudioController.setVolume(unmuteVolume(for: dev), on: dev)
    }

    private func muteIntentSatisfied(on dev: AudioDeviceID) -> Bool {
        if AudioController.supportsMute(dev) {
            return AudioController.isMuted(dev) == muted
        }
        let isZero = (AudioController.volume(on: dev) ?? 1) <= 0.0001
        return isZero == muted
    }

    /// Keeps the icon honest when mute/volume is changed elsewhere
    /// (System Settings, another app).
    private func startMuteListener(for dev: AudioDeviceID) {
        let selector: AudioObjectPropertySelector =
            supportsMute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
        // Volume can live on the main element or only on the channels.
        let elements = supportsMute ? [kAudioObjectPropertyElementMain] : AudioController.volumeElements(on: dev)
        muteListeners = elements.compactMap { element in
            AudioPropertyListener(
                objectID: dev,
                selector: selector,
                scope: kAudioObjectPropertyScopeInput,
                element: element
            ) { [weak self] in
                MainActor.assumeIsolated { self?.resyncMutedState() }
            }
        }
    }

    private func resyncMutedState() {
        guard let dev = currentDevice else { return }
        if Date() < settlingUntil {
            if !muteIntentSatisfied(on: dev) { writeMuteIntent(to: dev) }
            return
        }
        muted = currentMutedState(dev)
        notify()
    }

    private func currentMutedState(_ dev: AudioDeviceID) -> Bool {
        if AudioController.supportsMute(dev) {
            return AudioController.isMuted(dev)
        }
        // No mute property: treat ~0 input volume as muted.
        return (AudioController.volume(on: dev) ?? 1) <= 0.0001
    }

    private func notify() {
        keyMonitor?.watchesEscape = soloStartedByKey && (soloActive || soloBusy)
        onStateChange?()
    }
}
