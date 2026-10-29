import AppKit
import SwiftUI

/// Draws an overlay's look into an image, once per frame size, for the
/// compositor and the editor's preview alike.
@MainActor
enum OverlayRenderer {
    /// One variant (line or image) of `overlay`, for a frame of `frame`
    /// pixels. Nil if there's nothing to draw.
    static func render(_ overlay: Overlay, variant: Int, frame: CGSize) -> CGImage? {
        switch overlay.kind {
        case .text:
            guard overlay.lines.indices.contains(variant) else { return nil }
            let line = overlay.lines[variant]
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // Blank: the icon alone, if there is one.
            guard !text.isEmpty || line.icon != nil else { return nil }
            let renderer = ImageRenderer(content: TextOverlayView(
                text: text, icon: line.icon, style: overlay.style, size: overlay.size, frameHeight: frame.height
            ))
            // Long text wraps to fit the spot.
            renderer.proposedSize = ProposedViewSize(width: Overlay.Spot.maxWidth(in: frame), height: nil)
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage
        case .graphic:
            guard overlay.images.indices.contains(variant), let image = graphic(overlay.images[variant]) else { return nil }
            return draw(image, for: overlay, in: frame)
        }
    }

    /// Vector graphics (PDF, SVG) draw sharp at any size.
    private static func draw(_ image: NSImage, for overlay: Overlay, in frame: CGSize) -> CGImage? {
        let (canvas, drawn) = layout(image.size, spot: overlay.spot, size: overlay.size, fit: overlay.fit, in: frame)
        guard canvas.width >= 1, canvas.height >= 1,
              let context = CGContext(
                  data: nil,
                  width: Int(canvas.width),
                  height: Int(canvas.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// A graphic of `size` placed for a frame: the image it's drawn into
    /// (`canvas`), and where in that it goes (`drawn`). Positioned: its
    /// size's share of the frame's height, no wider than the spot allows.
    /// Full frame: fit (all of it shows) or fill (covers the frame, edges
    /// cropped). Videos are placed the same way, frame by frame.
    nonisolated static func layout(_ size: CGSize, spot: Overlay.Spot, size scale: Overlay.Size, fit: Overlay.Fit, in frame: CGSize) -> (canvas: CGSize, drawn: CGRect) {
        let aspect = size.width / size.height
        var canvas: CGSize
        var drawn: CGRect
        if spot == .fullFrame {
            let fitted = fit == .fit
                ? min(frame.width / size.width, frame.height / size.height)
                : max(frame.width / size.width, frame.height / size.height)
            let sized = CGSize(width: size.width * fitted, height: size.height * fitted)
            canvas = fit == .fit ? sized : frame
            drawn = CGRect(x: (canvas.width - sized.width) / 2, y: (canvas.height - sized.height) / 2, width: sized.width, height: sized.height)
        } else {
            var height = frame.height * scale.graphicScale
            var width = height * aspect
            let widest = Overlay.Spot.maxWidth(in: frame)
            if width > widest {
                width = widest
                height = width / aspect
            }
            canvas = CGSize(width: width, height: height)
            drawn = CGRect(origin: .zero, size: canvas)
        }
        return (CGSize(width: canvas.width.rounded(), height: canvas.height.rounded()), drawn)
    }

    /// Graphics are read once and kept: previews redraw often.
    private static var graphics: [String: NSImage] = [:]

    /// A graphic's image; a movie's first frame, once it's been read.
    static func graphic(_ name: String) -> NSImage? {
        if let image = graphics[name] { return image }
        if OverlayVideo.isMovie(name) { return VideoPosters.shared.poster(name)?.image }
        guard let image = NSImage(contentsOf: EffectLibrary.graphicsFolder.appending(path: name)),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        graphics[name] = image
        return image
    }
}

/// An overlay's icon: its SF Symbol (or one of Vaux's own), or its emoji
/// (in color).
struct OverlayIcon: View {
    let icon: String

    /// Symbols drawn for Vaux, in its assets, where SF Symbols has none.
    static let ownSymbols: Set = ["poop"]

    var body: some View {
        if Self.isEmoji(icon) {
            Text(icon)
        } else if Self.ownSymbols.contains(icon) {
            Image(icon)
        } else {
            Image(systemName: icon)
        }
    }

    /// SF Symbol names are plain ASCII; anything else is an emoji.
    static func isEmoji(_ icon: String) -> Bool {
        !icon.allSatisfy(\.isASCII)
    }
}

/// Text over the video in one of the fixed styles, sized to the frame it's
/// drawn into (`frameHeight`, in pixels).
struct TextOverlayView: View {
    let text: String
    let icon: String?
    let style: Overlay.Style
    let size: Overlay.Size
    let frameHeight: CGFloat

    var body: some View {
        let font = frameHeight * size.textScale
        // An icon on its own is drawn bigger, in a rounder pill.
        let iconOnly = text.isEmpty
        let content = HStack(spacing: font * 0.45) {
            if let icon {
                let emoji = OverlayIcon.isEmoji(icon)
                // An emoji's picture sits smaller in its size than a
                // symbol's: a size up matches them, without making a line
                // with text any taller.
                OverlayIcon(icon: icon)
                    .font(.system(size: (iconOnly ? font * 1.3 : font) * (emoji ? 1.4 : 1), weight: .semibold))
                    .padding(.vertical, emoji && !iconOnly ? -font * 0.25 : 0)
            }
            if !iconOnly {
                Text(text)
                    .font(.system(size: font, weight: .semibold, design: style == .pill ? .rounded : .default))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.white)

        switch style {
        case .pill:
            content
                .padding(.horizontal, font * (iconOnly ? 0.55 : 0.9))
                .padding(.vertical, font * (iconOnly ? 0.45 : 0.5))
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: max(1, font * 0.05)))
        case .bar:
            content
                .padding(.leading, font * 1.1)
                .padding(.trailing, font * 0.9)
                .padding(.vertical, font * 0.55)
                .background(RoundedRectangle(cornerRadius: font * 0.18).fill(.black.opacity(0.65)))
                .overlay(alignment: .leading) {
                    // The lower-third stripe.
                    RoundedRectangle(cornerRadius: font * 0.08)
                        .fill(.white.opacity(0.9))
                        .frame(width: font * 0.16)
                        .padding(.vertical, font * 0.4)
                        .padding(.leading, font * 0.4)
                }
        case .plain:
            content
                .shadow(color: .black.opacity(0.7), radius: font * 0.18, y: font * 0.05)
                // Room for the shadow inside the image.
                .padding(font * 0.4)
        }
    }
}
