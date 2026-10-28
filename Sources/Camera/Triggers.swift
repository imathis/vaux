import Foundation
import KeyboardShortcuts
import Observation

/// Everything that can be triggered (Mute, Live, each effect, and Clear All)
/// and the keys for it: a global shortcut each, and a one-key code in the
/// Quick Menu. One list behind the Quick Menu, the Shortcuts tab and Stream
/// Deck alike.
///
/// A key tapped toggles its effect. Held, the effect lasts only while it's
/// held, then whatever it covered shows again. Mute just toggles, as its
/// shortcut always has (AppState listens for that).
@MainActor @Observable
final class Triggers {
    struct Item: Identifiable, Equatable {
        enum Action: Equatable {
            case mute
            /// Opens the Live panel.
            case live
            case effect(UUID)
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
    private let library: EffectLibrary
    /// Quick Menu keys set by hand, by item ID; the rest are given in order.
    private(set) var customKeys: [String: String]
    /// Opens the Live panel (set by Effects, which owns it).
    @ObservationIgnored var openLive: (() -> Void)?
    /// Item IDs whose shortcuts are being listened for.
    @ObservationIgnored private var listening: Set<String> = []
    /// Keys down now, by item ID.
    @ObservationIgnored private var presses: [String: Press] = [:]

    /// A key that's down: when, and the effect it turned on, if it did, to
    /// take off again if it turns out to be held.
    private struct Press {
        let start = Date.now
        let turnedOn: UUID?
    }

    /// Held at least this long, a key's effect lasts only while it's held.
    static let holdSeconds = 0.35
    private static let keysKey = "quickMenuKeys"

    init(appState: AppState, library: EffectLibrary) {
        self.appState = appState
        self.library = library
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
        }
    }

    var items: [Item] {
        [
            Item(id: Self.id(of: .mute), action: .mute, title: "Mute", isOn: appState.muted),
            Item(id: Self.id(of: .live), action: .live, title: "Live…", isOn: library.liveOn),
        ]
        + library.effects.map { effect in
            let action = Item.Action.effect(effect.id)
            return Item(id: Self.id(of: action), action: action, title: effect.name, isOn: library.isOn(effect.id))
        }
        + [Item(id: Item.clearAllName.rawValue, action: .clearAll, title: "Clear all", isOn: false)]
    }

    /// Each item's Quick Menu key: set by hand, or given in order. Mute gets
    /// M, Live L, effects 1–9 then letters, Clear All 0.
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
        let letters = "QWERTYUIOPASDFGHJKLZXCVBNM".map(String.init)
        for item in items where keys[item.id] == nil {
            keys[item.id] = switch item.action {
            case .mute: next(from: ["M"] + letters)
            case .live: next(from: ["L"] + letters)
            case .effect: next(from: digits + letters)
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

    /// Its key went down: turns its effect off if it's on, else on, on top.
    func press(_ action: Item.Action) {
        let id = Self.id(of: action)
        // Key repeat while held.
        guard presses[id] == nil else { return }
        switch action {
        case .mute: appState.toggle()
        case .live: openLive?()
        case .clearAll: library.clearAll()
        case .effect(let effect):
            if library.isOn(effect) {
                library.turnOff(effect)
                presses[id] = Press(turnedOn: nil)
            } else {
                presses[id] = Press(turnedOn: library.turnOn(effect))
            }
        }
    }

    /// Its key came up. Held long enough, the effect it turned on goes, and
    /// what it covered shows again; a tap leaves it on.
    func release(_ action: Item.Action) {
        guard let press = presses.removeValue(forKey: Self.id(of: action)), let token = press.turnedOn else { return }
        if Date.now.timeIntervalSince(press.start) >= Self.holdSeconds {
            library.takeOff(token)
        } else {
            library.settle(token)
        }
    }

    /// An item's ID, which names its shortcut and its Quick Menu key.
    static func id(of action: Item.Action) -> String {
        switch action {
        case .mute: KeyboardShortcuts.Name.toggleMicMute.rawValue
        case .live: Item.liveName.rawValue
        case .effect(let id): "effect-\(id)"
        case .clearAll: Item.clearAllName.rawValue
        }
    }

    /// Listens for each effect's shortcut, down and up, as effects come and
    /// go; a deleted one's shortcut and Quick Menu key go with it.
    private func followItems() {
        let actions = withObservationTracking {
            library.effects.map { Item.Action.effect($0.id) }
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
