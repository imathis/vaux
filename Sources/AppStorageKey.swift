import Foundation

/// Shared persistence keys/defaults so `AppState` and `SettingsView` agree.
enum AppStorageKey {
    static let unmuteVolume = "unmuteVolume"
    /// Scalar 0.0...1.0. macOS's "input volume 0–100" maps to this × 100.
    static let unmuteVolumeDefault = 0.75

    /// Auto-switch to the highest-priority connected input on device/input changes.
    static let enforcePreferred = "enforcePreferred"
}

extension Notification.Name {
    /// Posted when the user enables enforcement, so AppState applies it immediately.
    static let hushEnforcePreferred = Notification.Name("hushEnforcePreferred")
}
