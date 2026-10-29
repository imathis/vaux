import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

extension UTType {
    /// A `.vauxeffects` file (declared in Info.plist).
    static let vauxEffects = UTType(exportedAs: "dev.imathis.vaux.effects", conformingTo: .data)
}

/// Your effects in one file, to keep or pass on: the effects and groups,
/// Live, the default and dictation ones, the graphics and videos they show,
/// and the keys for them (shortcuts, the Quick Menu's and its tap key).
/// Not your mics and cameras: those belong to this Mac. A binary property
/// list, graphics as they are.
struct EffectsBackup: Codable {
    var version = 1
    var effects: EffectLibrary.Stored
    /// By file name in the graphics folder.
    var graphics: [String: Data]
    /// By trigger ID (and the Quick Menu's own).
    var shortcuts: [String: KeyboardShortcuts.Shortcut]
    var quickMenuKeys: [String: String]
    var quickMenuTap: String?

    /// Kept automatically before an import replaces your effects.
    @MainActor static var autoBackups: URL { EffectLibrary.folder.appending(path: "Backups", directoryHint: .isDirectory) }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> EffectsBackup {
        try PropertyListDecoder().decode(EffectsBackup.self, from: Data(contentsOf: url))
    }

    /// The graphics its effects (and Live) show.
    static func graphics(of stored: EffectLibrary.Stored) -> Set<String> {
        Set((stored.effects + [stored.live]).flatMap(\.overlays).flatMap(\.images))
    }
}

extension Effects {
    /// What's kept now, as a backup.
    func backup() -> EffectsBackup {
        let stored = library.stored
        let graphics = EffectsBackup.graphics(of: stored).reduce(into: [String: Data]()) { files, name in
            files[name] = try? Data(contentsOf: EffectLibrary.graphicsFolder.appending(path: name))
        }
        let names = triggers.items.map(\.shortcut) + [Triggers.quickMenu]
        let shortcuts = names.reduce(into: [String: KeyboardShortcuts.Shortcut]()) { shortcuts, name in
            shortcuts[name.rawValue] = KeyboardShortcuts.getShortcut(for: name)
        }
        return EffectsBackup(
            effects: stored,
            graphics: graphics,
            shortcuts: shortcuts,
            quickMenuKeys: triggers.customKeys,
            quickMenuTap: UserDefaults.standard.string(forKey: QuickMenu.tapKey)
        )
    }

    /// Yours become the backup's, keys and all. What you had is kept first,
    /// in the Backups folder, in case.
    func restore(_ backup: EffectsBackup) throws {
        try FileManager.default.createDirectory(at: EffectsBackup.autoBackups, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        try self.backup().write(to: EffectsBackup.autoBackups.appending(path: "Before import \(stamp).vauxeffects"))
        writeGraphics(backup.graphics)
        library.clearAll()
        library.restore(backup.effects)
        for (name, shortcut) in backup.shortcuts {
            KeyboardShortcuts.setShortcut(shortcut, for: .init(name))
        }
        triggers.restoreKeys(backup.quickMenuKeys)
        if let tap = backup.quickMenuTap { UserDefaults.standard.set(tap, forKey: QuickMenu.tapKey) }
    }

    /// Its effects and groups added to yours, as copies: new IDs, names
    /// kept apart. Your default, dictation and Live effects, and your keys,
    /// stay as they are.
    func add(_ backup: EffectsBackup) {
        writeGraphics(backup.graphics)
        var groupIDs: [UUID: UUID] = [:]
        for group in backup.effects.groups ?? [] {
            groupIDs[group.id] = library.addGroup(named: group.name).id
            if let index = library.groups.firstIndex(where: { $0.id == groupIDs[group.id] }) {
                library.groups[index].icon = group.icon
                library.groups[index].color = group.color
            }
        }
        let effectIDs = Dictionary(uniqueKeysWithValues: backup.effects.effects.map { ($0.id, UUID()) })
        for var effect in backup.effects.effects {
            effect.id = effectIDs[effect.id]!
            effect.includes = effect.includes.compactMap { effectIDs[$0] }
            effect.group = effect.group.flatMap { groupIDs[$0] }
            effect.overlays = effect.overlays.map { overlay in
                var overlay = overlay
                overlay.id = UUID()
                return overlay
            }
            library.add(effect)
        }
    }

    /// Into the graphics folder; any already there (by name, which is
    /// unique) left as they are.
    private func writeGraphics(_ graphics: [String: Data]) {
        try? FileManager.default.createDirectory(at: EffectLibrary.graphicsFolder, withIntermediateDirectories: true)
        for (name, data) in graphics {
            let url = EffectLibrary.graphicsFolder.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        }
    }
}
