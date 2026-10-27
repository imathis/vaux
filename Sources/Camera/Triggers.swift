import Foundation
import KeyboardShortcuts
import Observation

/// Everything that can be triggered (Mute, each overlay, each push-in level,
/// each combo, and Clear All) and the keys for it: a global shortcut each,
/// and a one-key code in the Quick Menu. One list behind the Quick Menu, the
/// Shortcuts tab and Stream Deck alike.
///
/// A key tapped toggles its effect. Held, the effect lasts only while it's
/// held, then whatever it replaced comes back. Mute just toggles, as its
/// shortcut always has (AppState listens for that).
@MainActor @Observable
final class Triggers {
    struct Item: Identifiable, Equatable {
        enum Action: Equatable {
            case mute
            /// Opens the Live panel.
            case live
            case overlay(UUID)
            case pushIn(UUID)
            case combo(UUID)
            case clearAll
        }

        /// Also its shortcut's name.
        let id: String
        let action: Action
        let title: String
        let isOn: Bool

        var shortcut: KeyboardShortcuts.Name { .init(id) }
    }

    /// Opens the Quick Menu.
    static let quickMenu = KeyboardShortcuts.Name("quickMenu", initial: .init(.period, modifiers: [.option]))

    private let appState: AppState
    private let overlays: OverlayLibrary
    private let zoom: ZoomShortcuts
    private let combos: ComboLibrary
    /// Quick Menu keys set by hand, by item ID; the rest are given in order.
    private(set) var customKeys: [String: String]
    /// Opens the Live panel (set by Effects, which owns it).
    @ObservationIgnored var openLive: (() -> Void)?
    /// Item IDs whose shortcuts are being listened for.
    @ObservationIgnored private var listening: Set<String> = []
    /// Keys down now, by item ID.
    @ObservationIgnored private var presses: [String: Press] = [:]

    /// A key that's down: whether it turned its effect on, and what to put
    /// back if it turns out to be held.
    private struct Press {
        let start = Date.now
        let turnedOn: Bool
        /// Overlays it showed, and what each replaced in its spot.
        var shown: [(overlay: UUID, replaced: OverlayLibrary.Showing?)] = []
        var pushIn: UUID?
        var previousZoom: UUID?
    }

    /// Held at least this long, a key's effect lasts only while it's held.
    static let holdSeconds = 0.35
    private static let keysKey = "quickMenuKeys"

    init(appState: AppState, overlays: OverlayLibrary, zoom: ZoomShortcuts, combos: ComboLibrary) {
        self.appState = appState
        self.overlays = overlays
        self.zoom = zoom
        self.combos = combos
        customKeys = UserDefaults.standard.dictionary(forKey: Self.keysKey) as? [String: String] ?? [:]
        KeyboardShortcuts.onKeyDown(for: Item.clearAllName) { [weak self] in self?.press(.clearAll) }
        KeyboardShortcuts.onKeyDown(for: Item.liveName) { [weak self] in self?.press(.live) }
        followItems()
        // The Quick Menu's default key may already be one of yours: yours wins.
        if let leader = KeyboardShortcuts.getShortcut(for: Self.quickMenu),
           items.contains(where: { KeyboardShortcuts.getShortcut(for: $0.shortcut) == leader }) {
            KeyboardShortcuts.setShortcut(nil, for: Self.quickMenu)
        }
    }

    /// A shortcut was just set on `name`: anything else with the same one
    /// loses it, so one key does one thing.
    func claim(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        guard let shortcut else { return }
        for other in items.map(\.shortcut) + [Self.quickMenu]
        where other != name && KeyboardShortcuts.getShortcut(for: other) == shortcut {
            KeyboardShortcuts.setShortcut(nil, for: other)
            if let level = zoom.levels.first(where: { $0.name == other }) { zoom.shortcutChanged(level, to: nil) }
        }
    }

    var items: [Item] {
        [
            Item(id: Self.id(of: .mute), action: .mute, title: "Mute", isOn: appState.muted),
            Item(id: Self.id(of: .live), action: .live, title: "Live…", isOn: overlays.liveOn || zoom.liveZoom != nil),
        ]
        + overlays.overlays.map { overlay in
            Item(id: "overlay-\(overlay.id)", action: .overlay(overlay.id), title: overlay.name, isOn: overlays.isShowing(overlay.id))
        }
        + zoom.levels.map { level in
            Item(id: level.name.rawValue, action: .pushIn(level.id), title: "Push in \(level.zoom.zoomText)", isOn: zoom.active == level.id)
        }
        + combos.combos.map { combo in
            let action = Item.Action.combo(combo.id)
            return Item(id: Self.id(of: action), action: action, title: combo.name, isOn: effect(of: action).map(isOn) ?? false)
        }
        + [Item(id: Item.clearAllName.rawValue, action: .clearAll, title: "Clear all overlays", isOn: false)]
    }

    /// Each item's Quick Menu key: set by hand, or given in order. Mute gets
    /// M, Live L, overlays 1–9 then letters, push-ins Z X C V…, combos
    /// A S D F…, Clear All 0.
    var keys: [String: String] {
        var keys: [String: String] = [:]
        let items = items
        for item in items {
            if let key = customKeys[item.id] { keys[item.id] = key }
        }
        var used = Set(keys.values)
        func next(from candidates: [String]) -> String? {
            guard let key = candidates.first(where: { !used.contains($0) }) else { return nil }
            used.insert(key)
            return key
        }
        let digits = (1...9).map(String.init)
        let letters = "QWERTYUIOPASDFGHJKL".map(String.init)
        for item in items where keys[item.id] == nil {
            keys[item.id] = switch item.action {
            case .mute: next(from: ["M"] + letters)
            case .live: next(from: ["L"] + letters)
            case .overlay: next(from: digits + letters)
            case .pushIn: next(from: "ZXCVBNM".map(String.init) + letters)
            case .combo: next(from: "ASDFGHJKL".map(String.init) + letters)
            case .clearAll: next(from: ["0"] + letters)
            }
        }
        return keys
    }

    func isCustom(_ id: String) -> Bool { customKeys[id] != nil }

    /// Sets an item's Quick Menu key, taking it from any other item that had
    /// it; nil goes back to the one given in order.
    func setKey(_ key: String?, for id: String) {
        if let key {
            customKeys = customKeys.filter { $0.value != key }
            customKeys[id] = key
        } else {
            customKeys[id] = nil
        }
        UserDefaults.standard.set(customKeys, forKey: Self.keysKey)
    }

    /// A tap: a click in the Quick Menu or the menu bar.
    func trigger(_ action: Item.Action) {
        press(action)
        release(action)
    }

    /// What an item does: overlays, each in its spot, and at most one push-in.
    /// One overlay or one level for those items; a combo's members (any
    /// deleted, or with nothing to show, skipped). Clear All has none.
    private struct Effect {
        var overlays: [UUID] = []
        var pushIn: UUID?

        var isEmpty: Bool { overlays.isEmpty && pushIn == nil }
    }

    private func effect(of action: Item.Action) -> Effect? {
        switch action {
        case .mute, .live:
            return nil
        case .overlay(let id):
            return Effect(overlays: [id])
        case .pushIn(let id):
            return Effect(pushIn: id)
        case .combo(let id):
            guard let combo = combos.combo(id) else { return nil }
            return Effect(
                overlays: combo.overlays.filter { overlays.overlay($0)?.canShow ?? false },
                pushIn: combo.pushIn.flatMap { level in zoom.levels.contains { $0.id == level } ? level : nil }
            )
        case .clearAll:
            return nil
        }
    }

    /// All of it showing.
    private func isOn(_ effect: Effect) -> Bool {
        !effect.isEmpty
            && effect.overlays.allSatisfy(overlays.isShowing)
            && effect.pushIn.map { zoom.active == $0 } ?? true
    }

    /// Its key went down: toggles the effect, all of it.
    func press(_ action: Item.Action) {
        let id = Self.id(of: action)
        // Key repeat while held.
        guard presses[id] == nil else { return }
        guard let effect = effect(of: action) else {
            if action == .clearAll { overlays.clearAll() }
            if action == .mute { appState.toggle() }
            if action == .live { openLive?() }
            return
        }
        if isOn(effect) {
            effect.overlays.forEach(overlays.hide)
            if let level = effect.pushIn, zoom.active == level { zoom.activate(nil) }
            presses[id] = Press(turnedOn: false)
            return
        }
        var press = Press(turnedOn: true)
        for overlay in effect.overlays where !overlays.isShowing(overlay) {
            press.shown.append((overlay, overlays.show(overlay)))
        }
        if let level = effect.pushIn, zoom.active != level {
            press.pushIn = level
            press.previousZoom = zoom.active
            zoom.activate(level)
        }
        presses[id] = press
    }

    /// Its key came up. Held long enough, what it turned on goes, and what
    /// that replaced comes back; a tap leaves it on.
    func release(_ action: Item.Action) {
        guard let press = presses.removeValue(forKey: Self.id(of: action)), press.turnedOn,
              Date.now.timeIntervalSince(press.start) >= Self.holdSeconds
        else { return }
        // Last shown first, so overlays sharing a spot unwind in order.
        for (overlay, replaced) in press.shown.reversed() where overlays.isShowing(overlay) {
            overlays.hide(overlay)
            if let replaced { overlays.restore(replaced) }
        }
        if let level = press.pushIn, zoom.active == level { zoom.activate(press.previousZoom) }
    }

    private static func id(of action: Item.Action) -> String {
        switch action {
        case .mute: KeyboardShortcuts.Name.toggleMicMute.rawValue
        case .live: Item.liveName.rawValue
        case .overlay(let id): "overlay-\(id)"
        case .pushIn(let id): ZoomShortcuts.Level.shortcut(for: id).rawValue
        case .combo(let id): "combo-\(id)"
        case .clearAll: Item.clearAllName.rawValue
        }
    }

    /// Listens for each overlay's, push-in level's and combo's shortcut, down
    /// and up, as they come and go; a deleted one's shortcut and Quick Menu
    /// key go with it.
    private func followItems() {
        let actions = withObservationTracking {
            overlays.overlays.map { Item.Action.overlay($0.id) }
                + zoom.levels.map { Item.Action.pushIn($0.id) }
                + combos.combos.map { Item.Action.combo($0.id) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followItems() }
        }
        let ids = Set(actions.map(Self.id(of:)))
        for action in actions where !listening.contains(Self.id(of: action)) {
            let name = KeyboardShortcuts.Name(Self.id(of: action))
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.press(action) }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.release(action) }
        }
        for id in listening.subtracting(ids) {
            let name = KeyboardShortcuts.Name(id)
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.reset(name)
            if customKeys[id] != nil { setKey(nil, for: id) }
        }
        listening = ids
    }
}

extension Triggers.Item {
    static let clearAllName = KeyboardShortcuts.Name("clearAll")
    static let liveName = KeyboardShortcuts.Name("live")
}
