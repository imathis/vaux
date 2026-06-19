import AppKit
import SwiftUI

/// Borderless panel must opt in to becoming key so the slider/keyboard work.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the custom menu in a borderless panel under the status item and
/// dismisses it on outside-click, Escape, or selecting Settings/Quit.
@MainActor
final class MenuPanelController {
    private let appState: AppState
    private let openSettings: () -> Void
    private var panel: NSPanel?
    private var hostingController: NSHostingController<MenuContentView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastOutsideCloseAt: Date?

    init(appState: AppState, openSettings: @escaping () -> Void) {
        self.appState = appState
        self.openSettings = openSettings
    }

    var isOpen: Bool { panel != nil }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isOpen {
            close()
        } else if let last = lastOutsideCloseAt, Date().timeIntervalSince(last) < 0.3 {
            // This click is the one that just dismissed the menu — don't reopen.
            lastOutsideCloseAt = nil
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        let content = MenuContentView(
            appState: appState,
            openSettings: openSettings,
            dismiss: { [weak self] in self?.close() })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller

        let panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 308, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true

        // Window-level Liquid Glass (macOS 26) — gives the translucent material
        // and rounded shape without a stray rectangular window backing/shadow.
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        glass.contentView = controller.view
        glass.autoresizingMask = [.width, .height]
        panel.contentView = glass

        // Now that the view is in a window it can report its size.
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        panel.setContentSize(size)

        position(panel, under: button, size: size)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastOutsideCloseAt = Date()
                self?.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    func close() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    private func position(_ panel: NSPanel, under button: NSStatusBarButton, size: NSSize) {
        guard let window = button.window else { return }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let y = onScreen.minY - 4 // just below the menu bar
        // Open to the right (left edge at the icon); shift left only as much as
        // needed to stay on screen, rather than flipping fully left of the icon.
        var x = onScreen.minX
        if let frame = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(x, frame.maxX - size.width - 4)
            x = max(x, frame.minX + 4)
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
    }
}
