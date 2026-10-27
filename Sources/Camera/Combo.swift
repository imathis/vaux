import Foundation
import Observation

/// Several effects on one key: overlays, each in its spot, and at most one
/// push-in (zoom is one level at a time). Taps and holds like any other.
struct Combo: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var overlays: [UUID] = []
    var pushIn: UUID?
}

/// The user's combos, stored in UserDefaults. Members deleted elsewhere are
/// skipped wherever a combo is used.
@MainActor @Observable
final class ComboLibrary {
    var combos: [Combo] {
        didSet { save() }
    }

    private static let key = "combos"

    init() {
        combos = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Combo].self, from: $0) } ?? []
    }

    func combo(_ id: UUID) -> Combo? { combos.first { $0.id == id } }

    @discardableResult
    func add() -> Combo {
        let combo = Combo(name: "New Combo")
        combos.append(combo)
        return combo
    }

    func duplicate(_ id: UUID) {
        guard var copy = combo(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        combos.append(copy)
    }

    func remove(_ id: UUID) {
        combos.removeAll { $0.id == id }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(combos), forKey: Self.key)
    }
}
