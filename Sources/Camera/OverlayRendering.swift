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
            let text = overlay.lines[variant].trimmingCharacters(in: .whitespaces)
            // Blank: the icon alone, if there is one.
            guard !text.isEmpty || overlay.icon != nil else { return nil }
            let renderer = ImageRenderer(content: TextOverlayView(
                text: text, icon: overlay.icon, style: overlay.style, size: overlay.size, frameHeight: frame.height
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

    /// Positioned: its size's share of the frame's height, no wider than the
    /// spot allows. Full frame: fit (all of it shows) or fill (covers the
    /// frame, edges cropped). Vector graphics (PDF, SVG) draw sharp at any
    /// size.
    private static func draw(_ image: NSImage, for overlay: Overlay, in frame: CGSize) -> CGImage? {
        let aspect = image.size.width / image.size.height
        var canvas: CGSize
        var drawn: CGRect
        if overlay.spot == .fullFrame {
            let scale = overlay.fit == .fit
                ? min(frame.width / image.size.width, frame.height / image.size.height)
                : max(frame.width / image.size.width, frame.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            canvas = overlay.fit == .fit ? size : frame
            drawn = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        } else {
            var height = frame.height * overlay.size.graphicScale
            var width = height * aspect
            let widest = Overlay.Spot.maxWidth(in: frame)
            if width > widest {
                width = widest
                height = width / aspect
            }
            canvas = CGSize(width: width, height: height)
            drawn = CGRect(origin: .zero, size: canvas)
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
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

    /// Graphics are read once and kept: previews redraw often.
    private static var graphics: [String: NSImage] = [:]

    static func graphic(_ name: String) -> NSImage? {
        if let image = graphics[name] { return image }
        guard let image = NSImage(contentsOf: OverlayLibrary.graphicsFolder.appending(path: name)),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        graphics[name] = image
        return image
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
                Image(systemName: icon)
                    .font(.system(size: iconOnly ? font * 1.3 : font, weight: .semibold))
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
