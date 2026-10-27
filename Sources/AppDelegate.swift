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
        // Shown only while Settings makes Vaux a regular app.
        NSApp.mainMenu = mainMenu()
        Snapshot.runIfAsked(appState: appState) { [weak self] in self?.openSettings() }
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

    @objc private func showAbout() {
        openAbout()
    }

    /// While Settings is open, Vaux is an app like any other, in the Dock and
    /// ⌘-Tab so its window can be found and focused; closing it puts Vaux back
    /// in the menu bar only.
    @objc private func openSettings() {
        if settingsWindow == nil {
            let tabs = SettingsTabController()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            tabs.fitWindow(animate: false)
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        // Forced: the menu panel doesn't activate Vaux, so another app is in front.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The Dock icon, while Settings makes Vaux show one: bring Settings back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openSettings() }
        return true
    }

    /// The menu bar while Vaux is a regular app (Settings open): About,
    /// Settings, hiding and quitting; Edit, so text fields cut, copy and paste;
    /// Window.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Vaux", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Vaux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Vaux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Vaux", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        return main
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
