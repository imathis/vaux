import AppKit
import KeyboardShortcuts
import SwiftUI

/// Every Vaux key in one place: Mute, and while the camera is on, the Quick
/// Menu's leader, then each effect with its Quick Menu key and its shortcut
/// (which a Stream Deck button can press).
struct ShortcutsSettings: View {
    let camera: VauxCamera

    var body: some View {
        Group {
            if let effects = camera.effects {
                EffectShortcuts(effects: effects)
            } else {
                Form {
                    Section {
                        KeyboardShortcuts.Recorder("Mute", name: .toggleMicMute)
                    } header: {
                        SettingsHeader("Microphone")
                    } footer: {
                        Text("Keys for effects and the Quick Menu are here once the camera is on.")
                            .foregroundStyle(.secondary)
                            .wraps()
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: SettingsHeader.pageWidth)
    }
}

struct EffectShortcuts: View {
    let effects: Effects

    private var triggers: Triggers { effects.triggers }

    var body: some View {
        let items = triggers.items
        let keys = triggers.keys
        Form {
            Section {
                ColumnTitles()
                ForEach(items.filter { $0.action == .mute }) { item in
                    TriggerRow(item: item, key: keys[item.id] ?? "", triggers: triggers)
                }
            } header: {
                SettingsHeader("Microphone")
            }
            Section {
                LabeledContent("Open the Quick Menu") {
                    KeyboardShortcuts.Recorder(for: Triggers.quickMenu) { triggers.claim($0, for: Triggers.quickMenu) }
                        .frame(width: 150)
                }
            } header: {
                SettingsHeader("Quick Menu", "One key opens a small menu over everything; a second key picks from it. The call app keeps focus. Every effect key, in the menu or a shortcut: tap it to turn the effect on or off, or hold it to show the effect only while held.")
            }
            Section {
                ColumnTitles()
                let list = items.filter { if case .effect = $0.action { true } else { false } }
                ForEach(list) { item in
                    TriggerRow(item: item, key: keys[item.id] ?? "", triggers: triggers)
                }
                if list.isEmpty {
                    Text("Add effects in the Effects tab.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsHeader("Effects", "Each turns its effect on, and off.")
            }
            Section {
                ForEach(items.filter { $0.action == .live || $0.action == .clearAll }) { item in
                    TriggerRow(item: item, key: keys[item.id] ?? "", triggers: triggers)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Names the two key columns.
private struct ColumnTitles: View {
    var body: some View {
        HStack {
            Spacer()
            Text("Menu key")
                .frame(width: 70)
            Text("Shortcut")
                .frame(width: 150)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// An item, its Quick Menu key, and its shortcut.
private struct TriggerRow: View {
    let item: Triggers.Item
    let key: String
    let triggers: Triggers

    var body: some View {
        HStack {
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            QuickKeyField(key: key, custom: triggers.isCustom(item.id)) { triggers.setKey($0, for: item.id) }
                .frame(width: 70)
            KeyboardShortcuts.Recorder(for: item.shortcut) { triggers.claim($0, for: item.shortcut) }
            .frame(width: 150)
        }
    }
}

/// A Quick Menu key: click, then type a letter or digit. Delete goes back to
/// the key given in order; Escape leaves it as it was.
struct QuickKeyField: View {
    let key: String
    /// Set by hand, rather than given in order.
    let custom: Bool
    let set: (String?) -> Void

    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            listening ? stop() : listen()
        } label: {
            if listening {
                Text("Type…")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 44, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
            } else {
                KeyCap(key: key, muted: !custom)
            }
        }
        .buttonStyle(.plain)
        .help(custom ? "Set by you. Click, then press Delete to go back to the one given in order." : "Given in order. Click, then type any key to choose your own.")
        .onDisappear(perform: stop)
    }

    private func listen() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53:
                stop()
            case 51, 117:
                set(nil)
                stop()
            default:
                guard let typed = event.charactersIgnoringModifiers?.uppercased(), Self.isUsable(typed) else {
                    NSSound.beep()
                    return nil
                }
                set(typed)
                stop()
            }
            return nil
        }
    }

    /// One visible character: letters, digits, punctuation like / . , ; and
    /// shifted ones like ?. Not space, Return or Tab, nor arrow and function
    /// keys (macOS gives those private-use characters).
    static func isUsable(_ typed: String) -> Bool {
        guard typed.count == 1, let character = typed.first, !character.isWhitespace else { return false }
        return character.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
    }
}
