import AppKit
import SwiftUI

/// Settings: a toolbar tab for each part of Vaux (Microphone, Camera,
/// Effects, Shortcuts), the window sized to the tab showing and to its
/// content as that changes, its top edge staying put.
@MainActor
final class SettingsTabController: NSTabViewController {
    enum Tab: Int {
        case microphone, camera, effects, shortcuts
    }

    init(camera: VauxCamera) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // The window resizes instead of the tabs sliding.
        transitionOptions = []
        addTabViewItem(page(MicrophoneSettings(), "Microphone", symbol: "mic"))
        addTabViewItem(page(CameraSettings(camera: camera), "Camera", symbol: "video"))
        addTabViewItem(page(EffectsSettings(camera: camera) { [weak self] in self?.select(.camera) }, "Effects", symbol: "wand.and.stars"))
        addTabViewItem(page(ShortcutsSettings(camera: camera), "Shortcuts", symbol: "keyboard"))
    }

    func select(_ tab: Tab) {
        selectedTabViewItemIndex = tab.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func page(_ view: some View, _ title: String, symbol: String) -> NSTabViewItem {
        let controller = SettingsPageController(rootView: AnyView(view))
        // The page's SwiftUI size becomes its preferred size.
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animate: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === selectedPage { fitWindow(animate: false) }
    }

    private var selectedPage: NSViewController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex].viewController : nil
    }

    /// Sizes the window to the page showing, keeping its top edge where it is.
    func fitWindow(animate: Bool) {
        guard let window = view.window, let contentView = window.contentView, let page = selectedPage else { return }
        let size = page.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let current = contentView.frame.size
        var frame = window.frame
        frame.size.width += size.width - current.width
        frame.size.height += size.height - current.height
        frame.origin.y -= size.height - current.height
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

/// A settings page, no taller than the screen allows (the page scrolls past
/// that).
private final class SettingsPageController: NSHostingController<AnyView> {
    override var preferredContentSize: NSSize {
        get {
            var size = super.preferredContentSize
            if let screen = view.window?.screen ?? NSScreen.main {
                // Title bar and the tab toolbar.
                size.height = min(size.height, screen.visibleFrame.height - 90)
            }
            return size
        }
        set { super.preferredContentSize = newValue }
    }
}
