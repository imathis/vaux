import CoreAudio
import Foundation
import KeyboardShortcuts
import Observation

/// Single source of truth for the menu bar UI and the mute action.
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

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleMicMute) { [weak self] in
            self?.toggle()
        }
        startDefaultDeviceListener()
        refreshDevice()
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
        currentDevice = dev

        guard let dev else {
            deviceName = nil
            supportsMute = false
            muted = false
            muteListener = nil
            return
        }

        deviceName = AudioController.deviceName(dev)
        supportsMute = AudioController.supportsMute(dev)
        muted = currentMutedState(dev)
        startMuteListener(for: dev)
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
    }

    private func currentMutedState(_ dev: AudioDeviceID) -> Bool {
        if AudioController.supportsMute(dev) {
            return AudioController.isMuted(dev)
        }
        // No mute property: treat ~0 input volume as muted.
        return (AudioController.volume(on: dev) ?? 1) <= 0.0001
    }
}
