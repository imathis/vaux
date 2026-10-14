import Foundation

/// One device in the preferred-input priority list, keyed by its stable UID.
/// `name` is the last-seen display name (so unplugged devices still read well).
struct InputEntry: Codable, Hashable, Identifiable {
    let uid: String
    var name: String
    var id: String { uid }
}

/// Persists the user's preferred input priority order (highest first) as a
/// JSON-encoded list of UIDs in UserDefaults.
enum PreferredInput {
    private static let key = "preferredInputOrder"

    static var order: [InputEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([InputEntry].self, from: data)
            else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

/// The level an input is set to when unmuted: its own, if it has one, else
/// the default.
enum UnmuteVolume {
    static var defaultLevel: Double {
        UserDefaults.standard.object(forKey: AppStorageKey.unmuteVolume) as? Double
            ?? AppStorageKey.unmuteVolumeDefault
    }

    /// Per-input levels, by device UID.
    static var overrides: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: AppStorageKey.unmuteVolumeOverrides) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: AppStorageKey.unmuteVolumeOverrides) }
    }

    static func level(forUID uid: String?) -> Double {
        uid.flatMap { overrides[$0] } ?? defaultLevel
    }
}
