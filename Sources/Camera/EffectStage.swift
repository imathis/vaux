import CoreGraphics
import Foundation
import Observation

/// Which effects are on, for one picture: the call's, or the preview's while
/// it's open. One of yours is on at a time, over the default effect:
/// turning another on replaces it. (Layering effects is done in the editor,
/// an effect building on others.) Over those go, while they last, a held
/// key's effect, the dictation effect while you dictate, and the Live
/// panel's while it's up. What shows comes from that stack, each part from
/// the latest that sets it: overlays by spot, the push-in, the shake, and
/// look by look setting. A held key adds its effect only while held, so
/// what it covered was never gone.
@MainActor @Observable
final class EffectStage {
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
    private(set) var shake: Effect.Shake?
    /// For a shake that builds up, the seconds it takes: three quarters of
    /// its effect's time on, so it's at full long enough to see. None for one
    /// that stays on: it eases straight in.
    private(set) var shakeBuild: Double?
    /// What set the zoom, the push-in and the shake (which needs room): a
    /// new one eases there, an edit to the same one moves at once.
    private(set) var zoomSource: UUID?
    /// How a new zoom moves there: the push-in's own way (the shake's, for
    /// one that only needs room).
    private(set) var zoomMove = Effect.Move()
    /// One you turned on mutes the mic while it's on (or builds on one that
    /// does). The default and dictation effects never do.
    private(set) var mutesMic = false

    @ObservationIgnored private unowned let library: EffectLibrary
    /// Effects, Live and the default as they were when frozen: edits wait
    /// until it thaws.
    @ObservationIgnored private var frozen: (effects: [Effect], live: Effect, defaultEffect: UUID?)?
    @ObservationIgnored private var lastVariant: [UUID: Int] = [:]
    @ObservationIgnored private var rendered: [String: [Int32: CGImage]] = [:]
    @ObservationIgnored private var videos: [String: OverlayVideo] = [:]

    /// Empty but for the default, or with what `stage` has on (but
    /// dictating, which the call's alone follows).
    init(library: EffectLibrary, copying stage: EffectStage? = nil) {
        self.library = library
        if let stage {
            stack = stage.stack.filter { $0.source != .dictation }
            defaultOff = stage.defaultOff
            lastVariant = stage.lastVariant
        }
        rebuild()
    }

    private var effects: [Effect] { frozen?.effects ?? library.effects }
    private var live: Effect { frozen?.live ?? library.live }
    private var defaultEffect: UUID? { frozen.map(\.defaultEffect) ?? library.defaultEffect }
    private func effect(_ id: UUID) -> Effect? { effects.first { $0.id == id } }
    private func parts(of effect: Effect) -> [Effect] { EffectLibrary.parts(of: effect) { self.effect($0) } }

    /// Holds what shows as it is, edits and all, until thawed: the call's,
    /// while the preview's open. Effects still come and go: one timing out,
    /// dictation.
    func freeze() {
        frozen = (library.effects, library.live, library.defaultEffect)
    }

    func thaw() {
        if frozen?.defaultEffect != library.defaultEffect { defaultOff = false }
        frozen = nil
        reconcile()
    }

    /// The library changed: effects, Live, the default (a new one, back on).
    func edited(newDefault: Bool = false) {
        guard frozen == nil else { return }
        if newDefault { defaultOff = false }
        reconcile()
    }

    // MARK: On and off

    /// On: in the stack, as itself (built on by another doesn't count).
    func isOn(_ id: UUID) -> Bool { stack.contains { $0.effect == id && $0.source != .live } }

    /// Something's on besides the default and dictation.
    var anythingOn: Bool { stack.contains { $0.source == .user || $0.source == .live } }

    var liveOn: Bool { stack.contains { $0.source == .live } }

    /// Turns an effect on, over everything on (a tap then settles it,
    /// replacing the one that was on). Returns its place in the stack, to
    /// take it off again after a hold; nil if it's the default coming back
    /// on, which isn't held.
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
            // From every stage: the preview may have picked it up.
            Task { [weak library] in
                try? await Task.sleep(for: .seconds(duration))
                library?.takeOff(entry.token)
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

    /// Takes one turn-on back off: a held key let go, or a duration up.
    func takeOff(_ token: UUID) {
        guard stack.contains(where: { $0.token == token }) else { return }
        stack.removeAll { $0.token == token }
        rebuild()
    }

    /// A turn-on that stays (a tap, not a hold): it replaces the effect of
    /// yours that was on, so one's on at a time. One that turns itself off
    /// goes over it instead, like a hold, and what was on shows again after.
    func settle(_ token: UUID) {
        guard let entry = stack.first(where: { $0.token == token }), effect(entry.effect)?.duration == nil,
              stack.contains(where: { $0.source == .user && $0.token != token })
        else { return }
        stack.removeAll { $0.source == .user && $0.token != token }
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
        if dictating, let dictationEffect = library.dictationEffect, effect(dictationEffect) != nil {
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
    /// that push in (or shake) go.
    func endCall() {
        let pushing = stack.filter { ($0.source == .user || $0.source == .live) && parts(of: $0).contains { $0.pushIn != nil || $0.shake != nil } }
        guard !pushing.isEmpty else { return }
        let tokens = Set(pushing.map(\.token))
        stack.removeAll { tokens.contains($0.token) }
        rebuild()
    }

    // MARK: What shows

    private func parts(of entry: Entry) -> [Effect] {
        if entry.source == .live { return parts(of: live) }
        return effect(entry.effect).map { parts(of: $0) } ?? []
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
        var shaking: (shake: Effect.Shake, source: UUID)?
        var building: Double?
        var moving = Effect.Move()
        var looks: [(look: Look, source: UUID)] = []
        var entries = stack
        for index in entries.indices {
            let token = entries[index].token
            for part in parts(of: entries[index]) {
                for overlay in part.overlays where overlay.canShow {
                    let variant = variant(of: overlay, in: &entries[index])
                    spots[overlay.spot] = (overlay, variant, token)
                }
                if let zoom = part.pushIn {
                    pushIn = (zoom, UUID.combining([token, part.id]))
                    moving = part.pushInMove
                }
                if let shake = part.shake {
                    shaking = (shake, UUID.combining([token, part.id]))
                    if pushIn == nil { moving = part.pushInMove }
                    building = shake.builds ? effect(entries[index].effect)?.duration.map { 0.75 * $0 } : nil
                }
                if let look = part.look { looks.append((look, part.id)) }
            }
        }
        if entries != stack { stack = entries }
        zoom = pushIn?.zoom ?? 1
        shake = shaking?.shake
        shakeBuild = building
        zoomMove = moving
        let muting = stack.contains { $0.source == .user && parts(of: $0).contains(where: \.mutesMic) }
        if muting != mutesMic { mutesMic = muting }
        let zoomSources = [pushIn?.source, shaking?.source].compactMap { $0 }
        zoomSource = zoomSources.isEmpty ? nil : UUID.combining(zoomSources)
        look = Look.merged(looks.map(\.look), id: UUID.combining(looks.map(\.source)))
        let order = [Overlay.Spot.fullFrame] + Overlay.Spot.allCases.filter { $0 != .fullFrame }
        var keys = Set<String>()
        scene = order.compactMap { spot in
            guard let (overlay, variant, token) = spots[spot] else { return nil }
            // Any edit to the overlay changes its hash, so a fresh render.
            let key = "\(token)-\(overlay.id)-\(variant)-\(overlay.hashValue)"
            keys.insert(key)
            // A video plays on from where it is while it's the same showing.
            if overlay.kind == .graphic, overlay.images.indices.contains(variant), OverlayVideo.isVideo(overlay.images[variant]) {
                if videos[key] == nil { videos[key] = OverlayVideo(overlay.images[variant], overlay: overlay) }
                return videos[key].map { OverlayLayer(key: key, spot: spot, images: [:], video: $0) }
            }
            if rendered[key] == nil {
                rendered[key] = Self.frameSizes.reduce(into: [:]) { images, size in
                    images[Int32(size.height)] = OverlayRenderer.render(overlay, variant: variant, frame: size)
                }
            }
            guard let images = rendered[key], !images.isEmpty else { return nil }
            return OverlayLayer(key: key, spot: spot, images: images)
        }
        rendered = rendered.filter { keys.contains($0.key) }
        videos = videos.filter { keys.contains($0.key) }
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
}
