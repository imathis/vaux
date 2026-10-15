import AppKit

/// Full-width volume slider flanked by icons (mic by default), mirroring the
/// system Sound slider, with its percentage. Settings' level controls (unmute
/// and speaker levels), via `VolumeSlider`.
final class InputVolumeView: NSView {
    struct Icons {
        let low: String
        let high: String
        static let mic = Icons(low: "mic", high: "mic.fill")
        static let speaker = Icons(low: "speaker", high: "speaker.wave.3.fill")
    }

    var onChange: ((Float) -> Void)?
    private let slider = NSSlider()
    private let low: NSImageView
    private let high: NSImageView
    private let percent = InputVolumeView.percentLabel()

    init(value: Float, icons: Icons, range: ClosedRange<Float>) {
        low = Self.icon(icons.low, pointSize: 12)
        high = Self.icon(icons.high, pointSize: 15)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))

        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.floatValue = value
        slider.isContinuous = true
        slider.trackFillColor = .controlAccentColor // the OS active (blue) fill
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        // A vibrant background desaturates the accent fill to grey. Pin the
        // slider to a concrete (non-vibrant) appearance so the blue shows,
        // matching the current light/dark setting.
        if let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            slider.appearance = NSAppearance(named: match)
        }

        addSubview(low)
        addSubview(slider)
        addSubview(high)
        addSubview(percent)

        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -8),

            high.centerYAnchor.constraint(equalTo: centerYAnchor),
            high.trailingAnchor.constraint(equalTo: percent.leadingAnchor, constant: -8),

            percent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percent.centerYAnchor.constraint(equalTo: centerYAnchor),
            percent.widthAnchor.constraint(equalToConstant: 36),
        ])
        updatePercent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setValue(_ value: Float) {
        if abs(slider.floatValue - value) > 0.0001 { slider.floatValue = value }
        updatePercent()
    }

    private func updatePercent() {
        percent.stringValue = slider.floatValue.percentText
    }

    private static func percentLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// Stretch to the full width of the SwiftUI representable.
    override func layout() {
        if let superview, superview.bounds.width > 0, frame.width != superview.bounds.width {
            frame.size.width = superview.bounds.width
        }
        super.layout()
    }

    private static func icon(_ name: String, pointSize: CGFloat) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    // The knob tracks the mouse on its own; throttle HAL writes to ~50ms while
    // dragging (flush on mouse-up) so we never block the main thread per move.
    private var pendingValue: Float?
    private var flushScheduled = false

    @objc private func sliderChanged() {
        updatePercent()
        pendingValue = slider.floatValue
        if NSApp.currentEvent?.type == .leftMouseUp {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard let value = pendingValue else { return }
        pendingValue = nil
        onChange?(value)
    }
}

import SwiftUI

extension BinaryFloatingPoint {
    /// A 0...1 level as a whole percentage: "75%".
    var percentText: String { "\(Int((Double(self) * 100).rounded()))%" }
}

/// SwiftUI wrapper for Settings (icons, blue fill, full width). Levels run
/// from 5%: a level of 0 would be silence that looks live.
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var icons: InputVolumeView.Icons = .mic

    func makeNSView(context: Context) -> InputVolumeView {
        let view = InputVolumeView(value: Float(value), icons: icons, range: 0.05...1)
        let coordinator = context.coordinator
        view.onChange = { coordinator.value.wrappedValue = Double($0) }
        return view
    }

    func updateNSView(_ nsView: InputVolumeView, context: Context) {
        context.coordinator.value = $value
        nsView.setValue(Float(value))
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
    }
}
