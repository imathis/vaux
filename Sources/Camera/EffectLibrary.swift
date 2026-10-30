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
    /// A video instead, drawn frame by frame.
    var video: OverlayVideo?

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
}

/// Your effects, and which are on: the call's (see EffectStage), or, while
/// the preview's open, the preview's. Effects you turn on show there then,
/// and the call stays as it was, edits and all, until it closes.
@MainActor @Observable
final class EffectLibrary {
    var effects: [Effect] {
        didSet {
            save()
            for stage in stages { stage.edited() }
        }
    }

    /// On under everything else, unless turned off for now.
    var defaultEffect: UUID? {
        didSet {
            save()
            for stage in stages { stage.edited(newDefault: defaultEffect != oldValue) }
        }
    }

    /// On while you dictate (solo mode), so the call knows why you're muted.
    var dictationEffect: UUID? {
        didSet { save() }
    }

    /// Groups effects go in (see `listing`).
    var groups: [EffectGroup] {
        didSet { save() }
    }

    /// Effects in no group, and groups, by ID, in the order they're listed;
    /// a group's effects go under it, in `effects`' order. Ones it doesn't
    /// have yet (just added) go at the end.
    var outline: [UUID] {
        didSet { save() }
    }

    /// The Live panel's: text typed on the spot, a push-in, and an effect to
    /// go with them. One, outside the list.
    var live: Effect {
        didSet {
            save()
            for stage in stages { stage.edited() }
        }
    }

    /// What the call shows.
    @ObservationIgnored private(set) var call: EffectStage!
    /// The preview window's, while it's open.
    private(set) var preview: EffectStage?

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
        /// Saved before there were groups: none.
        var groups: [EffectGroup]?
        var outline: [UUID]?
    }

    init() {
        let stored = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            ?? Self.migrated()
        effects = stored.effects
        defaultEffect = stored.defaultEffect
        dictationEffect = stored.dictationEffect
        live = stored.live
        groups = stored.groups ?? []
        outline = stored.outline ?? []
        // The Live panel edits its one text overlay.
        if live.overlays.first?.kind != .text { live.overlays.insert(.live, at: 0) }
        if !FileManager.default.fileExists(atPath: Self.file.path) { save() }
        pruneGraphics(keeping: Set((effects + [live]).flatMap(\.overlays).flatMap(\.images)))
        call = EffectStage(library: self)
    }

    func effect(_ id: UUID) -> Effect? { effects.first { $0.id == id } }

    /// Everything that's kept, as saved and backed up.
    var stored: Stored {
        Stored(effects: effects, defaultEffect: defaultEffect, dictationEffect: dictationEffect, live: live, groups: groups, outline: outline)
    }

    /// Replaced by a backup's: effects, groups, Live, and the default and
    /// dictation ones.
    func restore(_ stored: Stored) {
        groups = stored.groups ?? []
        outline = stored.outline ?? []
        effects = stored.effects
        var live = stored.live
        // The Live panel edits its one text overlay.
        if live.overlays.first?.kind != .text { live.overlays.insert(.live, at: 0) }
        self.live = live
        defaultEffect = stored.defaultEffect
        dictationEffect = stored.dictationEffect
    }

    // MARK: Groups

    /// What's listed, in order: effects in no group, and groups with
    /// theirs.
    enum Listing {
        case effect(Effect)
        case group(EffectGroup, [Effect])
    }

    /// As `outline` has them; any it doesn't, at the end.
    var listing: [Listing] {
        let known = Set(groups.map(\.id))
        let loose = effects.filter { $0.group.map { !known.contains($0) } ?? true }
        let looseIDs = Set(loose.map(\.id))
        var placed = Set<UUID>()
        var listing: [Listing] = []
        func place(_ group: EffectGroup) {
            if placed.insert(group.id).inserted { listing.append(.group(group, effects.filter { $0.group == group.id })) }
        }
        for id in outline {
            if let group = group(id) {
                place(group)
            } else if looseIDs.contains(id), let effect = effect(id), placed.insert(id).inserted {
                listing.append(.effect(effect))
            }
        }
        for effect in loose where placed.insert(effect.id).inserted { listing.append(.effect(effect)) }
        for group in groups { place(group) }
        return listing
    }

    /// Effects in the order they're listed everywhere, groups' in their
    /// place.
    var ordered: [Effect] {
        listing.flatMap { listed -> [Effect] in
            switch listed {
            case .effect(let effect): [effect]
            case .group(_, let effects): effects
            }
        }
    }

    /// The list rearranged at once: effects in their new order and groups,
    /// the groups in theirs, and the outline of the two.
    func arrange(effects: [Effect], groups: [EffectGroup], outline: [UUID]) {
        self.groups = groups
        self.outline = outline
        self.effects = effects
    }

    func group(_ id: UUID) -> EffectGroup? { groups.first { $0.id == id } }

    /// Its color: its own, or the one for its place among the groups.
    func tint(of group: EffectGroup) -> Effect.Tint {
        group.color ?? Effect.Tint.byPlace[(groups.firstIndex { $0.id == group.id } ?? 0) % Effect.Tint.byPlace.count]
    }

    /// A new group at the end, named apart from the others.
    @discardableResult
    func addGroup(named name: String = "New Group") -> EffectGroup {
        let names = Set(groups.map(\.name))
        var group = EffectGroup(name: name)
        if names.contains(name) {
            group.name = (2...).lazy.map { "\(name) \($0)" }.first { !names.contains($0) }!
        }
        groups.append(group)
        return group
    }

    /// Its effects stay where it was, in no group.
    func removeGroup(_ id: UUID) {
        let members = effects.filter { $0.group == id }.map(\.id)
        if let index = outline.firstIndex(of: id) { outline.replaceSubrange(index...index, with: members) }
        groups.removeAll { $0.id == id }
        effects = effects.map { effect in
            var effect = effect
            if effect.group == id { effect.group = nil }
            return effect
        }
    }

    /// Into a group (or none), at its end.
    func move(_ id: UUID, toGroup group: UUID?) {
        guard var effect = effect(id), effect.group != group else { return }
        effect.group = group
        var effects = effects.filter { $0.id != id }
        effects.append(effect)
        self.effects = effects
    }

    /// Its color: its own, or the one for its place in the list.
    func tint(of effect: Effect) -> Effect.Tint {
        effect.shownTint(atPlace: effects.firstIndex { $0.id == effect.id } ?? 0)
    }

    /// The furthest any effect (or Live) pushes in: the camera runs in a
    /// mode that keeps it sharp, so pushing in never switches modes mid-call.
    var furthest: Double { max((effects + [live]).compactMap(\.pushIn).max() ?? 1, 1) }

    /// The most room any shake needs, as a zoom; the same goes for it.
    var furthestShake: Double { (effects + [live]).compactMap(\.shake?.zoom).max() ?? 1 }

    /// An effect and what it builds on, in the order they stack: what it
    /// includes first (each with what that includes), then itself. Each
    /// once, so one that would include itself stops there.
    func parts(of effect: Effect) -> [Effect] { Self.parts(of: effect, finding: self.effect) }

    /// The same, finding what it includes by ID among a given set.
    static func parts(of effect: Effect, finding: (UUID) -> Effect?) -> [Effect] {
        var seen: Set<UUID> = []
        var parts: [Effect] = []
        func add(_ effect: Effect) {
            guard seen.insert(effect.id).inserted else { return }
            for id in effect.includes {
                if let included = finding(id) { add(included) }
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

    /// Where effects you turn on go: the preview while it's open, else the
    /// call.
    var stage: EffectStage { preview ?? call }

    private var stages: [EffectStage] { [call] + (preview.map { [$0] } ?? []) }

    /// On: in the stack, as itself (built on by another doesn't count).
    func isOn(_ id: UUID) -> Bool { stage.isOn(id) }

    /// Something's on besides the default and dictation.
    var anythingOn: Bool { stage.anythingOn }

    var liveOn: Bool { stage.liveOn }

    /// See EffectStage.turnOn.
    @discardableResult
    func turnOn(_ id: UUID) -> UUID? { stage.turnOn(id) }

    func turnOff(_ id: UUID) { stage.turnOff(id) }

    /// A held key let go, or a duration up, wherever it went.
    func takeOff(_ token: UUID) {
        for stage in stages { stage.takeOff(token) }
    }

    /// A tap, not a hold: see EffectStage.settle.
    func settle(_ token: UUID) {
        for stage in stages { stage.settle(token) }
    }

    func setLive(_ on: Bool) { stage.setLive(on) }

    /// Dictating is for real: the call shows it.
    func setDictating(_ dictating: Bool) { call.setDictating(dictating) }

    func clearAll() { stage.clearAll() }

    func endCall() { call.endCall() }

    /// The preview opens with what the call has on, and from then on takes
    /// what you turn on; the call holds still, edits and all.
    func openPreview() {
        guard preview == nil else { return }
        call.freeze()
        preview = EffectStage(library: self, copying: call)
    }

    /// The call picks up edits made meanwhile.
    func closePreview() {
        guard preview != nil else { return }
        preview = nil
        call.thaw()
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

    func save() {
        // Snapshots may change things to draw them; yours stay as they are.
        guard !Snapshot.isRunning else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
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
