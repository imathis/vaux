import SwiftUI

/// A look in an effect: color, tone, the three-way grade, and texture (blur
/// included). While
/// its effect is on, the camera follows each slider as it moves.
struct LookSections: View {
    @Binding var look: Look
    /// Takes the look out of its effect.
    let remove: () -> Void

    /// The range the grade's sliders are showing.
    @State private var range = GradeRange.shadows

    var body: some View {
        let defaults = look.defaults
        Section {
            LookSlider(title: "Temperature", value: $look.warmth, defaultValue: defaults.warmth, range: Look.warmthRange, format: .signedPercent)
            LookSlider(title: "Tint", value: $look.tint, defaultValue: defaults.tint, range: Look.signedRange, format: .signedPercent)
            LookSlider(title: "Saturation", value: $look.saturation, defaultValue: defaults.saturation, range: Look.saturationRange, format: .percent)
        } header: {
            // A preset goes back to how it came; one made from scratch, to
            // plain.
            PartHeader(
                "Look",
                "Color and texture over the whole picture.",
                reset: look.isDefault ? nil : { look = defaults },
                remove: remove
            )
        }
        Section {
            LookSlider(title: "Brightness", value: $look.brightness, defaultValue: defaults.brightness, range: Look.brightnessRange, format: .signedPercent)
            LookSlider(title: "Contrast", value: $look.contrast, defaultValue: defaults.contrast, range: Look.contrastRange, format: .percent)
            LookSlider(title: "Highlights", value: $look.highlights, defaultValue: defaults.highlights, range: Look.signedRange, format: .signedPercent)
            LookSlider(title: "Shadows", value: $look.shadows, defaultValue: defaults.shadows, range: Look.signedRange, format: .signedPercent)
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
            let grade = $look[dynamicMember: range.keyPath]
            let gradeDefaults = defaults[keyPath: range.keyPath]
            LookSlider(
                title: "Hue", value: grade.hue, defaultValue: gradeDefaults.hue, range: Look.hueRange, format: .degrees,
                swatch: Color(hue: grade.wrappedValue.hue / 360, saturation: max(grade.wrappedValue.saturation, 0.35), brightness: 1)
            )
            LookSlider(title: "Saturation", value: grade.saturation, defaultValue: gradeDefaults.saturation, range: Look.amountRange, format: .percent)
            LookSlider(title: "Luminance", value: grade.luminance, defaultValue: gradeDefaults.luminance, range: Look.signedRange, format: .signedPercent)
        } header: {
            SettingsHeader("Color Grading", "Tint shadows, midtones and highlights each toward a hue, lighter or darker.")
        }
        Section {
            LookSlider(title: "Blur", value: $look.blur, defaultValue: defaults.blur, range: Look.amountRange, format: .percent)
            LookSlider(title: "Fade", value: $look.fade, defaultValue: defaults.fade, range: Look.amountRange, format: .percent)
            LookSlider(title: "Vignette", value: $look.vignette, defaultValue: defaults.vignette, range: Look.amountRange, format: .percent)
            LookSlider(title: "Grain", value: $look.grain, defaultValue: defaults.grain, range: Look.amountRange, format: .percent)
        } header: {
            SettingsHeader("Texture", "Blur runs from soft focus to frosted glass. Fade lifts the blacks, like haze.")
        }
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
