import AppKit
import SwiftUI

/// Live: effects on the spot. Type something and Return shows it over your
/// video, in the look and spot you pick; a slider pushes in. Opened from the
/// Quick Menu (L), the menu, or its shortcut, it floats beside the call
/// until closed, and takes keys without activating Vaux, so the call app
/// stays in front.
@MainActor
final class LivePanel: NSObject, NSWindowDelegate {
    private let overlays: OverlayLibrary
    private let zoom: ZoomShortcuts
    private var panel: NSPanel?

    init(overlays: OverlayLibrary, zoom: ZoomShortcuts) {
        self.overlays = overlays
        self.zoom = zoom
        super.init()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = LiveWindow()
        let host = NSHostingView(rootView: LiveView(library: overlays, zoom: zoom))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.delegate = self
        // Where the Quick Menu opens: the upper third of the screen you're on.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: area.midX - panel.frame.width / 2,
                y: area.minY + area.height * 0.72 - panel.frame.height / 2
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// A floating utility panel that takes keys without activating Vaux;
/// Escape closes it.
private final class LiveWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: true)
        title = "Live"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// What to say, its look and spot, and the zoom. Typing doesn't change
/// what's showing until Return: each change would fade in anew.
struct LiveView: View {
    @Bindable var library: OverlayLibrary
    let zoom: ZoomShortcuts

    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Say something…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit(primary)
                Button(primaryTitle, action: primary)
                    .disabled(!showing && !canShow)
                    .frame(minWidth: 64)
            }
            HStack(spacing: 2) {
                ForEach(Overlay.icons, id: \.label) { icon in
                    let selected = library.live.icon == icon.symbol
                    Button { library.live.icon = icon.symbol } label: {
                        Image(systemName: icon.symbol ?? "circle.slash")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(icon.label)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Style", selection: $library.live.style) {
                        Text("Pill").tag(Overlay.Style.pill)
                        Text("Bar").tag(Overlay.Style.bar)
                        Text("Plain").tag(Overlay.Style.plain)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("Size", selection: $library.live.size) {
                        ForEach(Overlay.Size.textSizes, id: \.self) { size in
                            Text(size.rawValue.capitalized).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SpotGrid(spot: $library.live.spot)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .help("Push in")
                Slider(value: Binding(get: { zoom.factor }, set: { zoom.setLiveZoom(($0 * 20).rounded() / 20) }), in: 1...ZoomShortcuts.range.upperBound)
                    .controlSize(.small)
                Text(zoom.factor.zoomText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button { zoom.setLiveZoom(1) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(zoom.factor <= 1)
                .help("Back to 1×")
            }
            Text("Return shows it, or updates it while it's up · Esc closes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            draft = library.live.lines.first ?? ""
            typing = true
        }
    }

    private var showing: Bool { library.isShowing(library.live.id) }

    private var canShow: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty || library.live.icon != nil }

    private var edited: Bool { draft != (library.live.lines.first ?? "") }

    private var primaryTitle: String { !showing ? "Show" : edited ? "Update" : "Hide" }

    /// Shows what's typed, updates it while it's up, or hides it.
    private func primary() {
        if showing, !edited {
            library.hide(library.live.id)
            return
        }
        library.live.lines = [draft]
        if !showing, canShow { library.show(library.live.id) }
    }
}

/// The spots, laid out as in the frame: a compact pick for the Live panel.
private struct SpotGrid: View {
    @Binding var spot: Overlay.Spot

    private let rows: [[Overlay.Spot?]] = [
        [.topLeading, .top, .topTrailing],
        [nil, .center, nil],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        if let place = rows[row][column] {
                            Button { spot = place } label: {
                                Circle()
                                    .fill(place == spot ? Color.accentColor : Color.secondary.opacity(0.4))
                                    .frame(width: 11, height: 11)
                                    .frame(width: 18, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(place.label)
                        } else {
                            Color.clear.frame(width: 18, height: 14)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}
