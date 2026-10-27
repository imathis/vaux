import CoreGraphics
import Foundation

/// Something shown over Vaux Camera's video: text or a graphic, in a spot.
/// Several lines (or images) make a set: each showing picks one at random,
/// never the same twice running.
struct Overlay: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text, graphic
    }

    enum Style: String, Codable, CaseIterable, Sendable {
        /// Translucent capsule, the original dictation badge.
        case pill
        /// A broadcast lower-third plate.
        case bar
        /// Text with a soft shadow, nothing behind it.
        case plain
    }

    enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
    }

    /// Where it sits. Center-left and center-right are left out: that's
    /// where your face and shoulders are, and apps crop the sides.
    enum Spot: String, Codable, CaseIterable, Sendable {
        case topLeading, top, topTrailing, center, bottomLeading, bottom, bottomTrailing
        /// Graphics only: covering the frame, fit or fill.
        case fullFrame
    }

    enum Fit: String, Codable, CaseIterable, Sendable {
        /// The whole graphic shows.
        case fit
        /// The graphic covers the frame; its edges may be cropped.
        case fill
    }

    var id = UUID()
    var name: String
    var kind = Kind.text
    var lines: [String] = []
    /// Graphic files, in `OverlayLibrary.graphicsFolder`.
    var images: [String] = []
    /// An SF Symbol before the text, if any.
    var icon: String?
    var style = Style.pill
    var size = Size.medium
    var spot = Spot.top
    var fit = Fit.fit
    /// Hides itself after this many seconds; nil stays until turned off.
    var duration: Double?

    /// The lines or images a showing picks from.
    var variants: Int { kind == .text ? lines.count : images.count }

    /// A line shows its text, and its icon if it has one; a blank line with
    /// an icon shows just the icon (a coffee cup for a break). An image
    /// always shows.
    func shows(_ variant: Int) -> Bool {
        switch kind {
        case .text: lines.indices.contains(variant) && (icon != nil || !lines[variant].trimmingCharacters(in: .whitespaces).isEmpty)
        case .graphic: images.indices.contains(variant)
        }
    }

    /// Has something to show.
    var canShow: Bool { (0..<variants).contains(where: shows) }
}

extension Overlay.Spot {
    /// Where an overlay of `size` sits in a frame of `frame`: inside the 4:3
    /// middle apps keep when they crop tiles, with a margin. Core Image
    /// coordinates: origin at the bottom left.
    func origin(for size: CGSize, in frame: CGSize) -> CGPoint {
        if self == .fullFrame { return CGPoint(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2) }
        let safe = Self.safeArea(in: frame)
        let margin = frame.height * 0.05
        let left = safe.minX + margin
        let middle = safe.midX - size.width / 2
        let right = safe.maxX - margin - size.width
        let top = frame.height - margin - size.height
        let center = (frame.height - size.height) / 2
        let bottom = margin
        let (x, y): (CGFloat, CGFloat) = switch self {
        case .topLeading: (left, top)
        case .top: (middle, top)
        case .topTrailing: (right, top)
        case .center: (middle, center)
        case .bottomLeading: (left, bottom)
        case .bottom: (middle, bottom)
        case .bottomTrailing: (right, bottom)
        case .fullFrame: (0, 0)
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The widest a spot's overlay may be.
    static func maxWidth(in frame: CGSize) -> CGFloat {
        safeArea(in: frame).width - frame.height * 0.1
    }

    /// The 4:3 middle of a 16:9 frame.
    static func safeArea(in frame: CGSize) -> CGRect {
        let width = min(frame.width, frame.height * 4 / 3)
        return CGRect(x: (frame.width - width) / 2, y: 0, width: width, height: frame.height)
    }

    var label: String {
        switch self {
        case .topLeading: "Top left"
        case .top: "Top"
        case .topTrailing: "Top right"
        case .center: "Center"
        case .bottomLeading: "Bottom left"
        case .bottom: "Bottom"
        case .bottomTrailing: "Bottom right"
        case .fullFrame: "Full frame"
        }
    }
}

extension Overlay.Size {
    /// Text height as a share of the frame's height. Text comes in medium
    /// and large; small text read as an afterthought, so any left over shows
    /// as medium.
    var textScale: CGFloat {
        switch self {
        case .small, .medium: 0.04
        case .large: 0.06
        }
    }

    /// The sizes text offers.
    static let textSizes: [Self] = [.medium, .large]

    /// A positioned graphic's height as a share of the frame's height.
    var graphicScale: CGFloat {
        switch self {
        case .small: 0.15
        case .medium: 0.25
        case .large: 0.4
        }
    }
}

extension Overlay {
    /// The first overlay: the original dictation badge.
    static let dictating = Overlay(name: "Dictating", lines: ["Dictating"], icon: "waveform")

    /// Icons offered for text, kept few.
    static let icons: [(symbol: String?, label: String)] = [
        (nil, "None"),
        ("waveform", "Waveform"),
        ("mic.slash.fill", "Muted"),
        ("cup.and.saucer.fill", "Break"),
        ("clock.fill", "Clock"),
        ("hand.raised.fill", "Hand"),
        ("sparkles", "Sparkles"),
        ("bubble.left.fill", "Speech"),
    ]
}
