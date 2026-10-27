import Foundation
import KeyboardShortcuts
import Observation

/// Zoom levels to push in to with a key (or a Stream Deck button): press to
/// push in, again to come back. On top of each camera's own zoom, so a
/// close-up feels the same on a wide camera and a tight one.
@MainActor @Observable
final class ZoomShortcuts {
    struct Level: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        var zoom: Double

        var name: KeyboardShortcuts.Name { Self.shortcut(for: id) }

        static func shortcut(for id: UUID) -> KeyboardShortcuts.Name { .init("zoom-\(id.uuidString)") }
    }

    static let range = 1.1...2.0
    private static let key = "zoomShortcuts"

    private(set) var levels: [Level]
    /// The level pushed in to, if any.
    private(set) var active: UUID?
    /// Levels with a key recorded: only they're in play mid-call.
    private(set) var assigned: Set<UUID> = []
    /// The Live effect's zoom, while Live is on: in place of the levels
    /// until a level is pushed in.
    private(set) var liveZoom: Double?
    /// The zoom the Live effect pushes in to when it's on, kept for next
    /// time. Changed while Live is on, the camera follows.
    var liveLevel = UserDefaults.standard.object(forKey: ZoomShortcuts.liveLevelKey) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(liveLevel, forKey: Self.liveLevelKey)
            if liveZoom != nil { liveZoom = liveLevel > 1.001 ? liveLevel : nil }
        }
    }
    private static let liveLevelKey = "liveZoom"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Level].self, from: $0) }
        // A starting point to record a key for. Saved at once: its key is
        // stored under its ID.
        levels = stored ?? [Level(id: UUID(), zoom: 1.5)]
        if stored == nil { save() }
        assigned = Set(levels.filter { KeyboardShortcuts.getShortcut(for: $0.name) != nil }.map(\.id))
    }

    /// How far it's pushed in: the Live zoom, or the active level; 1 with
    /// neither.
    var factor: Double { liveZoom ?? levels.first { $0.id == active }?.zoom ?? 1 }

    /// The furthest a level with a key (or the Live effect) pushes in: the
    /// camera runs in a mode that keeps it sharp, so pushing in never
    /// switches modes mid-call.
    var furthest: Double { max(levels.filter { assigned.contains($0.id) }.map(\.zoom).max() ?? 1, liveLevel) }

    /// The Live effect on (its level, in place of any other) or off.
    func applyLive(_ on: Bool) {
        liveZoom = on && liveLevel > 1.001 ? liveLevel : nil
        if on, liveZoom != nil, active != nil { active = nil }
    }

    /// The recorder changed a level's key.
    func shortcutChanged(_ level: Level, to shortcut: KeyboardShortcuts.Shortcut?) {
        if shortcut == nil { assigned.remove(level.id) } else { assigned.insert(level.id) }
    }

    func toggle(_ id: UUID) {
        active = active == id ? nil : id
        liveZoom = nil
    }

    /// Pushes in to a level, or (nil) back to the camera's own zoom.
    func activate(_ id: UUID?) {
        if active != id { active = id }
        if liveZoom != nil { liveZoom = nil }
    }

    /// Back to each camera's own zoom: a new call starts there.
    func reset() {
        if active != nil { active = nil }
        if liveZoom != nil { liveZoom = nil }
    }

    func add() {
        levels.append(Level(id: UUID(), zoom: 1.5))
        save()
    }

    /// Its key goes with it (`Triggers` follows the levels).
    func remove(_ level: Level) {
        assigned.remove(level.id)
        levels.removeAll { $0.id == level.id }
        if active == level.id { active = nil }
        save()
    }

    /// Undoing a remove: back in its place, its key in play if it had one.
    func restore(_ level: Level, at index: Int, assigned hasKey: Bool) {
        levels.insert(level, at: min(index, levels.count))
        if hasKey { assigned.insert(level.id) }
        save()
    }

    func setZoom(_ zoom: Double, for level: Level) {
        guard let index = levels.firstIndex(where: { $0.id == level.id }) else { return }
        levels[index].zoom = min(max(zoom, Self.range.lowerBound), Self.range.upperBound)
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(levels), forKey: Self.key)
    }
}
