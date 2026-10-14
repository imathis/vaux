import AppKit

/// The menu bar glyph: five voice bars. Muted flattens them all to dots
/// (silence); solo keeps three bars live between two dimmed dots. All neutral,
/// following the menu bar: the shape carries the state.
/// Drawn rather than an SF Symbol so the three states share one shape.
enum StatusIcon {
    enum State {
        case live
        case muted
        /// `problem`: something couldn't be muted, so the voice turns orange.
        case solo(problem: Bool)

        /// Only a solo problem carries color; everything else follows the menu bar.
        var isTemplate: Bool {
            if case .solo(problem: true) = self { false } else { true }
        }
    }

    static func image(_ state: State, description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(state)
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

    private static func draw(_ state: State) {
        switch state {
        case .live:
            for (i, height) in liveHeights.enumerated() { bar(i, height: height, color: .black) }
        case .muted:
            for i in xs.indices { bar(i, height: dot, color: .black) }
        case .solo(let problem):
            let quiet = (problem ? NSColor.labelColor : .black).withAlphaComponent(0.45)
            bar(0, height: dot, color: quiet)
            bar(4, height: dot, color: quiet)
            let voice: NSColor = problem ? .systemOrange : .black
            bar(1, height: 8, color: voice)
            bar(2, height: 16, color: voice)
            bar(3, height: 9.4, color: voice)
        }
    }

    private static func bar(_ index: Int, height: CGFloat, color: NSColor) {
        color.setFill()
        let rect = NSRect(x: xs[index], y: 9 - height / 2, width: 2, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }
}
