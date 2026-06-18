import Foundation

/// Shared persistence keys/defaults so `AppState` and `SettingsView` agree.
enum AppStorageKey {
    static let unmuteVolume = "unmuteVolume"
    /// Scalar 0.0...1.0. macOS's "input volume 0–100" maps to this × 100.
    static let unmuteVolumeDefault = 0.75
}
