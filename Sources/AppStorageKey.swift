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

    /// Solo mode: lower speaker output while solo is on, to this fraction of
    /// its current level (scalar 0.0...1.0).
    static let soloDuck = "soloDuck"
    static let soloDuckLevel = "soloDuckLevel"
    static let soloDuckLevelDefault = 0.3

    /// Solo mode: modifier key whose lone tap toggles solo (`ModifierTapMonitor.Key`).
    static let soloTapKey = "soloTapKey"

    /// Solo mode: bundle ID of the app solo follows — on while it's listening
    /// to the mic. Empty for none.
    static let soloFollowApp = "soloFollowApp"
}

extension Notification.Name {
    /// Posted when the user enables enforcement, so AppState applies it immediately.
    static let enforcePreferredInput = Notification.Name("enforcePreferredInput")
}
