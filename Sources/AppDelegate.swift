import AppKit
import SwiftUI

/// Owns the menu bar status item and the settings window.
///
/// Plain click on the icon opens the menu; Shift-click toggles mute. The
/// settings window is a self-managed NSWindow (a SwiftUI `Settings` scene
/// can't take key focus in an LSUIElement app, which breaks the shortcut
/// recorder), hosting the SwiftUI `SettingsView` via NSHostingController.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        appState.onStateChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    // MARK: Icon

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let muted = appState.muted
        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        let description = muted ? "Microphone muted" : "Microphone live"

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if muted {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let red = image?.withSymbolConfiguration(config)
            red?.isTemplate = false
            button.image = red
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = appState.deviceName.map { "Hush — Input: \($0)" } ?? "Hush — no input device"
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Plain click toggles mute (the frequent action). A modifier-click opens
        // the menu: Shift, Option, or Control. These are left-clicks with a
        // modifier, so the action fires on the reliable leftMouseUp path. True
        // right-click is also wired up, but AppKit doesn't deliver right-mouse
        // events to status items reliably (confirmed broken on macOS 27), so the
        // modifier-clicks are the dependable route.
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isRightMouse = NSApp.currentEvent?.type == .rightMouseUp
        let wantsMenu = isRightMouse
            || flags.contains(.shift)
            || flags.contains(.option)
            || flags.contains(.control)
        if wantsMenu {
            showMenu()
        } else {
            appState.toggle()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = makeMenu()
        button.highlight(true)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 5),
                   in: button)
        button.highlight(false)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: appState.deviceName.map { "Input: \($0)" } ?? "No input device",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if appState.deviceName != nil && !appState.supportsMute {
            let note = NSMenuItem(title: "Mute unsupported — using volume", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: appState.muted ? "Unmute" : "Mute",
            action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = appState.hasDevice
        menu.addItem(toggle)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Hush", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: Menu actions

    @objc private func toggleFromMenu() {
        appState.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            // Don't let the hosting controller drive (and collapse) the window
            // size; we set an explicit content size and let SwiftUI fill it.
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "Hush Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 400, height: 260))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
