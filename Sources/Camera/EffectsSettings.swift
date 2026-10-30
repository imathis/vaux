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

    /// The group whose name, icon and color are open.
    @State private var editingGroup: UUID?
    /// A backup picked to import, before choosing how.
    @State private var importing: EffectsBackup?
    @State private var importError: String?


    private var library: EffectLibrary { effects.library }

    var body: some View {
        @Bindable var library = library
        Form {
            Section {
                // One list, groups' names in it as headers: an effect dragged
                // under one goes in that group; above them all, in none. A
                // List, which drags to reorder (a Form's rows don't), as tall
                // as its rows, so it never scrolls inside the page.
                List {
                    // No row is move-disabled: SwiftUI keeps such a row at its
                    // place, refusing any drop that would shift it.
                    ForEach(rows) { row in
                        switch row {
                        case .effect(let effect): line(effectRow(effect))
                        case .group(let group): line(groupRow(group))
                        case .end(_, empty: true):
                            line(Text("Drag effects here")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 70)
                                .frame(maxWidth: .infinity, alignment: .leading))
                        case .end:
                            // A boundary, not a gap: dropped over the bottom
                            // of the group's last effect, an effect lands
                            // above it; over the top of the next, below it.
                            Color.clear
                                .frame(height: 1)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                // Lets a group's end be a line thin.
                .environment(\.defaultMinListRowHeight, 1)
                // A little past the last row, so the end takes a drop too.
                .frame(height: rows.map(\.height).reduce(0, +) + 12)
                // Under its list, at the trailing edge, as in System
                // Settings; a menu where there's a choice to make. Preview
                // at the leading edge, apart.
                HStack {
                    Button { effects.preview.show() } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                    .help("Try effects in a window of their own, where the call can't see them")
                    Spacer()
                    Button("Add Group") { editingGroup = library.addGroup().id }
                    AddEffectMenu {
                        editing = Editing(id: library.add($0).id, isNew: true)
                    } addGroup: { group, members in
                        // A copy of the group, its effects in it.
                        StarterGraphics.install()
                        let copy = library.addGroup(named: group.name)
                        if let index = library.groups.firstIndex(where: { $0.id == copy.id }) {
                            library.groups[index].icon = group.icon
                            library.groups[index].color = group.color
                        }
                        for var effect in members {
                            effect.group = copy.id
                            library.add(effect)
                        }
                    }
                }
            } header: {
                SettingsHeader("Effects", "One at a time, over the default effect. To layer, build one on others.")
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
                SettingsHeader("Default and Dictating", "The default is always on, underneath. The other shows while you dictate.")
            }
            Section {
                LabeledContent("Effects, groups, graphics and keys") {
                    HStack {
                        Button("Import…", action: chooseImport)
                        Button("Export…", action: export)
                    }
                }
            } header: {
                SettingsHeader("Backup", "One file to keep, or to share. Not your mics and cameras.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsHeader.pageWidth)
        .sheet(item: $editing) { editing in
            EffectEditor(effects: effects, id: editing.id, isNew: editing.isNew, delete: { remove(editing.id) }) {
                if let copy = library.duplicate(editing.id) { self.editing = Editing(id: copy.id, isNew: true) }
            }
        }
        .sheet(isPresented: Binding(get: { editingGroup != nil }, set: { if !$0 { editingGroup = nil } })) {
            if let editingGroup { GroupEditor(library: library, id: editingGroup) }
        }
        .confirmationDialog(
            importTitle,
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            titleVisibility: .visible,
            presenting: importing
        ) { backup in
            Button("Add to Your Effects") { effects.add(backup) }
            Button("Replace Your Effects", role: .destructive) {
                do { try effects.restore(backup) } catch { importError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Adding keeps yours and adds copies. Replacing swaps in everything, keys too; yours are saved in Vaux's Backups folder first.")
        }
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var importTitle: String {
        guard let importing else { return "" }
        let count = importing.effects.effects.count
        return "Import \(count) \(count == 1 ? "effect" : "effects")?"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.vauxEffects]
        panel.nameFieldStringValue = "\(VauxCamera.appName) Effects"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try effects.backup().write(to: url) } catch { importError = error.localizedDescription }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.vauxEffects]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { importing = try EffectsBackup.read(url) } catch { importError = "That file isn't a Vaux effects backup." }
        }
    }

    private func remove(_ id: UUID) {
        effects.remove(id, undo: undoManager)
    }

    /// The list as it's listed: effects in no group, and each group's name,
    /// its effects, and its end.
    private var rows: [EffectListRow] {
        library.listing.flatMap { listed -> [EffectListRow] in
            switch listed {
            case .effect(let effect): [.effect(effect)]
            case .group(let group, let effects): [.group(group)] + effects.map(EffectListRow.effect) + [.end(group, empty: effects.isEmpty)]
            }
        }
    }

    /// Dropped: see EffectListRow.
    private func move(from offsets: IndexSet, to destination: Int) {
        let (effects, groups, outline) = EffectListRow.arrangement(of: EffectListRow.moved(rows, offsets, to: destination))
        library.arrange(effects: effects, groups: groups, outline: outline)
    }

    /// A row of the list, a line tall.
    private func line(_ content: some View) -> some View {
        content
            .frame(height: 22)
            .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
    }

    private func effectRow(_ effect: Effect) -> some View {
        EffectRow(
            effect: effect,
            tint: library.tint(of: effect),
            inGroup: effect.group.flatMap(library.group) != nil,
            summary: summary(of: effect),
            badge: library.defaultEffect == effect.id ? "Default" : library.dictationEffect == effect.id ? "Dictating" : nil,
            isOn: library.isOn(effect.id),
            toggle: { effects.triggers.trigger(.effect(effect.id)) },
            edit: { editing = Editing(id: effect.id) }
        )
        .contextMenu {
            Button("Edit…") { editing = Editing(id: effect.id) }
            Button("Duplicate") { library.duplicate(effect.id) }
            Menu("Move to Group") {
                Button("No Group") { library.move(effect.id, toGroup: nil) }
                    .disabled(effect.group == nil)
                ForEach(library.groups) { group in
                    Button(group.name) { library.move(effect.id, toGroup: group.id) }
                        .disabled(effect.group == group.id)
                }
                Divider()
                Button("New Group…") {
                    let group = library.addGroup()
                    library.move(effect.id, toGroup: group.id)
                    editingGroup = group.id
                }
            }
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

    private func groupRow(_ group: EffectGroup) -> some View {
        let index = library.groups.firstIndex { $0.id == group.id } ?? 0
        return GroupRow(group: group, tint: library.tint(of: group)) {
            editingGroup = group.id
        }
        .contextMenu {
            Button("Edit…") { editingGroup = group.id }
            Button("Move Up") { library.groups.swapAt(index, index - 1) }
                .disabled(index == 0)
            Button("Move Down") { library.groups.swapAt(index, index + 1) }
                .disabled(index == library.groups.count - 1)
            Divider()
            Button("Delete Group", role: .destructive) { library.removeGroup(group.id) }
        }
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

/// An effect in the list, one line: a handle to drag it by, what it mostly
/// is, its name (what's in it on hover), Default or Dictating, and on or
/// off. Click it to edit it.
private struct EffectRow: View {
    let effect: Effect
    let tint: Effect.Tint
    /// Listed under a group's name: set in from it.
    let inGroup: Bool
    let summary: String
    let badge: String?
    let isOn: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder, or into a group")
            // Drag it by its handle; click anywhere else to edit it (a
            // click across the whole row would swallow the drag).
            Button(action: edit) {
                HStack(spacing: 10) {
                    EffectBadge(icon: effect.shownIcon, tint: tint)
                        .frame(width: 20)
                        .padding(.leading, inGroup ? 18 : 0)
                    Text(effect.name)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(summary)
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
    }
}

/// A group's name over its effects, and what it shows as: dragged by its
/// handle, the group moves with them. Click it to edit it.
private struct GroupRow: View {
    let group: EffectGroup
    let tint: Effect.Tint
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to move the group, its effects with it")
            // Drag it by its handle; click anywhere else to edit it.
            Button(action: edit) {
                HStack(spacing: 10) {
                    EffectBadge(icon: group.shownIcon, tint: tint)
                        .frame(width: 20)
                    Text(group.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")
        }
    }
}

/// A group's name, icon and color.
private struct GroupEditor: View {
    let library: EffectLibrary
    let id: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let group = library.group(id) {
            let edited = Binding {
                library.group(id) ?? group
            } set: { changed in
                if let index = library.groups.firstIndex(where: { $0.id == id }) { library.groups[index] = changed }
            }
            let place = library.groups.firstIndex { $0.id == id } ?? 0
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("Name", text: edited.name)
                        LabeledContent("Icon") {
                            EffectIconPicker(icon: edited.icon, shown: group.shownIcon, tint: library.tint(of: group))
                        }
                        LabeledContent("Color") {
                            TintPicker(color: edited.color, automatic: Effect.Tint.byPlace[place % Effect.Tint.byPlace.count])
                        }
                    } header: {
                        SettingsHeader("Group", "Listed together, and a key on Stream Deck that opens them.")
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Button("Delete Group", role: .destructive) {
                        dismiss()
                        library.removeGroup(id)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 480, height: 290)
        }
    }
}

/// Starting points for a new effect, each with one part to begin from.
private struct AddEffectMenu: View {
    let add: (Effect) -> Void
    /// A ready-made group, with its effects.
    let addGroup: (EffectGroup, [Effect]) -> Void

    var body: some View {
        Menu("Add Effect") {
            Button("Text") { add(Effect(name: "New Text", overlays: [.newText])) }
            Button("Graphic") { add(Effect(name: "New Graphic", overlays: [.newGraphic])) }
            Button("Push In") { add(Effect(name: "Push In", pushIn: 1.5)) }
            // A shake's a moment: it turns itself off.
            Button("Shake") { add(Effect(name: "Shake", shake: Effect.Shake(), duration: 2)) }
            Menu("Look") {
                Button("Plain") { add(Effect(name: "New Look", look: Look(name: "Look"))) }
                Section("Presets") {
                    ForEach(Look.presets) { preset in
                        Button(preset.name) { add(Effect(name: preset.name, look: preset.copy)) }
                    }
                }
            }
            // The ones Vaux comes with, again or for the first time.
            Menu("Ready-Made") {
                ForEach(Effect.starters.indices, id: \.self) { index in
                    Button(Effect.starters[index].name) { add(Effect.starters[index]) }
                }
                Divider()
                Button("\(EffectGroup.away.group.name) (a group)") {
                    let away = EffectGroup.away
                    addGroup(away.group, away.effects)
                }
            }
            Divider()
            Button("Empty") { add(Effect(name: "New Effect")) }
        }
        .fixedSize()
    }
}

/// Edits an effect, part by part. Edits show as they're made, on the
/// camera too while it's on (or in Preview, while that's open).
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
                previewing: library.preview != nil,
                preview: { effects.preview.show(id) },
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
                    Picker(selection: $effect.pushInMove.curve) {
                        ForEach(Effect.Move.Curve.allCases, id: \.self) { curve in
                            Text(curve.label).tag(curve)
                        }
                    } label: {
                        Text("Transition")
                        Text(effect.pushInMove.curve.summary)
                    }
                    if effect.pushInMove.curve != .snap {
                        SecondsSlider(label: "Over", seconds: $effect.pushInMove.seconds, stops: SecondsSlider.moveStops)
                    }
                } header: {
                    PartHeader("Push In", "Zooms in as it comes on and out as it goes, up to 2×.") { effect.pushIn = nil }
                }
            }
            if let shake = effect.shake {
                Section {
                    Picker(selection: Binding(get: { shake.motion }, set: { effect.shake?.motion = $0 })) {
                        ForEach(Effect.Shake.Motion.allCases, id: \.self) { motion in
                            Text(motion.label).tag(motion)
                        }
                    } label: {
                        Text("Motion")
                        Text(shake.motion.summary(pace: shake.pace))
                    }
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
                    HStack(spacing: 8) {
                        Text("Slow")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(get: { shake.pace }, set: { effect.shake?.pace = ($0 * 20).rounded() / 20 }),
                            in: 0...1
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        Text("Fast")
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(get: { shake.builds && effect.duration != nil }, set: { effect.shake?.builds = $0 })) {
                        Text("Build up")
                        Text(effect.duration == nil ? "Needs Turn off on its own, below: it builds toward when it turns off." : "From a quarter to full, three quarters of the way through its time.")
                    }
                    .disabled(effect.duration == nil)
                    Toggle(isOn: Binding(get: { shake.blur }, set: { effect.shake?.blur = $0 })) {
                        Text("Motion blur")
                        Text("Smears the picture the way it's moving, as a camera would.")
                    }
                    Toggle(isOn: Binding(get: { shake.overlays }, set: { effect.shake?.overlays = $0 })) {
                        Text("Shake overlays too")
                        Text("Off, text and graphics hold still over the moving picture.")
                    }
                } header: {
                    PartHeader("Shake", "Pushes in \(shake.zoom.zoomText) to make room for the movement.") { effect.shake = nil }
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
                    SecondsSlider(label: "After", seconds: Binding(get: { duration }, set: { effect.duration = $0 }))
                }
            } header: {
                SettingsHeader("Duration", effect.duration == nil ? "Off, it stays on until you turn it off." : "It turns itself off after the time below.")
            }
            Section {
                Toggle(isOn: $effect.mutesMic) {
                    Text("Mute while on")
                    Text("Unmutes as it goes, unless you were muted already.")
                }
            }
            Section {
                Picker("Group", selection: $effect.group) {
                    Text("None").tag(UUID?.none)
                    ForEach(library.groups) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }
                LabeledContent("Icon") {
                    EffectIconPicker(icon: $effect.icon, shown: effect.shownIcon, tint: library.tint(of: effect))
                }
                LabeledContent("Color") {
                    TintPicker(color: $effect.color, automatic: effect.shownTint(atPlace: library.effects.firstIndex { $0.id == effect.id } ?? 0))
                }
            } header: {
                SettingsHeader("Group, Icon and Color", "How it's listed, and how its Stream Deck key looks.")
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
            // A shake's a moment.
            effect.duration = turnsOff ? (effect.shake != nil ? 2 : 10) : nil
        }
    }
}

/// A time in seconds, on a slider: stops close together where a little
/// makes a difference, further apart as it gets longer. Arrow keys move a
/// stop at a time.
private struct SecondsSlider: View {
    let label: String
    @Binding var seconds: Double
    var stops = Self.durationStops

    /// How long an effect stays on: tenths to 3 seconds, quarters to 5,
    /// halves to 10, then wider.
    static let durationStops: [Double] = stride(from: 0.5, to: 3, by: 0.1).map { ($0 * 10).rounded() / 10 }
        + stride(from: 3, to: 5, by: 0.25).map { $0 }
        + stride(from: 5, to: 10, by: 0.5).map { $0 }
        + [10, 12, 15, 20, 30, 45, 60]
    /// How long a push in or out takes: a tenth of a second to 3.
    static let moveStops: [Double] = stride(from: 0.1, to: 1, by: 0.05).map { ($0 * 100).rounded() / 100 }
        + stride(from: 1, through: 3, by: 0.25).map { $0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(
                value: Binding(get: { Double(nearest) }, set: { seconds = stops[Int($0.rounded())] }),
                in: 0...Double(stops.count - 1)
            )
            .labelsHidden()
            .controlSize(.small)
            Text("\(seconds.formatted(.number.precision(.fractionLength(0...2)))) s")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    /// The stop it's at, or closest to (one set before there were stops).
    private var nearest: Int {
        stops.indices.min { abs(stops[$0] - seconds) < abs(stops[$1] - seconds) } ?? 0
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
            Button("Shake") {
                effect.shake = Effect.Shake()
                // A shake's a moment: it turns itself off, unless the effect
                // already does.
                if effect.duration == nil { effect.duration = 2 }
            }
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
                PartHeader("Text", "Several lines: each showing picks one at random. Blank text shows just the icon.", remove: remove)
            } else {
                PartHeader("Graphic", "An image, video or GIF, transparency kept. Several: each showing picks one.", remove: remove)
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
                // A video's length, to set the effect to play it once.
                if OverlayVideo.isVideo(name), let seconds = VideoPosters.shared.poster(name)?.seconds {
                    Text("\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("A video, looping. To play it once, turn the effect off on its own after this long.")
                }
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
        Button("Add Images or Videos…") { choosing = true }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.image, .pdf, .svg, .movie], allowsMultipleSelection: true) { result in
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
                Text("Inside the part of the frame apps keep when they crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wraps()
            }
        }
        .padding(.vertical, 4)
    }
}
