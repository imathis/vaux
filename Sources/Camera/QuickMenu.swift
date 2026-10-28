import AppKit
import KeyboardShortcuts
import SwiftUI

/// The Quick Menu: the leader key (or a right-side modifier tapped alone)
/// opens a small panel over everything; one more key fires an item. Tapped, the effect stays on; held, it lasts until
/// the key comes up (the panel hides but keeps listening for that). Escape,
/// the leader key again, or a click elsewhere closes it too. It takes keys
/// without activating Vaux, so the call app keeps focus. It's there while
/// the camera is on.
@MainActor
final class QuickMenu: NSObject, NSWindowDelegate {
    private let triggers: Triggers
    private var panel: QuickMenuPanel?
    /// The item key that's down, waiting for it to come up.
    private var holding: (keyCode: UInt16, action: Triggers.Item.Action)?
    private var tapMonitor: ModifierTapMonitor?

    /// Where the modifier that opens it, tapped alone, is kept.
    static let tapKey = "quickMenuTap"

    init(triggers: Triggers) {
        self.triggers = triggers
        super.init()
        KeyboardShortcuts.onKeyDown(for: Triggers.quickMenu) { [weak self] in self?.toggle() }
        tapMonitor = ModifierTapMonitor(defaultsKey: Self.tapKey) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel != nil { close() } else { open() }
    }

    private func open() {
        let panel = QuickMenuPanel()
        let host = NSHostingView(rootView: QuickMenuView(triggers: triggers) { [weak self] item in self?.fire(item) })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onKeyUp = { [weak self] event in self?.handleUp(event) ?? false }
        // Centered on the screen you're on, in its upper third.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: area.midX - panel.frame.width / 2,
                y: area.minY + area.height * 0.72 - panel.frame.height / 2
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func close() {
        // A key held as the panel goes (a click elsewhere) counts as let go.
        if let holding {
            self.holding = nil
            triggers.release(holding.action)
        }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// A click: a tap.
    private func fire(_ item: Triggers.Item) {
        close()
        triggers.trigger(item.action)
    }

    /// An item's key presses it; Escape closes. Anything else is ignored.
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            close()
            return true
        }
        guard holding == nil else { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let typed = event.charactersIgnoringModifiers?.uppercased(), !typed.isEmpty
        else { return false }
        let keys = triggers.keys
        guard let item = triggers.items.first(where: { keys[$0.id] == typed }) else {
            NSSound.beep()
            return true
        }
        // Out of sight at once, but still key, to hear the key come up.
        panel?.alphaValue = 0
        holding = (event.keyCode, item.action)
        triggers.press(item.action)
        return true
    }

    /// The held item key came up: released, then the panel goes.
    private func handleUp(_ event: NSEvent) -> Bool {
        guard let holding, event.keyCode == holding.keyCode else { return false }
        self.holding = nil
        triggers.release(holding.action)
        close()
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A borderless panel that takes keys without activating Vaux.
private final class QuickMenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) != true { super.keyUp(with: event) }
    }
}

/// The items and their keys.
struct QuickMenuView: View {
    let triggers: Triggers
    let fire: (Triggers.Item) -> Void

    var body: some View {
        let keys = triggers.keys
        VStack(alignment: .leading, spacing: 2) {
            Text(VauxCamera.appName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(triggers.items) { item in
                Button { fire(item) } label: {
                    HStack(spacing: 10) {
                        KeyCap(key: keys[item.id] ?? "")
                        Text(item.title)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if item.isOn {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .help("On")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuickMenuRowStyle())
            }
            Text("Tap a key to turn it on or off · hold it to show it only while held")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .wraps()
        }
        .padding(8)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
    }
}

/// Highlights under the pointer, like a menu.
private struct QuickMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(configuration.isPressed ? 0.35 : hovering ? 0.2 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// A key, drawn like a keycap.
struct KeyCap: View {
    let key: String
    var muted = false

    var body: some View {
        Text(key)
            .font(.system(.callout, design: .rounded).weight(.semibold).monospaced())
            .foregroundStyle(muted ? .secondary : .primary)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
    }
}
