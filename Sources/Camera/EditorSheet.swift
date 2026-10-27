import SwiftUI

/// The frame every effect's editor shares: its name and an on/off switch
/// pinned at the top; the form between; at the bottom, Delete and small
/// actions (reset, duplicate) on the left, Cancel and Done on the right.
/// Edits show as they're made, so the camera can be watched; Cancel
/// (Escape) puts back how things were when it opened, Done (Return) keeps
/// them.
struct EditorSheet<Actions: View, Content: View>: View {
    @Binding var name: String
    let isOn: Bool
    var canTurnOn = true
    let toggle: () -> Void
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
                Toggle("On", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .disabled(!isOn && !canTurnOn)
                    .help(isOn ? "On now: your camera follows as you change it" : "Turn it on to see it on your camera as you change it")
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
