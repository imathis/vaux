import Foundation

/// One camera in the priority list, keyed by its stable unique ID. `name` is
/// the last-seen name, so unplugged cameras still read well.
struct CameraEntry: Codable, Hashable, Identifiable, Sendable {
    let uid: String
    var name: String
    var id: String { uid }
}

/// The user's camera priority order (highest first), stored in UserDefaults.
enum PreferredCamera {
    private static let key = "preferredCameraOrder"

    static var order: [CameraEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([CameraEntry].self, from: data)
            else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

/// How far each camera is zoomed in, a center crop, by unique ID. 1× when
/// not set.
enum CameraZoom {
    static let range = 1.0...2.0
    private static let key = "cameraZoom"

    static var levels: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension Double {
    var zoomText: String { "\(formatted(.number.precision(.fractionLength(0...2))))×" }
}
