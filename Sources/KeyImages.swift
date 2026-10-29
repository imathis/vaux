import AppKit

/// An effect's Stream Deck key, drawn: its icon in its color on black, and,
/// for while it's on, white on its color (an emoji stays itself). PNG data
/// URLs, 144 pixels square (a key's 72 points at 2×), the icon above where
/// the key's title goes.
enum KeyImages {
    struct Pair: Encodable, Equatable {
        let off: String
        let on: String
    }

    static func pair(icon: String, tint: Effect.Tint) -> Pair {
        Pair(off: draw(icon, color: tint.nsColor, on: .black), on: draw(icon, color: .white, on: tint.nsColor))
    }

    private static let side = 144

    private static func draw(_ icon: String, color: NSColor, on background: NSColor) -> String {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return "" }
        // A point a pixel.
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        background.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // Its middle 50 down from the top, clear of a two-line title at the
        // bottom.
        let box = NSRect(x: 40, y: side - 50 - 32, width: 64, height: 64)
        if OverlayIcon.isEmoji(icon) {
            let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 48)])
            let size = text.size()
            text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
        } else if let image = symbol(icon, color: color) {
            let scale = min(box.width / image.size.width, box.height / image.size.height, 1)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// An SF Symbol, or one of Vaux's own, in `color`.
    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let image = OverlayIcon.ownSymbols.contains(name)
            ? NSImage(named: name)
            : NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image?.withSymbolConfiguration(configuration)
    }
}
