import SwiftUI

/// A look in the list, one line: on (one at a time), its name, its Quick
/// Menu key, and edit.
struct LookRow: View {
    let look: Look
    let key: String?
    let isOn: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(isOn ? "Turn off" : "Turn on")
            Text(look.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let key { KeyCap(key: key, muted: true) }
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

/// Edits a look. While it's on, the camera follows each slider as it moves:
/// the preview is your call app's own.
struct LookEditor: View {
    let effects: Effects
    let id: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var library = effects.looks
        VStack(spacing: 0) {
            if let index = library.looks.firstIndex(where: { $0.id == id }) {
                let look = $library.looks[index]
                Form {
                    Section {
                        TextField("Name", text: look.name)
                    } footer: {
                        Text(library.active == id
                            ? "On now: your camera follows as you change it."
                            : "Turn it on to see it on your camera as you change it.")
                            .foregroundStyle(.secondary)
                            .wraps()
                    }
                    Section {
                        LookSlider(title: "Saturation", value: look.saturation, range: Look.saturationRange, format: .percent)
                        LookSlider(title: "Contrast", value: look.contrast, range: Look.contrastRange, format: .percent)
                        LookSlider(title: "Brightness", value: look.brightness, range: Look.brightnessRange, format: .signedPercent)
                        LookSlider(title: "Warmth", value: look.warmth, range: Look.warmthRange, format: .signedPercent)
                    } header: {
                        SettingsHeader("Color")
                    }
                    Section {
                        LookSlider(title: "Fade", value: look.fade, range: Look.amountRange, format: .percent)
                        LookSlider(title: "Vignette", value: look.vignette, range: Look.amountRange, format: .percent)
                        LookSlider(title: "Grain", value: look.grain, range: Look.amountRange, format: .percent)
                    } header: {
                        SettingsHeader("Texture", "Fade lifts the blacks with a soft glow, for smoke and haze.")
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    dismiss()
                    library.remove(id)
                }
                Spacer()
                Button(library.active == id ? "Turn Off" : "Turn On") { effects.triggers.trigger(.look(id)) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }
}

/// One of a look's settings: a slider, and its value.
private struct LookSlider: View {
    enum Format {
        /// 1 is 100%.
        case percent
        /// 0 is none; above it reads +.
        case signedPercent
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: Format

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Rounded rather than stepped: a stepped slider draws a tick
                // per step.
                Slider(value: Binding(get: { value }, set: { value = ($0 * 100).rounded() / 100 }), in: range)
                    .controlSize(.small)
                    .frame(width: 200)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private var text: String {
        let percent = Int((value * 100).rounded())
        return switch format {
        case .percent: "\(percent)%"
        case .signedPercent: percent > 0 ? "+\(percent)%" : "\(percent)%"
        }
    }
}
