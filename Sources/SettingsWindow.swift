import AppKit
import SwiftUI

/// Settings: a toolbar tab for each part of Vaux (Microphone, Camera,
/// Effects, Shortcuts). The window fits the tab showing, and its content as
/// that changes, its top edge staying put: as tall as the page, down to the
/// bottom of the screen at most (the page scrolls past that), moving up only
/// when that leaves too little room. Its height can be dragged, up to the
/// page's; a dragged height holds until the next tab.
@MainActor
final class SettingsTabController: NSTabViewController {
    enum Tab: Int {
        case microphone, camera, effects, shortcuts
    }

    /// Dragged to a height since the tab was picked.
    private var dragged = false

    /// Less room than this below the window's top, and it moves up.
    private static let shortest: CGFloat = 360
    /// As short as it can be dragged.
    private static let shortestDragged: CGFloat = 200

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
        let index = tabViewItems.count
        // As its content grows or shrinks (a section appearing, an effect
        // added): AppKit isn't told.
        let view = view.onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { [weak self] _, _ in
            if let self, self.selectedTabViewItemIndex == index { self.fitWindow(animate: false) }
        }
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
        dragged = false
        fitWindow(animate: true)
    }

    private var selectedPage: NSViewController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex].viewController : nil
    }

    /// Sizes the window to the page showing (see the class), keeping its top
    /// edge where it is.
    func fitWindow(animate: Bool) {
        guard let window = view.window, let contentView = window.contentView,
              let page = selectedPage as? SettingsPageController else { return }
        // Being dragged: the height's yours.
        if window.inLiveResize {
            dragged = true
            return
        }
        let size = page.fullSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frame
        // Title bar and the tab toolbar.
        let chrome = frame.height - contentView.frame.height
        var height = dragged ? min(contentView.frame.height, size.height) : size.height
        var top = frame.maxY
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            height = min(height, screen.height - chrome)
            let room = top - chrome - screen.minY
            if height > room {
                height = max(room, min(height, Self.shortest))
                top = max(top, screen.minY + chrome + height)
            }
        }
        window.contentMinSize = NSSize(width: size.width, height: min(size.height, Self.shortestDragged))
        window.contentMaxSize = size
        frame.size = NSSize(width: frame.width + size.width - contentView.frame.width, height: chrome + height)
        frame.origin.y = top - frame.height
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

/// A settings page, sized by SettingsTabController (the page scrolls past
/// the window's height).
private final class SettingsPageController: NSHostingController<AnyView> {
    /// All of the page.
    var fullSize: NSSize { super.preferredContentSize }

    /// None to the tab view controller: SettingsTabController alone sizes the
    /// window, so a dragged height isn't put back.
    override var preferredContentSize: NSSize {
        get { .zero }
        set { super.preferredContentSize = newValue }
    }
}
