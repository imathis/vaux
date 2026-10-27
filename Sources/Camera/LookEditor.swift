import SwiftUI

/// A look in the list, one line: its name, on or off (one at a time), and
/// edit.
struct LookRow: View {
    let look: Look
    let isOn: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.filters")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(look.name)
                .lineLimit(1)
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

/// Edits a look. While it's on, the camera follows each slider as it moves:
/// the preview is your call app's own.
struct LookEditor: View {
    let effects: Effects
    let id: UUID
    /// Undoably, by the page that opened it.
    let delete: () -> Void
    /// Snapshots draw it whole.
    var height: CGFloat = 640

    @Environment(\.dismiss) private var dismiss
    /// The range the grade's sliders are showing.
    @State private var range = GradeRange.shadows

    var body: some View {
        @Bindable var library = effects.looks
        VStack(spacing: 0) {
            if let index = library.looks.firstIndex(where: { $0.id == id }) {
                let look = $library.looks[index]
                let defaults = look.wrappedValue.defaults
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
                        LookSlider(title: "Temperature", value: look.warmth, defaultValue: defaults.warmth, range: Look.warmthRange, format: .signedPercent)
                        LookSlider(title: "Tint", value: look.tint, defaultValue: defaults.tint, range: Look.signedRange, format: .signedPercent)
                        LookSlider(title: "Saturation", value: look.saturation, defaultValue: defaults.saturation, range: Look.saturationRange, format: .percent)
                    } header: {
                        SettingsHeader("Color", "Temperature toward amber or blue, tint toward magenta or green.")
                    }
                    Section {
                        LookSlider(title: "Brightness", value: look.brightness, defaultValue: defaults.brightness, range: Look.brightnessRange, format: .signedPercent)
                        LookSlider(title: "Contrast", value: look.contrast, defaultValue: defaults.contrast, range: Look.contrastRange, format: .percent)
                        LookSlider(title: "Highlights", value: look.highlights, defaultValue: defaults.highlights, range: Look.signedRange, format: .signedPercent)
                        LookSlider(title: "Shadows", value: look.shadows, defaultValue: defaults.shadows, range: Look.signedRange, format: .signedPercent)
                    } header: {
                        SettingsHeader("Tone")
                    }
                    Section {
                        Picker("Grade", selection: $range) {
                            ForEach(GradeRange.allCases, id: \.self) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        let grade = look[dynamicMember: range.keyPath]
                        let gradeDefaults = defaults[keyPath: range.keyPath]
                        LookSlider(
                            title: "Hue", value: grade.hue, defaultValue: gradeDefaults.hue, range: Look.hueRange, format: .degrees,
                            swatch: Color(hue: grade.wrappedValue.hue / 360, saturation: max(grade.wrappedValue.saturation, 0.35), brightness: 1)
                        )
                        LookSlider(title: "Saturation", value: grade.saturation, defaultValue: gradeDefaults.saturation, range: Look.amountRange, format: .percent)
                        LookSlider(title: "Luminance", value: grade.luminance, defaultValue: gradeDefaults.luminance, range: Look.signedRange, format: .signedPercent)
                    } header: {
                        SettingsHeader("Color Grading", "The shadows, midtones and highlights apart: tint each toward a hue, and brighten or darken it.")
                    }
                    Section {
                        LookSlider(title: "Fade", value: look.fade, defaultValue: defaults.fade, range: Look.amountRange, format: .percent)
                        LookSlider(title: "Vignette", value: look.vignette, defaultValue: defaults.vignette, range: Look.amountRange, format: .percent)
                        LookSlider(title: "Grain", value: look.grain, defaultValue: defaults.grain, range: Look.amountRange, format: .percent)
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
                    delete()
                }
                Spacer()
                if let look = library.look(id) {
                    // A preset goes back to how it came; one made from
                    // scratch, to plain.
                    Button(look.preset == nil ? "Reset" : "Reset to Default") {
                        if let index = library.looks.firstIndex(where: { $0.id == id }) {
                            library.looks[index] = look.defaults
                        }
                    }
                    .disabled(look.isDefault)
                }
                Button(library.active == id ? "Turn Off" : "Turn On") { effects.triggers.trigger(.look(id)) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: height)
    }
}

/// The parts of the picture the grade treats apart.
private enum GradeRange: CaseIterable {
    case shadows, midtones, highlights

    var title: String {
        switch self {
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        }
    }

    var keyPath: WritableKeyPath<Look, Look.Grade> {
        switch self {
        case .shadows: \.shadowGrade
        case .midtones: \.midtoneGrade
        case .highlights: \.highlightGrade
        }
    }
}

/// One of a look's settings: a slider, and its value.
private struct LookSlider: View {
    enum Format {
        /// 1 is 100%.
        case percent
        /// 0 is none; above it reads +.
        case signedPercent
        /// Around the color wheel.
        case degrees
    }

    let title: String
    @Binding var value: Double
    /// Its preset's (or plain): a reset arrow shows once it's moved away.
    let defaultValue: Double
    let range: ClosedRange<Double>
    let format: Format
    /// The color a hue makes, beside its value.
    var swatch: Color?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // Rounded rather than stepped: a stepped slider draws a tick
                // per step.
                Slider(value: Binding(get: { value }, set: { value = format == .degrees ? $0.rounded() : ($0 * 100).rounded() / 100 }), in: range)
                    .controlSize(.small)
                    .frame(width: 182)
                HStack(spacing: 4) {
                    if let swatch {
                        Circle().fill(swatch).frame(width: 9, height: 9)
                    }
                    Text(text)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, alignment: .trailing)
                Button { value = defaultValue } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Back to \(Self.text(defaultValue, format))")
                .opacity(value == defaultValue ? 0 : 1)
                .disabled(value == defaultValue)
            }
        }
    }

    private var text: String { Self.text(value, format) }

    private static func text(_ value: Double, _ format: Format) -> String {
        let percent = Int((value * 100).rounded())
        return switch format {
        case .percent: "\(percent)%"
        case .signedPercent: percent > 0 ? "+\(percent)%" : "\(percent)%"
        case .degrees: "\(Int(value.rounded()))°"
        }
    }
}
