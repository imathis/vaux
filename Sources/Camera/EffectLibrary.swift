import CoreGraphics
import Foundation
import Observation
import os

/// One overlay showing, ready to draw: its look rendered per frame height.
struct OverlayLayer: Equatable, @unchecked Sendable {
    /// Changes when what's drawn changes, so an edit or a new pick crossfades.
    let key: String
    let spot: Overlay.Spot
    /// By frame height. CGImages are immutable.
    let images: [Int32: CGImage]

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
}

/// Your effects, and which are on. Those on make a stack, in the order they
/// came on: the default effect at the bottom, then each as it's turned on
/// (the dictation effect while you dictate, the Live panel's while it's up).
/// What shows comes from the whole stack, each part from the latest effect
/// that sets it: overlays by spot, the push-in, and look by look setting,
/// so looks stack. A held key adds its effect only while held, so whatever
/// it covered was never gone.
@MainActor @Observable
final class EffectLibrary {
    var effects: [Effect] {
        didSet {
            save()
            reconcile()
        }
    }

    /// On under everything else, unless turned off for now.
    var defaultEffect: UUID? {
        didSet {
            if defaultEffect != oldValue { defaultOff = false }
            save()
            rebuild()
        }
    }

    /// On while you dictate (solo mode), so the call knows why you're muted.
    var dictationEffect: UUID? {
        didSet { save() }
    }

    /// The Live panel's: text typed on the spot, a push-in, and an effect to
    /// go with them. One, outside the list.
    var live: Effect {
        didSet {
            save()
            rebuild()
        }
    }

    struct Entry: Equatable {
        enum Source {
            /// The default effect, at the bottom.
            case base
            /// Turned on by you.
            case user
            case dictation
            case live
        }

        let effect: UUID
        let source: Source
        var token = UUID()
        /// The line or image each of its overlays picked when it came on.
        var variants: [UUID: Int] = [:]
    }

    /// Effects on, bottom first.
    private(set) var stack: [Entry] = []
    /// The default effect, turned off for now.
    private(set) var defaultOff = false

    /// What to draw, full frame first.
    private(set) var scene: [OverlayLayer] = []
    /// The looks on, merged.
    private(set) var look: Look?
    /// How far the stack pushes in; 1 for not at all.
    private(set) var zoom = 1.0
    /// What set the zoom: a new one eases there, an edit to the same one
    /// moves at once.
    private(set) var zoomSource: UUID?

    @ObservationIgnored private var lastVariant: [UUID: Int] = [:]
    @ObservationIgnored private var rendered: [String: [Int32: CGImage]] = [:]
    @ObservationIgnored let log = Logger(subsystem: "dev.imathis.vaux", category: "effects")

    /// Vaux Dev keeps its own.
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.imathis.vaux", directoryHint: .isDirectory)
    }

    /// Where imported graphics are kept.
    static var graphicsFolder: URL { folder.appending(path: "Graphics", directoryHint: .isDirectory) }
    static var file: URL { folder.appending(path: "effects.json") }

    struct Stored: Codable {
        var effects: [Effect]
        var defaultEffect: UUID?
        var dictationEffect: UUID?
        var live: Effect
    }

    init() {
        let stored = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            ?? Self.migrated()
        effects = stored.effects
        defaultEffect = stored.defaultEffect
        dictationEffect = stored.dictationEffect
        live = stored.live
        // The Live panel edits its one text overlay.
        if live.overlays.first?.kind != .text { live.overlays.insert(.live, at: 0) }
        if !FileManager.default.fileExists(atPath: Self.file.path) { save() }
        pruneGraphics(keeping: Set((effects + [live]).flatMap(\.overlays).flatMap(\.images)))
        rebuild()
    }

    func effect(_ id: UUID) -> Effect? { effects.first { $0.id == id } }

    /// On: in the stack, as itself (built on by another doesn't count).
    func isOn(_ id: UUID) -> Bool { stack.contains { $0.effect == id && $0.source != .live } }

    /// Something's on besides the default and dictation.
    var anythingOn: Bool { stack.contains { $0.source == .user || $0.source == .live } }

    var liveOn: Bool { stack.contains { $0.source == .live } }

    /// The furthest any effect (or Live) pushes in: the camera runs in a
    /// mode that keeps it sharp, so pushing in never switches modes mid-call.
    var furthest: Double { max((effects + [live]).compactMap(\.pushIn).max() ?? 1, 1) }

    /// An effect and what it builds on, in the order they stack: what it
    /// includes first (each with what that includes), then itself. Each
    /// once, so one that would include itself stops there.
    func parts(of effect: Effect) -> [Effect] {
        var seen: Set<UUID> = []
        var parts: [Effect] = []
        func add(_ effect: Effect) {
            guard seen.insert(effect.id).inserted else { return }
            for id in effect.includes {
                if let included = self.effect(id) { add(included) }
            }
            parts.append(effect)
        }
        add(effect)
        return parts
    }

    /// `candidate` can go in `id`: it isn't `id`, and doesn't build on it.
    func canInclude(_ candidate: UUID, in id: UUID) -> Bool {
        guard candidate != id, let effect = effect(candidate) else { return false }
        return !parts(of: effect).contains { $0.id == id }
    }

    // MARK: On and off

    /// Turns an effect on, over everything on. Returns its place in the
    /// stack, to take it off again after a hold; nil if it's the default
    /// coming back on, which isn't held.
    @discardableResult
    func turnOn(_ id: UUID) -> UUID? {
        guard let effect = effect(id) else { return nil }
        if id == defaultEffect, defaultOff {
            defaultOff = false
            rebuild()
            return nil
        }
        let entry = Entry(effect: id, source: .user)
        stack.append(entry)
        rebuild()
        if let duration = effect.duration {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                self?.takeOff(entry.token)
            }
        }
        return entry.token
    }

    /// Turns an effect off, wherever it is in the stack (the default, for
    /// now).
    func turnOff(_ id: UUID) {
        if id == defaultEffect { defaultOff = true }
        stack.removeAll { $0.effect == id && $0.source != .live && $0.source != .base }
        rebuild()
    }

    func toggle(_ id: UUID) {
        if isOn(id) {
            turnOff(id)
        } else if let token = turnOn(id) {
            settle(token)
        }
    }

    /// Takes one turn-on back off: a held key let go, or a duration up.
    func takeOff(_ token: UUID) {
        guard stack.contains(where: { $0.token == token }) else { return }
        stack.removeAll { $0.token == token }
        rebuild()
    }

    /// A turn-on that stays (a tap, not a hold): effects of yours it now
    /// covers completely go, rather than coming back when it's turned off.
    func settle(_ token: UUID) {
        guard let top = stack.firstIndex(where: { $0.token == token }) else { return }
        var covered: Set<String> = []
        var drop: Set<UUID> = []
        // Top down, gathering what's set above each.
        for index in stack.indices.reversed() {
            let slots = slots(of: stack[index])
            if index < top, stack[index].source == .user, !slots.isEmpty, slots.isSubset(of: covered) {
                drop.insert(stack[index].token)
            }
            covered.formUnion(slots)
        }
        guard !drop.isEmpty else { return }
        stack.removeAll { drop.contains($0.token) }
        rebuild()
    }

    /// The Live panel's effect up, on top (or back on top), or down.
    func setLive(_ on: Bool) {
        stack.removeAll { $0.source == .live }
        if on { stack.append(Entry(effect: live.id, source: .live)) }
        rebuild()
    }

    /// Dictation started or ended: the dictation effect, on top while it
    /// lasts.
    func setDictating(_ dictating: Bool) {
        stack.removeAll { $0.source == .dictation }
        if dictating, let dictationEffect, effect(dictationEffect) != nil {
            stack.append(Entry(effect: dictationEffect, source: .dictation))
        }
        rebuild()
    }

    /// Everything you turned on, off (the Live text too).
    func clearAll() {
        guard anythingOn else { return }
        stack.removeAll { $0.source == .user || $0.source == .live }
        rebuild()
    }

    /// A call ended: the next starts at each camera's own zoom, so effects
    /// that push in go.
    func endCall() {
        let pushing = stack.filter { ($0.source == .user || $0.source == .live) && parts(of: $0).contains { $0.pushIn != nil } }
        guard !pushing.isEmpty else { return }
        let tokens = Set(pushing.map(\.token))
        stack.removeAll { tokens.contains($0.token) }
        rebuild()
    }

    // MARK: The list

    /// A new effect at the end of the list, named apart from the others.
    @discardableResult
    func add(_ effect: Effect) -> Effect {
        var effect = effect
        let names = Set(effects.map(\.name))
        if names.contains(effect.name) {
            let base = effect.name
            effect.name = (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
        }
        effects.append(effect)
        return effect
    }

    /// A copy beside it.
    @discardableResult
    func duplicate(_ id: UUID) -> Effect? {
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = effects[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.overlays = copy.overlays.map { overlay in
            var overlay = overlay
            overlay.id = UUID()
            return overlay
        }
        effects.insert(copy, at: index + 1)
        return copy
    }

    /// Effects built on it skip it while it's gone, and pick it back up if
    /// it's restored.
    func remove(_ id: UUID) {
        effects.removeAll { $0.id == id }
        if defaultEffect == id { defaultEffect = nil }
        if dictationEffect == id { dictationEffect = nil }
    }

    /// Undoing a remove: back in its place, the default or dictation effect
    /// again if it was.
    func restore(_ effect: Effect, at index: Int, isDefault: Bool, isDictation: Bool) {
        effects.insert(effect, at: min(index, effects.count))
        if isDefault { defaultEffect = effect.id }
        if isDictation { dictationEffect = effect.id }
    }

    // MARK: Graphics

    /// Copies image files in for graphic overlays, keeping their names
    /// readable; returns the names they're kept under.
    func importGraphics(_ urls: [URL]) -> [String] {
        do {
            try FileManager.default.createDirectory(at: Self.graphicsFolder, withIntermediateDirectories: true)
        } catch {
            log.error("Couldn't make the graphics folder: \(error)")
            return []
        }
        return urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
            do {
                try FileManager.default.copyItem(at: url, to: Self.graphicsFolder.appending(path: name))
                return name
            } catch {
                log.error("Couldn't import \(url.lastPathComponent, privacy: .public): \(error)")
                return nil
            }
        }
    }

    /// A kept graphic's original file name.
    static func displayName(ofGraphic name: String) -> String {
        String(name.drop { $0 != "-" }.dropFirst())
    }

    /// Deletes graphics no effect uses any more, at launch rather than as
    /// they go, so undoing a delete finds them. Duplicates share their
    /// files, so a file goes only when nothing points at it.
    private func pruneGraphics(keeping used: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.graphicsFolder.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: Self.graphicsFolder.appending(path: file))
        }
    }

    // MARK: What shows

    private func parts(of entry: Entry) -> [Effect] {
        if entry.source == .live { return parts(of: live) }
        return effect(entry.effect).map { parts(of: $0) } ?? []
    }

    /// What an entry sets, so a later one can be seen to cover all of it:
    /// its overlays' spots, a push-in, and the look settings it changes.
    private func slots(of entry: Entry) -> Set<String> {
        var slots: Set<String> = []
        for part in parts(of: entry) {
            for overlay in part.overlays where overlay.canShow { slots.insert("spot \(overlay.spot)") }
            if part.pushIn != nil { slots.insert("push-in") }
            if let look = part.look { slots.formUnion(look.changes.map { "look \($0)" }) }
        }
        return slots
    }

    /// Keeps the stack true to edits: an effect deleted goes from it.
    private func reconcile() {
        let ids = Set(effects.map(\.id))
        stack.removeAll { $0.source != .live && !ids.contains($0.effect) }
        rebuild()
    }

    /// The default effect at the bottom, unless it's off for now.
    private func placeDefault() {
        let wanted = defaultOff ? nil : defaultEffect.flatMap(effect)?.id
        if let first = stack.first, first.source == .base {
            if first.effect == wanted { return }
            stack.removeFirst()
        }
        if let wanted { stack.insert(Entry(effect: wanted, source: .base), at: 0) }
    }

    /// Works out what shows from the stack.
    private func rebuild() {
        placeDefault()
        var spots: [Overlay.Spot: (overlay: Overlay, variant: Int, token: UUID)] = [:]
        var pushIn: (zoom: Double, source: UUID)?
        var looks: [(look: Look, source: UUID)] = []
        var entries = stack
        for index in entries.indices {
            let token = entries[index].token
            for part in parts(of: entries[index]) {
                for overlay in part.overlays where overlay.canShow {
                    let variant = variant(of: overlay, in: &entries[index])
                    spots[overlay.spot] = (overlay, variant, token)
                }
                if let zoom = part.pushIn { pushIn = (zoom, UUID.combining([token, part.id])) }
                if let look = part.look { looks.append((look, part.id)) }
            }
        }
        if entries != stack { stack = entries }
        zoom = pushIn?.zoom ?? 1
        zoomSource = pushIn?.source
        look = Look.merged(looks.map(\.look), id: UUID.combining(looks.map(\.source)))
        let order = [Overlay.Spot.fullFrame] + Overlay.Spot.allCases.filter { $0 != .fullFrame }
        var keys = Set<String>()
        scene = order.compactMap { spot in
            guard let (overlay, variant, token) = spots[spot] else { return nil }
            // Any edit to the overlay changes its hash, so a fresh render.
            let key = "\(token)-\(overlay.id)-\(variant)-\(overlay.hashValue)"
            keys.insert(key)
            if rendered[key] == nil {
                rendered[key] = Self.frameSizes.reduce(into: [:]) { images, size in
                    images[Int32(size.height)] = OverlayRenderer.render(overlay, variant: variant, frame: size)
                }
            }
            guard let images = rendered[key], !images.isEmpty else { return nil }
            return OverlayLayer(key: key, spot: spot, images: images)
        }
        rendered = rendered.filter { keys.contains($0.key) }
    }

    /// The line or image an overlay shows for this turn-on: the one it
    /// picked, if it still can, else a fresh pick, at random, never the one
    /// shown last time.
    private func variant(of overlay: Overlay, in entry: inout Entry) -> Int {
        if let picked = entry.variants[overlay.id], overlay.shows(picked) { return picked }
        let showable = (0..<overlay.variants).filter(overlay.shows)
        let choices = showable.count > 1 ? showable.filter { $0 != lastVariant[overlay.id] } : showable
        let choice = choices.randomElement() ?? 0
        lastVariant[overlay.id] = choice
        entry.variants[overlay.id] = choice
        return choice
    }

    /// Frame sizes Vaux Camera sends.
    private static let frameSizes = CameraSpec.sizes.map { CGSize(width: Int($0.width), height: Int($0.height)) }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(effects: effects, defaultEffect: defaultEffect, dictationEffect: dictationEffect, live: live))
            try data.write(to: Self.file, options: .atomic)
        } catch {
            log.error("Couldn't save effects: \(error)")
        }
    }
}

extension UUID {
    /// One ID standing for several, in order: the same ones give the same.
    static func combining(_ ids: [UUID]) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, id) in ids.enumerated() {
            withUnsafeBytes(of: id.uuid) { raw in
                for byte in 0..<16 { bytes[(byte + index) % 16] ^= raw[byte] &+ UInt8(truncatingIfNeeded: index) }
            }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
