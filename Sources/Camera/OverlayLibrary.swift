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

/// The user's overlays, and which are showing: one per spot, so a new one
/// replaces what's in its spot and different spots show together.
@MainActor @Observable
final class OverlayLibrary {
    var overlays: [Overlay] {
        didSet {
            save()
            reconcile()
        }
    }

    /// Shown while you dictate (solo mode).
    var dictationOverlay: UUID? {
        didSet { save() }
    }

    /// The Live panel's overlay: one, outside the list, its text typed on
    /// the spot.
    var live: Overlay {
        didSet {
            save()
            reconcile()
        }
    }

    /// The Live text is up. It keeps its spot while it's on, even when an
    /// edit leaves it nothing to draw for a moment (no text, no icon), so
    /// it's back as soon as there is.
    private(set) var liveOn = false

    /// What's showing, by spot.
    private(set) var showing: [Overlay.Spot: Showing] = [:]
    /// What to draw, full frame first.
    private(set) var scene: [OverlayLayer] = []

    struct Showing: Equatable {
        let overlay: UUID
        let variant: Int
        /// This showing in particular: an auto-hide only hides its own.
        let token: UUID
    }

    /// The showing dictation started, so ending it hides only that one.
    @ObservationIgnored private var dictationShowing: UUID?
    @ObservationIgnored private var lastVariant: [UUID: Int] = [:]
    @ObservationIgnored private var rendered: [String: [Int32: CGImage]] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "dev.imathis.vaux", category: "overlays")

    /// Vaux Dev keeps its own.
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.imathis.vaux", directoryHint: .isDirectory)
    }

    /// Where imported graphics are kept.
    static var graphicsFolder: URL { folder.appending(path: "Graphics", directoryHint: .isDirectory) }
    private static var file: URL { folder.appending(path: "overlays.json") }

    private struct Stored: Codable {
        var overlays: [Overlay]
        var dictationOverlay: UUID?
        var live: Overlay?
    }

    /// Saved before lines had their own icons: one icon per overlay.
    private struct OldIcons: Decodable {
        struct Entry: Decodable {
            let id: UUID
            let icon: String?
        }

        let overlays: [Entry]
        let live: Entry?

        var byOverlay: [UUID: String] {
            ((live.map { [$0] } ?? []) + overlays).reduce(into: [:]) { icons, entry in icons[entry.id] = entry.icon }
        }
    }

    init() {
        if let data = try? Data(contentsOf: Self.file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            let icons = (try? JSONDecoder().decode(OldIcons.self, from: data))?.byOverlay ?? [:]
            overlays = stored.overlays.map { Self.updated($0, icon: icons[$0.id]) }
            dictationOverlay = stored.dictationOverlay
            live = stored.live.map { Self.updated($0, icon: icons[$0.id]) } ?? .live
        } else {
            // First run: the original badge, shown while dictating.
            let dictating = Overlay.dictating
            overlays = [dictating]
            dictationOverlay = dictating.id
            live = .live
            save()
        }
        pruneGraphics(keeping: Set(overlays.flatMap(\.images) + live.images))
    }

    /// An overlay as an earlier Vaux saved it, brought up to date.
    private static func updated(_ overlay: Overlay, icon: String?) -> Overlay {
        var overlay = overlay
        // Text no longer comes small: those are medium now.
        if overlay.kind == .text, !Overlay.Size.textSizes.contains(overlay.size) { overlay.size = .medium }
        // Its one icon goes on each of its lines.
        if let icon {
            for index in overlay.lines.indices where overlay.lines[index].icon == nil { overlay.lines[index].icon = icon }
        }
        return overlay
    }

    func overlay(_ id: UUID) -> Overlay? { overlays.first { $0.id == id } ?? (live.id == id ? live : nil) }

    func isShowing(_ id: UUID) -> Bool { showing.values.contains { $0.overlay == id } }

    func toggle(_ id: UUID) {
        if isShowing(id) { hide(id) } else { show(id) }
    }

    /// Shows an overlay in its spot, replacing what's there, with a fresh
    /// pick from its lines or images.
    /// Returns what was in the spot, so a held key can put it back.
    @discardableResult
    func show(_ id: UUID) -> Showing? {
        guard let overlay = overlay(id), overlay.canShow else { return nil }
        let replaced = showing[overlay.spot]
        if replaced?.overlay == live.id { liveOn = false }
        let token = UUID()
        showing[overlay.spot] = Showing(overlay: id, variant: pick(from: overlay), token: token)
        rebuild()
        if let duration = overlay.duration {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard let self, showing[overlay.spot]?.token == token else { return }
                showing[overlay.spot] = nil
                rebuild()
            }
        }
        return replaced
    }

    /// Puts back what a held overlay replaced, if its spot is free again and
    /// the overlay still exists. The same showing, so dictation ending still
    /// hides it if dictation put it there.
    func restore(_ shown: Showing) {
        guard let overlay = overlay(shown.overlay), showing[overlay.spot] == nil else { return }
        showing[overlay.spot] = shown
        if shown.overlay == live.id { liveOn = true }
        rebuild()
    }

    /// Puts the Live text up in its spot (replacing what's there), or takes
    /// it down.
    func setLive(_ on: Bool) {
        for (spot, shown) in showing where shown.overlay == live.id { showing[spot] = nil }
        if on { showing[live.spot] = Showing(overlay: live.id, variant: 0, token: UUID()) }
        liveOn = on
        rebuild()
    }

    /// Dictation started or ended: shows the "while dictating" overlay, then
    /// hides it, unless something else has taken its spot meanwhile.
    func setDictating(_ dictating: Bool) {
        if dictating {
            guard let id = dictationOverlay, let overlay = overlay(id) else { return }
            show(id)
            dictationShowing = showing[overlay.spot]?.token
        } else if let token = dictationShowing {
            for (spot, shown) in showing where shown.token == token { showing[spot] = nil }
            dictationShowing = nil
            rebuild()
        }
    }

    func hide(_ id: UUID) {
        for (spot, shown) in showing where shown.overlay == id { showing[spot] = nil }
        if id == live.id { liveOn = false }
        rebuild()
    }

    func clearAll() {
        guard !showing.isEmpty else { return }
        showing = [:]
        liveOn = false
        rebuild()
    }

    @discardableResult
    func add(_ kind: Overlay.Kind) -> Overlay {
        let overlay = Overlay(
            name: kind == .text ? "New Text" : "New Graphic",
            kind: kind,
            lines: kind == .text ? [Overlay.Line(text: "Be right back")] : [],
            spot: kind == .text ? .bottom : .bottomTrailing
        )
        overlays.append(overlay)
        return overlay
    }

    /// A copy beside it.
    @discardableResult
    func duplicate(_ id: UUID) -> Overlay? {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = overlays[index]
        copy.id = UUID()
        copy.name += " Copy"
        overlays.insert(copy, at: index + 1)
        return copy
    }

    func remove(_ id: UUID) {
        hide(id)
        if dictationOverlay == id { dictationOverlay = nil }
        overlays.removeAll { $0.id == id }
    }

    /// Undoing a delete: back in its place, and shown while dictating if it
    /// was. Its graphics are still there (see pruneGraphics).
    func restore(_ overlay: Overlay, at index: Int, dictation: Bool) {
        overlays.insert(overlay, at: min(index, overlays.count))
        if dictation { dictationOverlay = overlay.id }
    }

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

    /// Deletes graphics no overlay uses any more, at launch rather than as
    /// they go, so undoing a delete finds them. Duplicated overlays share
    /// their files, so a file goes only when nothing points at it.
    private func pruneGraphics(keeping used: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.graphicsFolder.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: Self.graphicsFolder.appending(path: file))
        }
    }

    /// A line or image, at random, never the one shown last time.
    private func pick(from overlay: Overlay) -> Int {
        let showable = (0..<overlay.variants).filter(overlay.shows)
        let choices = showable.count > 1 ? showable.filter { $0 != lastVariant[overlay.id] } : showable
        let choice = choices.randomElement() ?? 0
        lastVariant[overlay.id] = choice
        return choice
    }

    /// Keeps what's showing true to edits: an overlay that moved spots moves
    /// with them; one deleted, or emptied, goes.
    private func reconcile() {
        for (spot, shown) in showing {
            // Live stays while it's on, drawn or not (see liveOn).
            guard let overlay = overlay(shown.overlay), overlay.canShow || overlay.id == live.id else {
                showing[spot] = nil
                continue
            }
            if overlay.spot != spot {
                showing[spot] = nil
                showing[overlay.spot] = shown
            }
            if shown.variant >= overlay.variants {
                showing[overlay.spot] = Showing(overlay: shown.overlay, variant: 0, token: shown.token)
            }
        }
        rebuild()
    }

    private func rebuild() {
        let order = [Overlay.Spot.fullFrame] + Overlay.Spot.allCases.filter { $0 != .fullFrame }
        var keys = Set<String>()
        scene = order.compactMap { spot in
            guard let shown = showing[spot], let overlay = overlay(shown.overlay) else { return nil }
            // Any edit to the overlay changes its hash, so a fresh render.
            let key = "\(shown.token)-\(shown.variant)-\(overlay.hashValue)"
            keys.insert(key)
            if rendered[key] == nil {
                rendered[key] = Self.frameSizes.reduce(into: [:]) { images, size in
                    images[Int32(size.height)] = OverlayRenderer.render(overlay, variant: shown.variant, frame: size)
                }
            }
            guard let images = rendered[key], !images.isEmpty else { return nil }
            return OverlayLayer(key: key, spot: spot, images: images)
        }
        rendered = rendered.filter { keys.contains($0.key) }
    }

    /// Frame sizes Vaux Camera sends.
    private static let frameSizes = CameraSpec.sizes.map { CGSize(width: Int($0.width), height: Int($0.height)) }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(overlays: overlays, dictationOverlay: dictationOverlay, live: live))
            try data.write(to: Self.file, options: .atomic)
        } catch {
            log.error("Couldn't save overlays: \(error)")
        }
    }
}
