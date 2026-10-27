import AppKit
import SwiftUI

/// Development: launched with `-snapshot <path>`, Vaux draws each Settings tab
/// and the menu, whole, to PNGs named after `<path>` (".microphone", ".menu"…),
/// opens Settings and draws that window on each tab (".window-camera"…), then
/// quits. Layout can be checked
/// without screen recording (Vaux draws itself). `make snapshot` does this.
@MainActor
enum Snapshot {
    static func runIfAsked(appState: AppState, openSettings: @escaping () -> Void) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-snapshot"), arguments.indices.contains(flag + 1) else { return }
        let base = URL(fileURLWithPath: arguments[flag + 1]).deletingPathExtension()
        Task {
            let pages: [(String, AnyView)] = [
                ("microphone", AnyView(MicrophoneSettings())),
                ("camera", AnyView(CameraSettings())),
                ("effects", AnyView(EffectsSettings())),
                ("shortcuts", AnyView(ShortcutsSettings())),
                ("menu", AnyView(MenuContentView(appState: appState, openAbout: {}, openSettings: {}, dismiss: {}, resized: { _ in }))),
            ]
            for (name, page) in pages {
                await render(page, to: base.appendingPathExtension("\(name).png"))
            }
            openSettings()
            // Let the window lay out and size itself to its first tab.
            try? await Task.sleep(for: .seconds(1))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let tabs = window.contentViewController as? NSTabViewController,
               let frame = window.contentView?.superview {
                // Each tab as the window shows it, sized to that tab.
                for (index, item) in tabs.tabViewItems.enumerated() {
                    tabs.selectedTabViewItemIndex = index
                    try? await Task.sleep(for: .seconds(0.6))
                    write(frame, to: base.appendingPathExtension("window-\(item.label.lowercased()).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// In a tall offscreen window, so nothing scrolls out of view. On the
    /// window's color: the menu's material and a bare page draw nothing.
    /// Measured again once `onAppear` has loaded the view's state.
    private static func render(_ view: AnyView, to url: URL) async {
        let host = NSHostingView(rootView: view
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: max(size.width, 100), height: max(size.height, 100)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSApp.effectiveAppearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(0.3))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        write(host, to: url)
        window.orderOut(nil)
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: url)
    }
}
