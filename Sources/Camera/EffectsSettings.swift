import SwiftUI
import UniformTypeIdentifiers

/// Your effects, each turned on and off by name, holding whatever you put in
/// it: text or graphics, a push-in, a look, a shake, other effects to build
/// on. Also
/// the default effect, and the one on while you dictate.
struct EffectsPage: View {
    let effects: Effects

    @State private var editing: Editing?
    /// The Settings window's: deleting an effect can be undone.
    @Environment(\.undoManager) private var undoManager

    private struct Editing: Identifiable {
        let id: UUID
        /// Just added: Cancel takes it away again.
        var isNew = false
    }

    private var library: EffectLibrary { effects.library }

    var body: some View {
        @Bindable var library = library
        Form {
            Section {
                ForEach(library.effects) { effect in
                    EffectRow(
                        effect: effect,
                        summary: summary(of: effect),
                        badge: library.defaultEffect == effect.id ? "Default" : library.dictationEffect == effect.id ? "Dictating" : nil,
                        isOn: library.isOn(effect.id),
                        toggle: { effects.triggers.trigger(.effect(effect.id)) },
                        edit: { editing = Editing(id: effect.id) }
                    )
                    .contextMenu {
                        Button("Edit…") { editing = Editing(id: effect.id) }
                        Button("Duplicate") { library.duplicate(effect.id) }
                        Divider()
                        Button(library.defaultEffect == effect.id ? "Not the Default" : "Make Default") {
                            library.defaultEffect = library.defaultEffect == effect.id ? nil : effect.id
                        }
                        Button(library.dictationEffect == effect.id ? "Not While Dictating" : "Use While Dictating") {
                            library.dictationEffect = library.dictationEffect == effect.id ? nil : effect.id
                        }
                        Divider()
                        Button("Delete", role: .destructive) { remove(effect.id) }
                    }
                }
                .onMove { library.effects.move(fromOffsets: $0, toOffset: $1) }
                // Under its list, at the trailing edge, as in System
                // Settings; a menu where there's a choice to make.
                HStack {
                    Spacer()
                    AddEffectMenu { editing = Editing(id: library.add($0).id, isNew: true) }
                }
            } header: {
                SettingsHeader("Effects", "Each turns on by name, with what you put in it: text or a graphic, a push-in, a look, a shake, other effects to build on. Effects on together stack, the latest on top.")
            }
            Section {
                Picker("Default effect", selection: $library.defaultEffect) {
                    Text("None").tag(UUID?.none)
                    ForEach(library.effects) { effect in
                        Text(effect.name).tag(UUID?.some(effect.id))
                    }
                }
                Picker("While dictating", selection: $library.dictationEffect) {
                    Text("Nothing").tag(UUID?.none)
                    ForEach(library.effects) { effect in
                        Text(effect.name).tag(UUID?.some(effect.id))
                    }
                }
            } header: {
                SettingsHeader("Default and Dictating", "The default effect is on under everything else. The dictating one is on while solo mode is, so the call knows why you're muted.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsHeader.pageWidth)
        .sheet(item: $editing) { editing in
            EffectEditor(effects: effects, id: editing.id, isNew: editing.isNew, delete: { remove(editing.id) }) {
                if let copy = library.duplicate(editing.id) { self.editing = Editing(id: copy.id, isNew: true) }
            }
        }
    }

    private func remove(_ id: UUID) {
        effects.remove(id, undo: undoManager)
    }

    /// What's in it, on hover: the name says enough in the list.
    private func summary(of effect: Effect) -> String {
        var parts = effect.includes.compactMap { library.effect($0)?.name }
        parts += effect.overlays.map { $0.kind == .text ? "Text" : "Graphic" }
        if let pushIn = effect.pushIn { parts.append("Push in \(pushIn.zoomText)") }
        if effect.look != nil { parts.append("Look") }
        if effect.shake != nil { parts.append("Shake") }
        var summary = parts.isEmpty ? "Nothing in it yet" : parts.joined(separator: " + ")
        if let duration = effect.duration { summary += " · off after \(duration.formatted(.number.precision(.fractionLength(0...1)))) s" }
        return summary
    }
}

/// An effect in the list, one line: what it mostly is, its name (what's in
/// it on hover), Default or Dictating, and on or off.
private struct EffectRow: View {
    let effect: Effect
    let summary: String
    let badge: String?
    let isOn: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(for: effect))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(effect.name)
                .lineLimit(1)
                .help(summary)
            if let badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 8)
            Button(action: toggle) {
                Image(systemName: isOn ? "eye.fill" : "eye")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(effect.isEmpty && !isOn)
            .help(effect.isEmpty ? "Nothing in it yet" : isOn ? "Turn off" : "Turn on")
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

    /// By its first part.
    static func symbol(for effect: Effect) -> String {
        if let overlay = effect.overlays.first { return overlay.kind == .text ? "textformat" : "photo" }
        if effect.look != nil { return "camera.filters" }
        if effect.pushIn != nil { return "plus.magnifyingglass" }
        if effect.shake != nil { return "rectangle.on.rectangle.angled" }
        if !effect.includes.isEmpty { return "square.stack.3d.up" }
        return "sparkles"
    }
}

/// Starting points for a new effect, each with one part to begin from.
private struct AddEffectMenu: View {
    let add: (Effect) -> Void

    var body: some View {
        Menu("Add Effect") {
            Button("Text") { add(Effect(name: "New Text", overlays: [.newText])) }
            Button("Graphic") { add(Effect(name: "New Graphic", overlays: [.newGraphic])) }
            Button("Push In") { add(Effect(name: "Push In", pushIn: 1.5)) }
            Button("Shake") { add(Effect(name: "Shake", shake: Effect.Shake())) }
            Menu("Look") {
                Button("Plain") { add(Effect(name: "New Look", look: Look(name: "Look"))) }
                Section("Presets") {
                    ForEach(Look.presets) { preset in
                        Button(preset.name) { add(Effect(name: preset.name, look: preset.copy)) }
                    }
                }
            }
            Divider()
            Button("Empty") { add(Effect(name: "New Effect")) }
        }
        .fixedSize()
    }
}

/// Edits an effect, part by part. Edits show as they're made, on the
/// camera too while it's on.
struct EffectEditor: View {
    let effects: Effects
    let id: UUID
    /// Just added: Cancel takes it away again.
    var isNew = false
    /// Undoably, by the page that opened it.
    let delete: () -> Void
    /// Opens a copy to edit, by the page that opened it.
    let duplicate: () -> Void
    /// Snapshots draw it whole.
    var height: CGFloat = 720

    /// How it was when opened, and whether it was on, for Cancel.
    @State private var opened: (effect: Effect, on: Bool)?

    var body: some View {
        let library = effects.library
        if let effect = library.effect(id) {
            let edited = edited(effect)
            EditorSheet(
                name: edited.name,
                isOn: library.isOn(id),
                canTurnOn: !effect.isEmpty,
                toggle: { effects.triggers.trigger(.effect(id)) },
                delete: delete,
                cancel: cancel,
                width: 560,
                height: height
            ) {
                Button(action: duplicate) { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate, to make another version of it")
            } content: {
                EffectForm(effect: edited, library: library)
            }
            .onAppear {
                if opened == nil { opened = (effect, library.isOn(id)) }
            }
        }
    }

    /// The effect by its ID, not its place in the list: a field still
    /// finishing an edit as it goes, once the effect's deleted, changes
    /// nothing (by place, it would change whatever moved into that place, or
    /// crash).
    private func edited(_ effect: Effect) -> Binding<Effect> {
        let library = effects.library
        return Binding {
            library.effect(id) ?? effect
        } set: { changed in
            if let index = library.effects.firstIndex(where: { $0.id == id }) { library.effects[index] = changed }
        }
    }

    /// Back to how it was, on or off as it was. One just added goes.
    private func cancel() {
        let library = effects.library
        guard let opened else { return }
        if isNew {
            library.remove(id)
            return
        }
        if let index = library.effects.firstIndex(where: { $0.id == id }) {
            library.effects[index] = opened.effect
        }
        if library.isOn(id) != opened.on { effects.triggers.trigger(.effect(id)) }
    }
}

/// An effect's parts, each in its own section with a button to take it out,
/// and a menu to add more.
struct EffectForm: View {
    @Binding var effect: Effect
    let library: EffectLibrary

    /// The line or image each overlay's preview shows.
    @State private var previewVariants: [UUID: Int] = [:]

    var body: some View {
        Form {
            // What it builds on shows too, under its own.
            let overlays = library.parts(of: effect).flatMap(\.overlays)
            if !overlays.isEmpty {
                Section {
                    EffectPreview(overlays: overlays, variants: previewVariants)
                } footer: {
                    Text("As people on the call see it. Your own preview is mirrored, so text reads backwards to you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .wraps()
                }
            }
            if !effect.includes.isEmpty {
                Section {
                    ForEach(effect.includes, id: \.self) { included in
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(library.effect(included)?.name ?? "A deleted effect")
                                .foregroundStyle(library.effect(included) == nil ? .secondary : .primary)
                            Spacer()
                            Button { effect.includes.removeAll { $0 == included } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Don't build on it")
                        }
                    }
                } header: {
                    SettingsHeader("Builds On", "These effects come with this one, under its own parts, in order.")
                }
            }
            ForEach(effect.overlays) { overlay in
                OverlaySections(overlay: binding(to: overlay), variant: variant(of: overlay), importGraphics: library.importGraphics) {
                    effect.overlays.removeAll { $0.id == overlay.id }
                }
            }
            if let pushIn = effect.pushIn {
                Section {
                    HStack(spacing: 8) {
                        // Rounded to 0.05× rather than stepped, which draws
                        // a tick mark for every step.
                        Slider(
                            value: Binding(get: { pushIn }, set: { effect.pushIn = ($0 * 20).rounded() / 20 }),
                            in: Effect.pushInRange
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        Text(pushIn.zoomText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } header: {
                    PartHeader("Push In", "Zooms further, on top of each camera's own zoom, up to 2×.") { effect.pushIn = nil }
                }
            }
            if let shake = effect.shake {
                Section {
                    HStack(spacing: 8) {
                        Text("Gentle")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(get: { shake.amount }, set: { effect.shake?.amount = ($0 * 20).rounded() / 20 }),
                            in: 0...1
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        Text("Wild")
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(get: { shake.blur }, set: { effect.shake?.blur = $0 })) {
                        Text("Motion blur")
                        Text("Smears the picture the way it's moving, as a camera would.")
                    }
                    Toggle(isOn: Binding(get: { shake.overlays }, set: { effect.shake?.overlays = $0 })) {
                        Text("Shake overlays too")
                        Text("Off, text and graphics hold still over the moving picture.")
                    }
                } header: {
                    PartHeader("Shake", "Jolts and tilts the picture within the camera's frame, so it pushes in to have room: \(shake.zoom.zoomText) at this amount, unless it's in that far already.") { effect.shake = nil }
                }
            }
            if effect.look != nil {
                LookSections(look: Binding(get: { effect.look ?? Look(name: "Look") }, set: { effect.look = $0 })) {
                    effect.look = nil
                }
            }
            Section {
                HStack {
                    if effect.isEmpty {
                        Text("Add text, a graphic, a push-in, a shake, a look, or another effect to build on.")
                            .foregroundStyle(.secondary)
                            .wraps()
                    }
                    Spacer()
                    AddPartMenu(effect: $effect, library: library)
                }
            }
            Section {
                Toggle("Turn off on its own", isOn: turnsOffOnItsOwn)
                if let duration = effect.duration {
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
                SettingsHeader("Duration", "Off, it stays on until you turn it off.")
            }
        }
        .formStyle(.grouped)
    }

    /// An overlay by its ID, not its place: a field still finishing an edit
    /// as its overlay is taken out (its text, say) changes nothing, where by
    /// place it crashed.
    private func binding(to overlay: Overlay) -> Binding<Overlay> {
        Binding {
            effect.overlays.first { $0.id == overlay.id } ?? overlay
        } set: { changed in
            if let index = effect.overlays.firstIndex(where: { $0.id == overlay.id }) { effect.overlays[index] = changed }
        }
    }

    private func variant(of overlay: Overlay) -> Binding<Int> {
        Binding {
            previewVariants[overlay.id] ?? 0
        } set: { variant in
            previewVariants[overlay.id] = variant
        }
    }

    private var turnsOffOnItsOwn: Binding<Bool> {
        Binding {
            effect.duration != nil
        } set: { turnsOff in
            effect.duration = turnsOff ? 10 : nil
        }
    }

    /// At least half a second, so it shows at all.
    private func seconds(_ duration: Double) -> Binding<Double> {
        Binding {
            duration
        } set: { seconds in
            effect.duration = max(seconds, 0.5)
        }
    }
}

/// A part's title, a line about it, and a button to take it out (and to
/// reset it, for a look).
struct PartHeader: View {
    let title: String
    let description: String?
    var reset: (() -> Void)?
    let remove: () -> Void

    init(_ title: String, _ description: String? = nil, reset: (() -> Void)? = nil, remove: @escaping () -> Void) {
        self.title = title
        self.description = description
        self.reset = reset
        self.remove = remove
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SettingsHeader(title, description)
            Spacer(minLength: 8)
            if let reset {
                Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Back to how it started")
            }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Take it out of this effect")
        }
    }
}

/// More for an effect: text or a graphic, a push-in, a shake or a look if it
/// has none, or another effect to build on.
private struct AddPartMenu: View {
    @Binding var effect: Effect
    let library: EffectLibrary

    var body: some View {
        let buildable = library.effects.filter { library.canInclude($0.id, in: effect.id) && !effect.includes.contains($0.id) }
        Menu("Add to Effect") {
            Button("Text") { effect.overlays.append(.newText) }
            Button("Graphic") { effect.overlays.append(.newGraphic) }
            Button("Push In") { effect.pushIn = 1.5 }
                .disabled(effect.pushIn != nil)
            Button("Shake") { effect.shake = Effect.Shake() }
                .disabled(effect.shake != nil)
            Menu("Look") {
                Button("Plain") { effect.look = Look(name: "Look") }
                Section("Presets") {
                    ForEach(Look.presets) { preset in
                        Button(preset.name) { effect.look = preset.copy }
                    }
                }
            }
            .disabled(effect.look != nil)
            Menu("Effect to Build On") {
                ForEach(buildable) { other in
                    Button(other.name) { effect.includes.append(other.id) }
                }
            }
            .disabled(buildable.isEmpty)
        }
        .fixedSize()
    }
}

/// An overlay in an effect: what it shows (lines or images), then how it
/// looks and where it goes.
private struct OverlaySections: View {
    @Binding var overlay: Overlay
    @Binding var variant: Int
    let importGraphics: ([URL]) -> [String]
    let remove: () -> Void

    var body: some View {
        Section {
            if overlay.kind == .text {
                LinesEditor(lines: $overlay.lines)
            } else {
                ImagesEditor(images: $overlay.images, importGraphics: importGraphics)
            }
            if overlay.variants > 1 {
                LabeledContent("Preview") {
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
        } header: {
            if overlay.kind == .text {
                PartHeader("Text", "More than one line: each showing picks one at random. Each line has its own icon; leave its text blank to show just the icon.", remove: remove)
            } else {
                PartHeader("Graphic", "PNG, PDF, SVG or any image, transparency kept. More than one: each showing picks one at random.", remove: remove)
            }
        }
        Section {
            if overlay.kind == .text {
                Picker("Style", selection: $overlay.style) {
                    Text("Pill").tag(Overlay.Style.pill)
                    Text("Bar").tag(Overlay.Style.bar)
                    Text("Plain").tag(Overlay.Style.plain)
                }
                .pickerStyle(.segmented)
                SizePicker(size: $overlay.size, sizes: Overlay.Size.textSizes)
            } else {
                SizePicker(size: $overlay.size, sizes: Overlay.Size.allCases)
                    .disabled(overlay.spot == .fullFrame)
            }
            SpotPicker(spot: $overlay.spot, allowsFullFrame: overlay.kind == .graphic)
            if overlay.spot == .fullFrame {
                Picker("Fit", selection: $overlay.fit) {
                    Text("Fit: show all of it").tag(Overlay.Fit.fit)
                    Text("Fill: cover the frame").tag(Overlay.Fit.fill)
                }
                .pickerStyle(.radioGroup)
            }
        }
    }

    private var shown: Int { min(max(variant, 0), max(overlay.variants - 1, 0)) }
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

/// An overlay's lines, one field each, its icon before it.
private struct LinesEditor: View {
    @Binding var lines: [Overlay.Line]

    var body: some View {
        ForEach(lines.indices, id: \.self) { index in
            HStack {
                LineIcon(icon: line(index).icon)
                TextField("Line \(index + 1)", text: line(index).text)
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
        // With the last line's icon, as a set usually goes.
        Button("Add Line") { lines.append(Overlay.Line(text: "", icon: lines.last?.icon)) }
    }

    /// Safe against the line being removed while its field still shows.
    private func line(_ index: Int) -> Binding<Overlay.Line> {
        Binding {
            lines.indices.contains(index) ? lines[index] : Overlay.Line(text: "")
        } set: { line in
            if lines.indices.contains(index) { lines[index] = line }
        }
    }
}

/// A line's icon, or a place for one: opens the icons to pick from.
private struct LineIcon: View {
    @Binding var icon: String?

    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            OverlayIcon(icon: icon ?? "circle.dashed")
                .foregroundStyle(icon == nil ? .tertiary : .primary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon == nil ? "Add an icon" : "Change the icon")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            IconChoices(icon: $icon, layout: .square) { choosing = false }
                .padding(12)
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
                Text(EffectLibrary.displayName(ofGraphic: name))
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


/// An effect's overlays drawn by the same renderer and placement the camera
/// uses, each spot's last, on a stand-in 720p frame, scaled down.
private struct EffectPreview: View {
    let overlays: [Overlay]
    /// The line or image each shows.
    let variants: [UUID: Int]

    private let frame = CGSize(width: 1280, height: 720)
    private let width: CGFloat = 460

    var body: some View {
        let scale = width / frame.width
        let bySpot = Dictionary(overlays.map { ($0.spot, $0) }, uniquingKeysWith: { _, last in last })
        let order = [Overlay.Spot.fullFrame] + Overlay.Spot.allCases.filter { $0 != .fullFrame }
        let images = order.compactMap { spot -> (spot: Overlay.Spot, image: CGImage)? in
            guard let overlay = bySpot[spot] else { return nil }
            let variant = min(max(variants[overlay.id] ?? 0, 0), max(overlay.variants - 1, 0))
            return OverlayRenderer.render(overlay, variant: variant, frame: frame).map { (spot, $0) }
        }
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.07))
                .frame(width: frame.height * 0.75 * scale)
                .frame(width: frame.width * scale, height: frame.height * scale, alignment: .bottom)
            // By spot (one each), not place: never a place that's gone.
            ForEach(images, id: \.spot) { spot, image in
                let size = CGSize(width: image.width, height: image.height)
                let origin = spot.origin(for: size, in: frame)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: size.width * scale, height: size.height * scale)
                    .offset(x: origin.x * scale, y: (frame.height - origin.y - size.height) * scale)
            }
        }
        .frame(width: frame.width * scale, height: frame.height * scale)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
