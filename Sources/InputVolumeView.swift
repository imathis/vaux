import AppKit

/// Full-width volume slider flanked by mic icons, mirroring the system Sound
/// slider. Reused in the menu (writes device volume) and in Settings (binds to
/// the unmute level) via `VolumeSlider`.
final class InputVolumeView: NSView {
    var onChange: ((Float) -> Void)?
    private let slider = NSSlider()

    init(supported: Bool, value: Float) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))

        let low = Self.icon("mic", pointSize: 12)
        let high = Self.icon("mic.fill", pointSize: 15)

        slider.minValue = 0
        slider.maxValue = 1
        slider.floatValue = value
        slider.isContinuous = true
        slider.trackFillColor = .controlAccentColor // the OS active (blue) fill
        slider.isEnabled = supported
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        // Menus render with a vibrant material that desaturates the accent fill
        // to grey. Pin the slider to a concrete (non-vibrant) appearance so the
        // blue shows, matching the current light/dark setting.
        if let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            slider.appearance = NSAppearance(named: match)
        }

        addSubview(low)
        addSubview(slider)
        addSubview(high)

        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -8),

            high.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            high.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setValue(_ value: Float) {
        if abs(slider.floatValue - value) > 0.0001 { slider.floatValue = value }
    }

    /// Stretch to the full width of the container (the menu, or the SwiftUI
    /// representable). NSMenu doesn't reliably size custom views to full width.
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

/// SwiftUI wrapper so Settings can reuse the exact menu slider (icons, blue
/// fill, full width).
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> InputVolumeView {
        let view = InputVolumeView(supported: true, value: Float(value))
        view.onChange = { context.coordinator.value.wrappedValue = Double($0) }
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
