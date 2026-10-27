import SwiftUI
import UniformTypeIdentifiers

/// Everything you trigger: overlays (show or hide, add, edit), push-in levels,
/// combos, and the overlay shown while dictating.
struct EffectsPage: View {
    let effects: Effects

    @State private var editing: Editing?
    @State private var editingCombo: Editing?
    @State private var editingLook: Editing?
    /// The Settings window's: deleting an effect can be undone.
    @Environment(\.undoManager) private var undoManager

    private struct Editing: Identifiable {
        let id: UUID
    }

    private var library: OverlayLibrary { effects.overlays }

    var body: some View {
        @Bindable var library = library
        Form {
            Section {
                ForEach(library.overlays) { overlay in
                    OverlayRow(
                        overlay: overlay,
                        showing: library.isShowing(overlay.id),
                        toggle: { library.toggle(overlay.id) },
                        edit: { editing = Editing(id: overlay.id) }
                    )
                    .contextMenu {
                        Button("Edit…") { editing = Editing(id: overlay.id) }
                        Button("Duplicate") { library.duplicate(overlay.id) }
                        Divider()
                        Button("Delete", role: .destructive) { remove(.overlay(overlay.id)) }
                    }
                }
                .onMove { library.overlays.move(fromOffsets: $0, toOffset: $1) }
                // Under its list, at the trailing edge, as in System
                // Settings; a menu where there's a choice to make.
                HStack {
                    Spacer()
                    Menu("Add Overlay") {
                        Button("Text") { editing = Editing(id: library.add(.text).id) }
                        Button("Graphic") { editing = Editing(id: library.add(.graphic).id) }
                    }
                    .fixedSize()
                }
            } header: {
                SettingsHeader("Overlays", "Over your video, one per spot: a new one replaces what's there.")
            }
            Section {
                PushInLevels(shortcuts: effects.zoomShortcuts) { remove(.pushIn($0.id)) }
            } header: {
                SettingsHeader("Push In", "Zoom further, and back. On top of each camera's zoom, up to 2×.")
            }
            Section {
                ForEach(effects.looks.looks) { look in
                    LookRow(
                        look: look,
                        isOn: effects.looks.active == look.id,
                        toggle: { effects.triggers.trigger(.look(look.id)) },
                        edit: { editingLook = Editing(id: look.id) }
                    )
                    .contextMenu {
                        Button("Edit…") { editingLook = Editing(id: look.id) }
                        Button("Duplicate") { effects.looks.duplicate(look.id) }
                        Divider()
                        Button("Delete", role: .destructive) { remove(.look(look.id)) }
                    }
                }
                .onMove { effects.looks.looks.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Spacer()
                    // The presets again: one deleted, or a fresh copy beside
                    // one that's been changed.
                    Menu("Add Look") {
                        Button("New Look") { editingLook = Editing(id: effects.looks.add().id) }
                        Section("Presets") {
                            ForEach(Look.presets) { preset in
                                Button(preset.name) { editingLook = Editing(id: effects.looks.add(preset).id) }
                            }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                SettingsHeader("Looks", "Color over the whole picture, one at a time.")
            }
            Section {
                let items = effects.triggers.items
                ForEach(effects.combos.combos) { combo in
                    ComboRow(
                        combo: combo,
                        summary: summary(of: combo),
                        isOn: items.first { $0.action == .combo(combo.id) }?.isOn ?? false,
                        toggle: { effects.triggers.trigger(.combo(combo.id)) },
                        edit: { editingCombo = Editing(id: combo.id) }
                    )
                    .contextMenu {
                        Button("Edit…") { editingCombo = Editing(id: combo.id) }
                        Button("Duplicate") { effects.combos.duplicate(combo.id) }
                        Divider()
                        Button("Delete", role: .destructive) { remove(.combo(combo.id)) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Combo") { editingCombo = Editing(id: effects.combos.add().id) }
                }
            } header: {
                SettingsHeader("Combos", "Several overlays, a push-in and a look, on one key.")
            }
            Section {
                Picker("While dictating, show", selection: $library.dictationOverlay) {
                    Text("Nothing").tag(UUID?.none)
                    ForEach(library.overlays) { overlay in
                        Text(overlay.name).tag(UUID?.some(overlay.id))
                    }
                }
            } header: {
                SettingsHeader("Dictating", "Shows while solo mode is on, so the call knows why you're muted.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsHeader.pageWidth)
        .sheet(item: $editing) { editing in
            OverlayEditor(library: library, id: editing.id) { remove(.overlay(editing.id)) }
        }
        .sheet(item: $editingCombo) { editing in
            ComboEditor(effects: effects, id: editing.id) { remove(.combo(editing.id)) }
        }
        .sheet(item: $editingLook) { editing in
            LookEditor(effects: effects, id: editing.id) { remove(.look(editing.id)) }
        }
    }

    private func remove(_ action: Triggers.Item.Action) {
        effects.remove(action, undo: undoManager)
    }

    /// Its overlays' names, its push-in, and its look.
    private func summary(of combo: Combo) -> String {
        var parts = combo.overlays.compactMap { library.overlay($0)?.name }
        if let level = effects.zoomShortcuts.levels.first(where: { $0.id == combo.pushIn }) {
            parts.append("Push in \(level.zoom.zoomText)")
        }
        if let look = combo.look.flatMap(effects.looks.look) { parts.append(look.name) }
        return parts.isEmpty ? "Nothing in it yet" : parts.joined(separator: " + ")
    }
}

/// A combo in the list, one line: its name (what's in it on hover), and
/// show or hide.
private struct ComboRow: View {
    let combo: Combo
    let summary: String
    let isOn: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(combo.name)
                .lineLimit(1)
                .help(summary)
            Spacer(minLength: 8)
            Button(action: toggle) {
                Image(systemName: isOn ? "eye.fill" : "eye")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOn ? "Turn off" : "Turn on")
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }
}

/// Picks what a combo stacks: overlays, and a push-in.
struct ComboEditor: View {
    let effects: Effects
    let id: UUID
    /// Undoably, by the page that opened it.
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var combos = effects.combos
        VStack(spacing: 0) {
            if let index = combos.combos.firstIndex(where: { $0.id == id }) {
                ComboForm(combo: $combos.combos[index], overlays: effects.overlays.overlays, levels: effects.zoomShortcuts.levels, looks: effects.looks.looks)
            }
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    dismiss()
                    delete()
                }
                Spacer()
                let isOn = effects.triggers.items.first { $0.action == .combo(id) }?.isOn ?? false
                Button(isOn ? "Turn Off" : "Turn On") { effects.triggers.trigger(.combo(id)) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 540)
    }
}

struct ComboForm: View {
    @Binding var combo: Combo
    let overlays: [Overlay]
    let levels: [ZoomShortcuts.Level]
    let looks: [Look]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $combo.name)
            }
            Section {
                ForEach(overlays) { overlay in
                    Toggle(isOn: member(overlay.id)) {
                        Text(overlay.name)
                        Text(overlay.spot.label)
                    }
                }
                if let clash {
                    Label(clash, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .wraps()
                }
            } header: {
                SettingsHeader("Overlays", "Each shows in its own spot, together.")
            }
            Section {
                Picker("Push in", selection: $combo.pushIn) {
                    Text("None").tag(UUID?.none)
                    ForEach(levels) { level in
                        Text("Push in \(level.zoom.zoomText)").tag(UUID?.some(level.id))
                    }
                }
                Picker("Look", selection: $combo.look) {
                    Text("None").tag(UUID?.none)
                    ForEach(looks) { look in
                        Text(look.name).tag(UUID?.some(look.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Checked overlays stay in the order they were checked.
    private func member(_ id: UUID) -> Binding<Bool> {
        Binding {
            combo.overlays.contains(id)
        } set: { included in
            if included {
                if !combo.overlays.contains(id) { combo.overlays.append(id) }
            } else {
                combo.overlays.removeAll { $0 == id }
            }
        }
    }

    /// Checked overlays that share a spot: only the last checked shows there.
    private var clash: String? {
        let chosen = combo.overlays.compactMap { id in overlays.first { $0.id == id } }
        let shared = Dictionary(grouping: chosen, by: \.spot).filter { $0.value.count > 1 }
        guard let (spot, sharing) = shared.first else { return nil }
        let names = sharing.map(\.name).formatted(.list(type: .and))
        return "\(names) share the \(spot.label.lowercased()) spot, so only \(sharing.last!.name) shows there."
    }
}

/// Push-in levels, each with its Quick Menu key; their shortcuts are in the
/// Shortcuts tab. The dot shows the one pushed in to, and pushes in by click
/// too, to try one without a key.
private struct PushInLevels: View {
    let shortcuts: ZoomShortcuts
    let remove: (ZoomShortcuts.Level) -> Void

    var body: some View {
        ForEach(shortcuts.levels) { level in
            let on = shortcuts.active == level.id
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                // Pushed in, the camera follows the slider as it moves.
                // Rounded to 0.05× here rather than stepped, which draws a
                // tick mark for every step.
                Slider(
                    value: Binding(get: { level.zoom }, set: { shortcuts.setZoom(($0 * 20).rounded() / 20, for: level) }),
                    in: ZoomShortcuts.range
                )
                .labelsHidden()
                .controlSize(.small)
                Text(level.zoom.zoomText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                // On now, as for the other effects.
                Button { shortcuts.toggle(level.id) } label: {
                    Image(systemName: on ? "eye.fill" : "eye")
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "Come back" : "Push in")
                Button { remove(level) } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        HStack {
            Spacer()
            Button("Add Push-In") { shortcuts.add() }
        }
    }
}

/// An overlay in the list, one line: its name (what and where on hover),
/// and show or hide.
private struct OverlayRow: View {
    let overlay: Overlay
    let showing: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: overlay.kind == .text ? "textformat" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(overlay.name)
                .lineLimit(1)
                .help(summary)
            Spacer(minLength: 8)
            Button(action: toggle) {
                Image(systemName: showing ? "eye.fill" : "eye")
                    .foregroundStyle(showing ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!overlay.canShow)
            .help(!overlay.canShow ? "Nothing to show yet" : showing ? "Hide" : "Show now")
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }

    /// What it is, on hover: the name says enough in the list.
    private var summary: String {
        let content = switch overlay.kind {
        case .text: overlay.lines.count == 1 ? "1 line" : "\(overlay.lines.count) lines"
        case .graphic: overlay.images.count == 1 ? "1 image" : "\(overlay.images.count) images"
        }
        let duration = overlay.duration.map { "hides after \($0.formatted(.number.precision(.fractionLength(0...1)))) s" } ?? "until turned off"
        return "\(content) · \(overlay.spot.label) · \(duration)"
    }
}

/// Edits one overlay, with a preview of it as others see it.
struct OverlayEditor: View {
    @Bindable var library: OverlayLibrary
    let id: UUID
    /// Undoably, by the page that opened it.
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewVariant = 0

    var body: some View {
        VStack(spacing: 0) {
            if let index = library.overlays.firstIndex(where: { $0.id == id }) {
                OverlayForm(
                    overlay: $library.overlays[index],
                    previewVariant: $previewVariant,
                    importGraphics: library.importGraphics
                )
            }
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    dismiss()
                    delete()
                }
                Spacer()
                Button(library.isShowing(id) ? "Hide" : "Show Now") { library.toggle(id) }
                    .disabled(!(library.overlay(id)?.canShow ?? false))
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540, height: 680)
    }
}

struct OverlayForm: View {
    @Binding var overlay: Overlay
    @Binding var previewVariant: Int
    let importGraphics: ([URL]) -> [String]

    var body: some View {
        Form {
            Section {
                OverlayPreview(overlay: overlay, variant: $previewVariant)
            } footer: {
                Text("As people on the call see it. Your own preview is mirrored, so text reads backwards to you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wraps()
            }
            Section {
                TextField("Name", text: $overlay.name)
                Picker("Kind", selection: kind) {
                    Text("Text").tag(Overlay.Kind.text)
                    Text("Graphic").tag(Overlay.Kind.graphic)
                }
                .pickerStyle(.segmented)
            }
            if overlay.kind == .text {
                Section {
                    LinesEditor(lines: $overlay.lines)
                } header: {
                    SettingsHeader("Lines", "More than one: each showing picks one at random. Leave a line blank to show just the icon.")
                }
                Section("Look") {
                    Picker("Style", selection: $overlay.style) {
                        Text("Pill").tag(Overlay.Style.pill)
                        Text("Bar").tag(Overlay.Style.bar)
                        Text("Plain").tag(Overlay.Style.plain)
                    }
                    .pickerStyle(.segmented)
                    SizePicker(size: $overlay.size, sizes: Overlay.Size.textSizes)
                    Picker("Icon", selection: $overlay.icon) {
                        ForEach(Overlay.icons, id: \.label) { icon in
                            Label(icon.label, systemImage: icon.symbol ?? "circle.slash").tag(icon.symbol)
                        }
                    }
                }
            } else {
                Section {
                    ImagesEditor(images: $overlay.images, importGraphics: importGraphics)
                } header: {
                    SettingsHeader("Images", "PNG, PDF, SVG or any image, transparency kept. More than one: each showing picks one at random.")
                }
                Section("Look") {
                    SizePicker(size: $overlay.size, sizes: Overlay.Size.allCases)
                        .disabled(overlay.spot == .fullFrame)
                }
            }
            Section("Placement") {
                SpotPicker(spot: $overlay.spot, allowsFullFrame: overlay.kind == .graphic)
                if overlay.spot == .fullFrame {
                    Picker("Fit", selection: $overlay.fit) {
                        Text("Fit: show all of it").tag(Overlay.Fit.fit)
                        Text("Fill: cover the frame").tag(Overlay.Fit.fill)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            Section {
                Toggle("Hide on its own", isOn: hidesOnItsOwn)
                if let duration = overlay.duration {
                    LabeledContent("After") {
                        HStack(spacing: 6) {
                            TextField("Seconds", value: seconds(duration), format: .number.precision(.fractionLength(0...1)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsHeader("Duration", "Off, it stays until you turn it off.")
            }
        }
        .formStyle(.grouped)
    }

    private var hidesOnItsOwn: Binding<Bool> {
        Binding {
            overlay.duration != nil
        } set: { hides in
            overlay.duration = hides ? 10 : nil
        }
    }

    /// At least half a second, so it shows at all.
    private func seconds(_ duration: Double) -> Binding<Double> {
        Binding {
            duration
        } set: { seconds in
            overlay.duration = max(seconds, 0.5)
        }
    }

    /// Text can't be full frame: switching to it moves the overlay to the top.
    private var kind: Binding<Overlay.Kind> {
        Binding {
            overlay.kind
        } set: { kind in
            overlay.kind = kind
            if kind == .text, overlay.spot == .fullFrame { overlay.spot = .top }
            if kind == .text, !Overlay.Size.textSizes.contains(overlay.size) { overlay.size = .medium }
        }
    }
}

private struct SizePicker: View {
    @Binding var size: Overlay.Size
    let sizes: [Overlay.Size]

    var body: some View {
        Picker("Size", selection: $size) {
            ForEach(sizes, id: \.self) { size in
                Text(size.rawValue.capitalized).tag(size)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// An overlay's lines, one field each.
private struct LinesEditor: View {
    @Binding var lines: [String]

    var body: some View {
        ForEach(lines.indices, id: \.self) { index in
            HStack {
                TextField("Line \(index + 1)", text: line(index))
                    .labelsHidden()
                Button {
                    if lines.indices.contains(index) { lines.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(lines.count <= 1)
                .help("Remove this line")
            }
        }
        Button("Add Line") { lines.append("") }
    }

    /// Safe against the line being removed while its field still shows.
    private func line(_ index: Int) -> Binding<String> {
        Binding {
            lines.indices.contains(index) ? lines[index] : ""
        } set: { text in
            if lines.indices.contains(index) { lines[index] = text }
        }
    }
}

/// A graphic overlay's images: each with its name, removable, and more to add.
private struct ImagesEditor: View {
    @Binding var images: [String]
    let importGraphics: ([URL]) -> [String]

    @State private var choosing = false

    var body: some View {
        ForEach(images, id: \.self) { name in
            HStack(spacing: 10) {
                Group {
                    if let image = OverlayRenderer.graphic(name) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 32)
                .padding(2)
                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 4))
                Text(OverlayLibrary.displayName(ofGraphic: name))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    images.removeAll { $0 == name }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this image")
            }
        }
        Button("Add Images…") { choosing = true }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.image, .pdf, .svg], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { images += importGraphics(urls) }
            }
    }
}

/// The overlay drawn by the same renderer and placement the camera uses, on
/// a stand-in 720p frame, scaled down.
private struct OverlayPreview: View {
    let overlay: Overlay
    @Binding var variant: Int

    private let frame = CGSize(width: 1280, height: 720)
    private let width: CGFloat = 460

    var body: some View {
        let scale = width / frame.width
        let shown = min(max(variant, 0), max(overlay.variants - 1, 0))
        let image = OverlayRenderer.render(overlay, variant: shown, frame: frame)
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.07))
                    .frame(width: frame.height * 0.75 * scale)
                    .frame(width: frame.width * scale, height: frame.height * scale, alignment: .bottom)
                if let image {
                    let size = CGSize(width: image.width, height: image.height)
                    let origin = overlay.spot.origin(for: size, in: frame)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .offset(x: origin.x * scale, y: (frame.height - origin.y - size.height) * scale)
                }
            }
            .frame(width: frame.width * scale, height: frame.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if overlay.variants > 1 {
                HStack {
                    Button { variant = (shown - 1 + overlay.variants) % overlay.variants } label: {
                        Image(systemName: "chevron.left")
                    }
                    Text("\(overlay.kind == .text ? "Line" : "Image") \(shown + 1) of \(overlay.variants)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { variant = (shown + 1) % overlay.variants } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Picks a spot on a little frame. The dashed box is the 4:3 middle apps keep
/// when they crop; spots sit inside it.
private struct SpotPicker: View {
    @Binding var spot: Overlay.Spot
    let allowsFullFrame: Bool

    private let frame = CGSize(width: 192, height: 108)
    private let dot = CGSize(width: 16, height: 16)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.2))
                let safe = Overlay.Spot.safeArea(in: frame)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: safe.width, height: safe.height)
                    .offset(x: safe.minX)
                ForEach(Overlay.Spot.allCases.filter { $0 != .fullFrame }, id: \.self) { candidate in
                    let origin = candidate.origin(for: dot, in: frame)
                    Button { spot = candidate } label: {
                        Circle()
                            .fill(spot == candidate ? Color.accentColor : .white.opacity(0.35))
                            .frame(width: dot.width, height: dot.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(candidate.label)
                    .offset(x: origin.x, y: frame.height - origin.y - dot.height)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .opacity(spot == .fullFrame ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(spot.label)
                    .font(.headline)
                if allowsFullFrame {
                    Toggle("Full frame", isOn: Binding(
                        get: { spot == .fullFrame },
                        set: { spot = $0 ? .fullFrame : .bottomTrailing }
                    ))
                }
                Text("Spots sit inside the middle of the frame that apps keep when they crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wraps()
            }
        }
        .padding(.vertical, 4)
    }
}
