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

    /// What you dictate with, which turns solo on and off: `macOSDictation`,
    /// followed by its 🎤 key (its own mic use can't be seen), or a dictation
    /// app's bundle ID, followed while it's listening.
    static let dictateWith = "dictateWith"
    static let macOSDictation = "macOSDictation"

    /// Vaux Camera is turned on (opt-in; see `VauxCamera`). The camera's own
    /// settings live with its parts.
    static let cameraOn = "cameraOn"
    /// The menu's camera section shows every effect (or only what's on).
    static let menuCameraExpanded = "menuCameraExpanded"
}

/// Settings from earlier builds, moved to what replaced them before anything
/// reads them.
enum SettingsMigration {
    static func run() {
        let defaults = UserDefaults.standard
        // Solo's triggers (a shortcut, a key shared with dictation, a followed
        // app) became one choice: what you dictate with. A followed app wins;
        // otherwise macOS Dictation. Pausing media stopped being a setting.
        if defaults.string(forKey: AppStorageKey.dictateWith) == nil {
            let follow = defaults.string(forKey: "soloFollowApp") ?? ""
            defaults.set(follow.isEmpty ? AppStorageKey.macOSDictation : follow, forKey: AppStorageKey.dictateWith)
        }
        for key in ["soloFollowApp", "soloTapKey", "soloPauseMedia", "KeyboardShortcuts_toggleSolo"] {
            defaults.removeObject(forKey: key)
        }
    }
}
