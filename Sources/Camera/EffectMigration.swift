import Foundation
import KeyboardShortcuts

/// Effects from how an earlier Vaux kept them: overlays, push-in levels,
/// looks and combos apart. Each becomes an effect under its own ID, keeping
/// its shortcut and Quick Menu key; combos build on what they held. What
/// was kept before is left as it was, so an earlier Vaux still finds it.
extension EffectLibrary {
    static func migrated() -> Stored {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let overlayData = try? Data(contentsOf: folder.appending(path: "overlays.json"))
        let old = overlayData.flatMap { try? decoder.decode(OldOverlays.self, from: $0) }
        let levels = defaults.data(forKey: "zoomShortcuts").flatMap { try? decoder.decode([OldLevel].self, from: $0) }
        let looks = defaults.data(forKey: "looks").flatMap { try? decoder.decode([Look].self, from: $0) }
        let combos = defaults.data(forKey: "combos").flatMap { try? decoder.decode([OldCombo].self, from: $0) } ?? []
        let liveLook = defaults.string(forKey: "liveLook").flatMap(UUID.init)
        guard overlayData != nil || levels != nil || looks != nil else { return firstRun }

        var effects: [Effect] = []
        /// Trigger IDs, which name shortcuts and Quick Menu keys, as they were.
        var formerIDs: [UUID: String] = [:]
        for overlay in old?.overlays ?? [] {
            effects.append(Effect(id: overlay.id, name: overlay.name, overlays: [overlay.updated], duration: overlay.duration))
            formerIDs[overlay.id] = "overlay-\(overlay.id)"
        }
        for level in levels ?? [] {
            effects.append(Effect(id: level.id, name: "Push In \(level.zoom.zoomText)", pushIn: level.zoom))
            formerIDs[level.id] = "zoom-\(level.id.uuidString)"
        }
        for var look in looks ?? [] {
            // Saved before looks knew their preset: matched by name.
            if look.preset == nil { look.preset = Look.presets.first { $0.name == look.name }?.preset }
            effects.append(Effect(id: look.id, name: look.name, look: look))
            formerIDs[look.id] = "look-\(look.id)"
        }
        for combo in combos {
            let includes = combo.overlays + [combo.pushIn, combo.look].compactMap { $0 }
            effects.append(Effect(id: combo.id, name: combo.name, includes: includes))
            formerIDs[combo.id] = "combo-\(combo.id)"
        }

        // Kinds kept apart could share a name (a combo named for an overlay
        // it shows): later ones say what they were.
        var names: Set<String> = []
        for index in effects.indices {
            let effect = effects[index]
            if names.contains(effect.name) {
                let kind = effect.look != nil ? "look" : effect.pushIn != nil ? "push-in" : !effect.includes.isEmpty ? "combo" : "overlay"
                effects[index].name += " (\(kind))"
            }
            names.insert(effects[index].name)
        }

        var live = Effect(name: "Live", overlays: [old?.live?.updated ?? .live])
        if let zoom = defaults.object(forKey: "liveZoom") as? Double, zoom > 1.001 { live.pushIn = zoom }
        if let liveLook, effects.contains(where: { $0.id == liveLook }) { live.includes = [liveLook] }

        // Shortcuts and Quick Menu keys, under the effects' trigger IDs too.
        var keys = defaults.dictionary(forKey: "quickMenuKeys") as? [String: String] ?? [:]
        for (id, former) in formerIDs {
            let current = Triggers.id(of: .effect(id))
            if let shortcut = KeyboardShortcuts.getShortcut(for: .init(former)) {
                KeyboardShortcuts.setShortcut(shortcut, for: .init(current))
            }
            if let key = keys[former] { keys[current] = key }
        }
        defaults.set(keys, forKey: "quickMenuKeys")

        let ids = Set(effects.map(\.id))
        return Stored(
            effects: effects,
            defaultEffect: defaults.string(forKey: "defaultLook").flatMap(UUID.init).flatMap { ids.contains($0) ? $0 : nil },
            dictationEffect: old?.dictationOverlay.flatMap { ids.contains($0) ? $0 : nil },
            live: live
        )
    }

    /// A first run: the original dictation badge, shown while dictating, a
    /// push-in and a look to start from.
    private static var firstRun: Stored {
        let dictating = Effect(name: "Dictating", overlays: [.dictating])
        let pushIn = Effect(name: "Push In", pushIn: 1.5)
        var noir = Effect(name: "Noir")
        noir.look = Look.presets.first
        return Stored(effects: [dictating, pushIn, noir], dictationEffect: dictating.id, live: Effect(name: "Live", overlays: [.live]))
    }
}

/// overlays.json as it was: overlays with their names and durations, one
/// icon each (before lines had their own), and which showed while
/// dictating.
private struct OldOverlays: Decodable {
    struct Entry: Decodable {
        let overlay: Overlay
        let id: UUID
        let name: String
        let duration: Double?
        let icon: String?

        private enum Keys: String, CodingKey {
            case id, name, duration, icon
        }

        init(from decoder: any Decoder) throws {
            overlay = try Overlay(from: decoder)
            let values = try decoder.container(keyedBy: Keys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Overlay"
            duration = try values.decodeIfPresent(Double.self, forKey: .duration)
            icon = try values.decodeIfPresent(String.self, forKey: .icon)
        }

        /// Its one icon on each of its lines, and text no smaller than
        /// medium (text no longer comes small).
        var updated: Overlay {
            var overlay = overlay
            if let icon {
                for index in overlay.lines.indices where overlay.lines[index].icon == nil { overlay.lines[index].icon = icon }
            }
            if overlay.kind == .text, !Overlay.Size.textSizes.contains(overlay.size) { overlay.size = .medium }
            return overlay
        }
    }

    let overlays: [Entry]
    let dictationOverlay: UUID?
    let live: Entry?
}

private struct OldLevel: Decodable {
    let id: UUID
    let zoom: Double
}

private struct OldCombo: Decodable {
    let id: UUID
    let name: String
    let overlays: [UUID]
    let pushIn: UUID?
    let look: UUID?
}
