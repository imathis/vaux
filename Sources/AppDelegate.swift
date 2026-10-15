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
    private var iconAnimator: StatusIconAnimator?
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
            iconAnimator = StatusIconAnimator(button: button)
        }
        statusItem = item
        menuController = MenuPanelController(
            appState: appState,
            openAbout: { [weak self] in self?.openAbout() },
            openSettings: { [weak self] in self?.openSettings() })

        appState.onStateChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    // MARK: Icon

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let muted = appState.muted
        let solo = appState.soloActive
        // A muted mic wins over solo: nobody hears you, dictation included.
        let description = muted ? "Microphone muted" : solo ? "Solo mode" : "Microphone live"
        // Neutral, so the shape carries the state: muted is dots, solo is three
        // bars between two dimmed dots (orange if something couldn't be muted).
        let state: StatusIcon.State = muted ? .muted : solo ? .solo(problem: !appState.soloProblems.isEmpty) : .live
        iconAnimator?.show(state, description: description)
        button.toolTip = appState.deviceName.map { "Vaux — Input: \($0)" } ?? "Vaux — no input device"
    }

    /// Don't leave call apps muted or speakers ducked behind us.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.soloActive || appState.soloBusy else { return .terminateNow }
        appState.endSoloForQuit {
            // Never before .terminateLater has been returned.
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Browsers' full accessibility trees are switched on only while needed.
    func applicationWillTerminate(_ notification: Notification) {
        CallMuter.releaseWebTrees()
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

    // MARK: About and Settings

    /// The standard About panel, with the release's name as its version
    /// (1.0.0-alpha.1, not the bare 1.0.0) and a line and link of credits.
    private func openAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = info["VauxRelease"] as? String ?? info["CFBundleShortVersionString"] as? String ?? ""
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Microphone control for the dictation age\n", attributes: small)
        var link = small
        link[.link] = URL(string: "https://github.com/imathis/vaux")
        credits.append(NSAttributedString(string: "github.com/imathis/vaux", attributes: link))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: release, .credits: credits])
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsHostingController(rootView: SettingsView())
            // Size the window to the SwiftUI content (fixed width, intrinsic height).
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Vaux Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Sizes the Settings window to its content, but never taller than the screen:
/// past that, the grouped form scrolls inside it.
private final class SettingsHostingController: NSHostingController<SettingsView> {
    override var preferredContentSize: NSSize {
        get {
            var size = super.preferredContentSize
            if let screen = view.window?.screen ?? NSScreen.main {
                let style = view.window?.styleMask ?? [.titled, .closable]
                let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
                size.height = min(size.height, screen.visibleFrame.height - titleBar)
            }
            return size
        }
        set { super.preferredContentSize = newValue }
    }
}
