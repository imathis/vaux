import AppKit

/// The menu bar glyph: five voice bars. Muted flattens them all to dots
/// (silence); solo keeps three bars live between two dimmed dots. All neutral,
/// following the menu bar: the shape carries the state.
/// Drawn rather than an SF Symbol so the three states share one shape, and so
/// StatusIconAnimator can draw the frames in between.
enum StatusIcon {
    enum State: Equatable {
        case live
        case muted
        /// `problem`: something couldn't be muted, so the voice turns orange.
        case solo(problem: Bool)

        /// Only a solo problem carries color; everything else follows the menu bar.
        var isTemplate: Bool {
            if case .solo(problem: true) = self { false } else { true }
        }

        /// The bars at rest in this state.
        var bars: [Bar] {
            switch self {
            case .live:
                liveHeights.map { Bar(height: $0, alpha: 1) }
            case .muted:
                Array(repeating: Bar(height: dot, alpha: 1), count: 5)
            case .solo:
                [Bar(height: dot, alpha: 0.45), Bar(height: 8, alpha: 1), Bar(height: 16, alpha: 1),
                 Bar(height: 9.4, alpha: 1), Bar(height: dot, alpha: 0.45)]
            }
        }
    }

    /// One bar on the 18pt grid: its height and opacity.
    struct Bar: Equatable {
        var height: CGFloat
        var alpha: CGFloat
    }

    /// `bars`: the state's resting bars, or a frame mid-transition.
    static func image(_ state: State, bars: [Bar], description: String) -> NSImage {
        let problem = !state.isTemplate
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(bars, problem: problem)
            return true
        }
        // Template images follow the menu bar like any system icon; a colored
        // one draws its dots in the label color, resolved at draw time.
        image.isTemplate = state.isTemplate
        image.accessibilityDescription = description
        return image
    }

    // An 18pt grid: five 2pt bars, centered vertically.
    private static let xs: [CGFloat] = [1, 4.5, 8, 11.5, 15]
    private static let liveHeights: [CGFloat] = [8, 13.9, 10.7, 16, 8.5]
    private static let dot: CGFloat = 2.4

    private static func draw(_ bars: [Bar], problem: Bool) {
        for (i, bar) in bars.enumerated() {
            let base: NSColor
            if problem {
                base = (1...3).contains(i) ? .systemOrange : .labelColor
            } else {
                base = .black
            }
            fill(i, height: bar.height, color: base.withAlphaComponent(bar.alpha))
        }
    }

    private static func fill(_ index: Int, height: CGFloat, color: NSColor) {
        // A bounce can overshoot; keep it inside the 18pt image.
        let height = min(max(height, 0.5), 18)
        color.setFill()
        let rect = NSRect(x: xs[index], y: 9 - height / 2, width: 2, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}
