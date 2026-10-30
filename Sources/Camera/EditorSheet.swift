import SwiftUI

/// The frame every effect's editor shares: its name, Preview and an on/off
/// switch pinned at the top; the form between; at the bottom, Delete and
/// small actions (reset, duplicate) on the left, Cancel and Done on the
/// right. Edits show as they're made, so the camera (or Preview) can be
/// watched; Cancel (Escape) puts back how things were when it opened, Done
/// (Return) keeps them.
struct EditorSheet<Actions: View, Content: View>: View {
    @Binding var name: String
    let isOn: Bool
    var canTurnOn = true
    let toggle: () -> Void
    /// Preview's open: on and off are there, not on the camera.
    var previewing = false
    /// Opens Preview, with it on.
    var preview: (() -> Void)?
    let delete: () -> Void
    let cancel: () -> Void
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                if let preview {
                    Button(action: preview) {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                    .disabled(!isOn && !canTurnOn)
                    .help("Try it in a window of its own, where the call can't see it")
                }
                Toggle("On", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .disabled(!isOn && !canTurnOn)
                    .help(previewing
                        ? (isOn ? "On in Preview: it follows as you change it" : "Turn it on in Preview")
                        : (isOn ? "On now: your camera follows as you change it" : "Turn it on to see it on your camera as you change it"))
            }
            .padding(14)
            Divider()
            content
            Divider()
            HStack(spacing: 12) {
                Button("Delete", role: .destructive) {
                    dismiss()
                    delete()
                }
                actions
                    .buttonStyle(.borderless)
                Spacer()
                Button("Cancel") {
                    cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: width, height: height)
    }
}
