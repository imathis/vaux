import Foundation

/// Shared persistence keys/defaults so `AppState` and `SettingsView` agree.
enum AppStorageKey {
    static let unmuteVolume = "unmuteVolume"
    /// Scalar 0.0...1.0. macOS's "input volume 0–100" maps to this × 100.
    static let unmuteVolumeDefault = 0.75
    /// Per-input unmute levels that override the default: [device UID: scalar].
    static let unmuteVolumeOverrides = "unmuteVolumeOverrides"

    /// Auto-switch to the highest-priority connected input on device/input changes.
    static let enforcePreferred = "enforcePreferred"

    /// Solo mode: speaker volume while solo is on, as a share of its level
    /// (scalar 0.05...1.0). 1 leaves the speakers alone.
    static let soloSpeakerLevel = "soloSpeakerLevel"
    static let soloSpeakerLevelDefault = 1.0

    /// Solo mode: pause playing media until solo ends.
    static let soloPauseMedia = "soloPauseMedia"
    static let soloPauseMediaDefault = true

    /// Solo mode: key shared with dictation that toggles solo
    /// (`SoloKeyMonitor.Key`): the Dictation key or a lone modifier tap.
    static let soloTapKey = "soloTapKey"

    /// Solo mode: bundle ID of the app solo follows — on while it's listening
    /// to the mic. Empty for none.
    static let soloFollowApp = "soloFollowApp"
}
