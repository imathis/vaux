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
