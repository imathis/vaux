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
    private var highlightView: NSView?
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
        // and rounded shape. Wrapped in a layer-masked container so the window's
        // corner triangles are clipped to the rounded shape; without it the
        // backing shows through as dark corners behind the rounded glass.
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        glass.contentView = controller.view
        glass.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        glass.frame = container.bounds
        container.addSubview(glass)
        panel.contentView = container

        // Now that the view is in a window it can report its size.
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        panel.setContentSize(size)
        glass.frame = container.bounds

        position(panel, under: button, size: size)
        panel.makeKeyAndOrderFront(nil)
        // Recompute the shadow from the rounded glass shape; the default cached
        // shadow is rectangular and bleeds dark corners behind the rounded panel.
        panel.invalidateShadow()
        self.panel = panel

        showHighlight(behind: button)

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
        highlightView?.removeFromSuperview()
        highlightView = nil
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    /// Draws the menu-bar "active" capsule behind the icon while the menu is
    /// open. `highlight(true)` on the button renders nothing on macOS 26 (the
    /// system draws the real oval only while presenting its own NSMenu/
    /// NSPopover), so we render a Liquid Glass capsule ourselves.
    private func showHighlight(behind button: NSStatusBarButton) {
        guard let windowContent = button.window?.contentView,
              let superview = button.superview else { return }
        // Fill the whole item window, not just the narrow button slot. The window
        // is wider than the slot (system margins that overlap neighbors), so this
        // gives a wide capsule that spills past the icon the way the system's
        // indicator does — while the slot stays narrow for tight icon spacing.
        let height: CGFloat = 23
        let radius = height / 2
        let centerY = windowContent.convert(NSPoint(x: 0, y: button.frame.midY), from: superview).y
        let rect = NSRect(x: 0, y: centerY - radius, width: windowContent.bounds.width, height: height)

        // Clip to the capsule so the glass view's rectangular edge/shadow (the
        // dark border) is masked away.
        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.cornerRadius = radius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = []

        // Real Liquid Glass — the translucent frosted material the system uses.
        let glass = NSGlassEffectView(frame: container.bounds)
        glass.cornerRadius = radius
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        windowContent.addSubview(container, positioned: .below, relativeTo: nil)
        highlightView = container
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
