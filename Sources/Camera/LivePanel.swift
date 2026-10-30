import AppKit
import SwiftUI

/// Live: an effect set up on the spot. Text over your video, in the style
/// and spot you pick, a push-in, and another effect to go with them; Show
/// puts it all up at once, Hide takes it down. Opened from the Quick Menu (L), the menu, or its
/// shortcut, it floats beside the call until closed, and takes keys
/// without activating Vaux, so the call app stays in front.
@MainActor
final class LivePanel: NSObject, NSWindowDelegate {
    private let library: EffectLibrary
    private var panel: NSPanel?

    init(library: EffectLibrary) {
        self.library = library
        super.init()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = LiveWindow()
        let host = NSHostingView(rootView: LiveView(library: library))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.delegate = self
        // Where the Quick Menu opens.
        panel.placeHigh()
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

/// What to say, its style and spot, the push-in and an effect to go with
/// them, shown and hidden together. While it's up, all but the text follow
/// changes at once; typed text waits for Return, since each change would
/// fade in anew.
struct LiveView: View {
    @Bindable var library: EffectLibrary

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
            IconChoices(icon: icon)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Style", selection: overlay.style) {
                        Text("Pill").tag(Overlay.Style.pill)
                        Text("Bar").tag(Overlay.Style.bar)
                        Text("Plain").tag(Overlay.Style.plain)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("Size", selection: overlay.size) {
                        ForEach(Overlay.Size.textSizes, id: \.self) { size in
                            Text(size.rawValue.capitalized).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SpotGrid(spot: overlay.spot)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .help("Push in")
                Slider(value: pushIn, in: 1...Effect.pushInRange.upperBound)
                    .controlSize(.small)
                Text(pushIn.wrappedValue.zoomText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button { library.live.pushIn = nil } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(library.live.pushIn == nil)
                .help("Back to 1×")
            }
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .help("With an effect")
                Picker("Effect", selection: Binding(get: { library.live.includes.first }, set: { library.live.includes = $0.map { [$0] } ?? [] })) {
                    Text("No effect").tag(UUID?.none)
                    ForEach(library.effects) { effect in
                        Text(effect.name).tag(UUID?.some(effect.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            Text("Show (or Return) puts it all up together · Esc closes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            draft = overlay.wrappedValue.lines.first?.text ?? ""
            typing = true
        }
    }

    private var showing: Bool { library.liveOn }

    /// Its text overlay (the library keeps it one).
    private var overlay: Binding<Overlay> {
        Binding {
            library.live.overlays.first ?? .live
        } set: { overlay in
            if library.live.overlays.isEmpty { library.live.overlays = [overlay] } else { library.live.overlays[0] = overlay }
        }
    }

    /// The icon goes up (or changes) at once, unlike typed text.
    private var icon: Binding<String?> {
        Binding {
            overlay.wrappedValue.lines.first?.icon
        } set: { icon in
            if overlay.wrappedValue.lines.isEmpty {
                overlay.wrappedValue.lines = [Overlay.Line(text: "", icon: icon)]
            } else {
                overlay.wrappedValue.lines[0].icon = icon
            }
        }
    }

    /// 1× is none.
    private var pushIn: Binding<Double> {
        Binding {
            library.live.pushIn ?? 1
        } set: { zoom in
            let rounded = (zoom * 20).rounded() / 20
            library.live.pushIn = rounded > 1.001 ? rounded : nil
        }
    }

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty || overlay.wrappedValue.lines.first?.icon != nil }

    private var canShow: Bool { hasText || library.live.pushIn != nil || !library.live.includes.isEmpty }

    private var edited: Bool { draft != (overlay.wrappedValue.lines.first?.text ?? "") }

    private var primaryTitle: String { !showing ? "Show" : edited ? "Update" : "Hide" }

    /// Shows all of it, updates the text while it's up, or hides all of it.
    private func primary() {
        if showing, !edited {
            library.setLive(false)
            return
        }
        overlay.wrappedValue.lines = [Overlay.Line(text: draft, icon: overlay.wrappedValue.lines.first?.icon)]
        if !showing { library.setLive(true) }
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
