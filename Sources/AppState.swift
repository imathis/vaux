import CoreAudio
import Foundation
import KeyboardShortcuts

/// Single source of truth for the mute action and the menu bar state.
///
/// Resolves the default input device live, mirrors its mute state into
/// `muted` (for the icon), and re-resolves automatically when the system
/// input changes. The hotkey and the menu item both route through `toggle()`.
@MainActor
final class AppState {
    private(set) var muted = false
    private(set) var deviceName: String?
    private(set) var supportsMute = false

    /// Invoked on the main actor whenever `muted` / `deviceName` /
    /// `supportsMute` change, so the AppKit status item can refresh.
    var onStateChange: (() -> Void)?

    var hasDevice: Bool { currentDevice != nil }

    private var currentDevice: AudioDeviceID?
    private var defaultDeviceListener: AudioPropertyListener?
    private var muteListener: AudioPropertyListener?

    /// Unmute level as a scalar 0.0...1.0, read fresh from `UserDefaults`
    /// (kept in sync by the Settings slider via `@AppStorage`).
    private var unmuteVolume: Float32 {
        let stored = UserDefaults.standard.object(forKey: AppStorageKey.unmuteVolume) as? Double
        return Float32(stored ?? AppStorageKey.unmuteVolumeDefault)
    }

    private var muteIntentInitialized = false

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleMicMute) { [weak self] in
            self?.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .applyPreferredInput) { [weak self] in
            self?.applyPreferredInput()
        }
        startDefaultDeviceListener()
        refreshDevice()
    }

    /// Switch the system default input to the highest-priority device in the
    /// preferred order that's currently connected. No-op if none are present.
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
        if AudioController.supportsMute(dev) {
            let next = !AudioController.isMuted(dev)
            AudioController.setMuted(next, on: dev)
            if !next { AudioController.setVolume(unmuteVolume, on: dev) } // reassert level on unmute
            muted = next
        } else {
            let next = !muted
            AudioController.setVolume(next ? 0 : unmuteVolume, on: dev)
            muted = next
        }
        notify()
    }

    // MARK: Device tracking

    private func startDefaultDeviceListener() {
        defaultDeviceListener = AudioPropertyListener(
            objectID: AudioController.system,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            // Listener fires on the main queue (see AudioPropertyListener), so
            // we're already on the MainActor executor.
            MainActor.assumeIsolated { self?.refreshDevice() }
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
            muteListener = nil
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

    private func writeMuteIntent(to dev: AudioDeviceID) {
        if AudioController.supportsMute(dev) {
            AudioController.setMuted(muted, on: dev)
            if !muted { AudioController.setVolume(unmuteVolume, on: dev) }
        } else {
            AudioController.setVolume(muted ? 0 : unmuteVolume, on: dev)
        }
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
        muteListener = AudioPropertyListener(
            objectID: dev,
            selector: selector,
            scope: kAudioObjectPropertyScopeInput
        ) { [weak self] in
            MainActor.assumeIsolated { self?.resyncMutedState() }
        }
    }

    private func resyncMutedState() {
        guard let dev = currentDevice else { return }
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
        onStateChange?()
    }
}
