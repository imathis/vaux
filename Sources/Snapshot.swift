import AppKit
import SwiftUI

/// Development: launched with `-snapshot <path>`, Vaux draws each Settings tab
/// and the menu, whole, to PNGs named after `<path>` (".microphone", ".menu"…),
/// opens Settings and draws that window on each tab (".window-camera"…), then
/// quits. Layout can be checked
/// without screen recording (Vaux draws itself). `make snapshot` does this.
@MainActor
enum Snapshot {
    /// Snapshots don't run the camera: a Vaux Dev already running would be
    /// feeding it.
    static let isRunning = ProcessInfo.processInfo.arguments.contains("-snapshot")

    static func runIfAsked(appState: AppState, camera: VauxCamera, openSettings: @escaping () -> Void) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-snapshot"), arguments.indices.contains(flag + 1) else { return }
        let base = URL(fileURLWithPath: arguments[flag + 1]).deletingPathExtension()
        Task {
            var pages: [(String, AnyView)] = [
                ("microphone", AnyView(MicrophoneSettings())),
                ("camera", AnyView(CameraSettings(camera: camera))),
                ("effects", AnyView(EffectsSettings(camera: camera) {})),
                ("shortcuts", AnyView(ShortcutsSettings(camera: camera))),
                ("menu", AnyView(MenuContentView(appState: appState, camera: camera, openAbout: {}, openSettings: {}, dismiss: {}, resized: { _ in }))),
            ]
            // Effects' pages, with the camera off too: effects touch no camera.
            let effects = camera.effects ?? Effects(appState: appState)
            pages.append(("effects-on", AnyView(EffectsPage(effects: effects))))
            pages.append(("shortcuts-on", AnyView(EffectShortcuts(effects: effects).frame(width: SettingsHeader.pageWidth))))
            if let overlay = effects.overlays.overlays.first {
                pages.append(("editor", AnyView(OverlayEditor(library: effects.overlays, id: overlay.id))))
                let sample = Combo(name: "Big entrance", overlays: [overlay.id], pushIn: effects.zoomShortcuts.levels.first?.id)
                pages.append(("combo-form", AnyView(
                    ComboForm(combo: .constant(sample), overlays: effects.overlays.overlays, levels: effects.zoomShortcuts.levels)
                        .frame(width: 480)
                )))
            }
            pages.append(("quickmenu", AnyView(QuickMenuView(triggers: effects.triggers) { _ in }.padding(20))))
            let preview = camera.effects == nil ? VauxCamera(previewing: effects, appState: appState) : camera
            pages.append(("menu-camera", AnyView(MenuContentView(appState: appState, camera: preview, openAbout: {}, openSettings: {}, dismiss: {}, resized: { _ in }))))
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
