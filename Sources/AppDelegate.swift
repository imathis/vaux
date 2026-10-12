import AppKit
import SwiftUI

/// Owns the menu bar status item, the custom menu panel, and the settings window.
///
/// Plain click on the icon opens the menu; a modifier-click (Shift/Option/Control)
/// toggles mute. The menu is a custom SwiftUI panel (see MenuPanelController),
/// not an NSMenu, so it can match the system Control Center menus' grey hover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusItem: NSStatusItem?
    private var menuController: MenuPanelController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fixed width reserves room for the active-state oval (drawn behind the
        // icon while the menu is open) so it isn't clipped to a tight icon slot.
        // Can't exceed this to overlap neighbors the way the system does — the
        // oval is clipped to this item's own window.
        let item = NSStatusBar.system.statusItem(withLength: 18)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
        menuController = MenuPanelController(appState: appState) { [weak self] in self?.openSettings() }

        appState.onStateChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    // MARK: Icon

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let muted = appState.muted
        let solo = appState.soloActive
        let symbol = solo ? "waveform.and.mic" : muted ? "mic.slash.fill" : "mic.fill"
        let description = solo ? "Solo mode" : muted ? "Microphone muted" : "Microphone live"
        // Solo is a mode you shouldn't forget you're in: tint it (orange if
        // something couldn't be muted).
        let tint: NSColor? = solo
            ? (appState.soloProblems.isEmpty ? .controlAccentColor : .systemOrange)
            : muted ? .systemRed : nil

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            let tinted = image?.withSymbolConfiguration(config)
            tinted?.isTemplate = false
            button.image = tinted
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = appState.deviceName.map { "Hush — Input: \($0)" } ?? "Hush — no input device"
    }

    /// Don't leave call apps muted or speakers ducked behind us.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.soloActive else { return .terminateNow }
        appState.endSolo { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Plain click opens the menu; a modifier-click (Shift/Option/Control)
        // toggles mute. (Right-click on a status item isn't reliably delivered.)
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifierHeld = flags.contains(.shift) || flags.contains(.option) || flags.contains(.control)
        if modifierHeld {
            appState.toggle()
        } else {
            menuController?.toggle(relativeTo: sender)
        }
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            // Size the window to the SwiftUI content (fixed width, intrinsic height).
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Hush Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
