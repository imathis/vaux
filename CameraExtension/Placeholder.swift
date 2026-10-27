import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import VideoToolbox

/// What Vaux Camera shows while Vaux isn't sending a camera: drawn once
/// per size, then converted to Vaux Camera's YUV.
enum Placeholder {
    static func make(_ size: CMVideoDimensions) -> CVPixelBuffer? {
        guard let drawn = buffer(size, kCVPixelFormatType_32BGRA), let yuv = buffer(size, CameraSpec.pixelFormat) else { return nil }
        draw(into: drawn)
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard let transfer else { return nil }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard VTPixelTransferSessionTransferImage(transfer, from: drawn, to: yuv) == noErr else { return nil }
        return yuv
    }

    private static func buffer(_ size: CMVideoDimensions, _ pixelFormat: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), pixelFormat, attributes as CFDictionary, &buffer)
        return buffer
    }

    private static func draw(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        TestCard.draw(in: context, size: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }
}

/// An old broadcast test card, Vaux's own: a ringed circle over a grid,
/// resolution wedges and a bullseye in the middle, a wheel in each corner,
/// a gray scale, and PLEASE STAND BY, on a vignetted, scanlined, grainy
/// field. Laid out on the frame's height; what matters sits in the middle
/// 4:3, which apps keep when they crop.
enum TestCard {
    private static let ink = CGColor(gray: 0.08, alpha: 1)
    private static let paper = CGColor(gray: 0.95, alpha: 1)

    static func draw(in context: CGContext, size: CGSize) {
        let h = size.height
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let unit = h / 720

        field(in: context, size: size)
        grid(in: context, size: size, center: center, unit: unit)
        // The big ring, lighter inside, over the grid.
        let ring = 0.44 * h
        fill(circle: center, radius: ring, gray: 0.66, in: context)
        stroke(circle: center, radius: ring, width: 9 * unit, in: context)
        for angle in stride(from: 45.0, to: 360, by: 90) {
            line(from: polar(center, 0.32 * h, angle), to: polar(center, 0.405 * h, angle), width: 6 * unit, in: context)
        }
        for (x, y) in [(-1.0, 1.0), (1, 1), (-1, -1), (1, -1)] {
            wheel(at: CGPoint(x: center.x + x * 0.705 * h, y: center.y + y * 0.315 * h), radius: 0.15 * h, unit: unit, in: context)
        }
        grayScale(center: CGPoint(x: center.x, y: center.y - 0.275 * h), width: 0.46 * h, height: 0.045 * h, unit: unit, in: context)
        staircase(top: center.y - 0.325 * h, centerX: center.x, unit: unit, h: h, in: context)
        target(at: center, radius: 0.2 * h, unit: unit, in: context)
        labels(center: center, h: h, unit: unit, in: context)
        texture(in: context, size: size, unit: unit)
    }

    // MARK: Parts

    /// Mid gray, darker toward the edges like an old tube.
    private static func field(in context: CGContext, size: CGSize) {
        let colors = [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.34, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: hypot(size.width, size.height) / 2, options: [.drawsAfterEndLocation])
    }

    private static func grid(in context: CGContext, size: CGSize, center: CGPoint, unit: CGFloat) {
        context.setStrokeColor(ink.copy(alpha: 0.5)!)
        context.setLineWidth(1.5 * unit)
        let step = size.height / 6
        var x = center.x.truncatingRemainder(dividingBy: step)
        while x < size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y = step
        while y < size.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.strokePath()
    }

    /// The middle: wedges of lines closing in from each side, two fans of
    /// fine lines across the diagonals, and a bullseye.
    private static func target(at center: CGPoint, radius: CGFloat, unit: CGFloat, in context: CGContext) {
        fill(circle: center, radius: radius, gray: 0.76, in: context)
        context.saveGState()
        clip(circle: center, radius: radius, in: context)
        // The fans, shaded behind the lines.
        for start in [118.0, 298.0] {
            for step in 0..<16 {
                let angle = start + Double(step) * 2
                line(from: polar(center, 0.05 * radius / 0.2 * 0.2 + radius * 0.25, angle), to: polar(center, radius, angle), width: 1.2 * unit, in: context)
            }
        }
        wedges(at: center, outer: radius, inner: radius * 0.22, spread: radius * 0.42, count: 13, width: 1.4 * unit, in: context)
        context.restoreGState()
        stroke(circle: center, radius: radius, width: 4 * unit, in: context)
        bullseye(at: center, radius: radius * 0.22, unit: unit, in: context)
    }

    /// A corner wheel: ringed, a wedge of lines from each side, and between
    /// them, an arc and its number.
    private static func wheel(at center: CGPoint, radius: CGFloat, unit: CGFloat, in context: CGContext) {
        fill(circle: center, radius: radius, gray: 0.7, in: context)
        context.saveGState()
        clip(circle: center, radius: radius, in: context)
        wedges(at: center, outer: radius, inner: radius * 0.24, spread: radius * 0.3, count: 9, width: 1.3 * unit, in: context)
        context.restoreGState()
        for (angle, number) in [(45.0, "25"), (135.0, "20"), (225.0, "30"), (315.0, "35")] {
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: radius * 0.78, startAngle: radians(angle - 14), endAngle: radians(angle + 14), clockwise: false)
            context.addPath(arc)
            context.setStrokeColor(ink)
            context.setLineWidth(2 * unit)
            context.strokePath()
            let spot = polar(center, radius * 0.56, angle)
            text(number, font: "DINCondensed-Bold", size: 14 * unit, color: ink, kern: 0, at: CGPoint(x: spot.x, y: spot.y - 5 * unit), in: context)
        }
        stroke(circle: center, radius: radius, width: 3.5 * unit, in: context)
        bullseye(at: center, radius: radius * 0.22, unit: unit, in: context)
    }

    /// Lines narrowing from each side toward the middle.
    private static func wedges(at center: CGPoint, outer: CGFloat, inner: CGFloat, spread: CGFloat, count: Int, width: CGFloat, in context: CGContext) {
        context.setStrokeColor(ink)
        context.setLineWidth(width)
        for side in 0..<4 {
            for index in 0..<count {
                let offset = (CGFloat(index) / CGFloat(count - 1) - 0.5) * 2
                let far = CGPoint(x: offset * spread, y: outer * 0.97)
                let near = CGPoint(x: offset * spread * 0.18, y: inner * 1.15)
                let turn = CGAffineTransform(rotationAngle: CGFloat(side) * .pi / 2)
                let a = far.applying(turn), b = near.applying(turn)
                context.move(to: CGPoint(x: center.x + a.x, y: center.y + a.y))
                context.addLine(to: CGPoint(x: center.x + b.x, y: center.y + b.y))
            }
        }
        context.strokePath()
    }

    private static func bullseye(at center: CGPoint, radius: CGFloat, unit: CGFloat, in context: CGContext) {
        fill(circle: center, radius: radius, gray: 0.92, in: context)
        for ring in 0..<4 {
            stroke(circle: center, radius: radius * (1 - CGFloat(ring) * 0.24), width: 2.2 * unit, in: context)
        }
        fill(circle: center, radius: radius * 0.14, gray: 0.08, in: context)
    }

    /// Ten steps, black to white.
    private static func grayScale(center: CGPoint, width: CGFloat, height: CGFloat, unit: CGFloat, in context: CGContext) {
        let steps = 10
        let step = width / CGFloat(steps)
        for index in 0..<steps {
            context.setFillColor(CGColor(gray: 0.06 + 0.9 * CGFloat(index) / CGFloat(steps - 1), alpha: 1))
            context.fill(CGRect(x: center.x - width / 2 + CGFloat(index) * step, y: center.y - height / 2, width: step, height: height))
        }
        context.setStrokeColor(ink)
        context.setLineWidth(2.5 * unit)
        context.stroke(CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
    }

    /// Bars getting shorter, down to the bottom of the ring.
    private static func staircase(top: CGFloat, centerX: CGFloat, unit: CGFloat, h: CGFloat, in context: CGContext) {
        context.setFillColor(ink)
        for index in 0..<4 {
            let width = h * (0.3 - CGFloat(index) * 0.07)
            let y = top - CGFloat(index) * 13 * unit
            context.fill(CGRect(x: centerX - width / 2, y: y, width: width, height: 5 * unit))
        }
    }

    private static func labels(center: CGPoint, h: CGFloat, unit: CGFloat, in context: CGContext) {
        // A slate band behind the message, so the middle's lines don't run
        // through it.
        let band = CGRect(x: center.x - 0.43 * h, y: center.y - 44 * unit, width: 0.86 * h, height: 84 * unit)
        context.setFillColor(CGColor(gray: 0, alpha: 0.6))
        context.addPath(CGPath(roundedRect: band, cornerWidth: 6 * unit, cornerHeight: 6 * unit, transform: nil))
        context.fillPath()
        // Shadowed, as if printed over the card.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 3 * unit, height: -3 * unit), blur: 2 * unit, color: CGColor(gray: 0, alpha: 0.85))
        text("PLEASE STAND BY", font: "DINCondensed-Bold", size: 64 * unit, color: paper, kern: 12 * unit, at: CGPoint(x: center.x, y: center.y - 22 * unit), in: context)
        text("VAUX", font: "DINCondensed-Bold", size: 64 * unit, color: paper, kern: 22 * unit, at: CGPoint(x: center.x, y: center.y + 0.255 * h), in: context)
        context.restoreGState()
        let caption = "\(CameraSpec.name.uppercased())  ·  WAITING FOR A CAMERA"
        text(caption, font: "DINCondensed-Bold", size: 17 * unit, color: ink, kern: 3 * unit, at: CGPoint(x: center.x, y: 12 * unit), in: context)
    }

    /// Scanlines and a little grain, so it reads as a picture on a tube.
    private static func texture(in context: CGContext, size: CGSize, unit: CGFloat) {
        context.setFillColor(CGColor(gray: 0, alpha: 0.07))
        var y: CGFloat = 0
        while y < size.height {
            context.fill(CGRect(x: 0, y: y, width: size.width, height: max(1, unit)))
            y += 3 * unit
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<Int(size.width * size.height / 40) {
            let gray = CGFloat.random(in: 0...1, using: &generator)
            context.setFillColor(CGColor(gray: gray, alpha: 0.12))
            context.fill(CGRect(x: .random(in: 0..<size.width, using: &generator), y: .random(in: 0..<size.height, using: &generator), width: unit * 1.5, height: unit * 1.5))
        }
    }

    // MARK: Drawing

    private static func fill(circle center: CGPoint, radius: CGFloat, gray: CGFloat, in context: CGContext) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func stroke(circle center: CGPoint, radius: CGFloat, width: CGFloat, in context: CGContext) {
        context.setStrokeColor(ink)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func clip(circle center: CGPoint, radius: CGFloat, in context: CGContext) {
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
    }

    private static func line(from a: CGPoint, to b: CGPoint, width: CGFloat, in context: CGContext) {
        context.setStrokeColor(ink)
        context.setLineWidth(width)
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
    }

    /// Centered on `point` horizontally, its baseline at `point.y`.
    private static func text(_ string: String, font name: String, size: CGFloat, color: CGColor, kern: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTKernAttributeName: kern,
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
        // The last letter's kern trails it: leave it out of the centering.
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) - kern
        context.textPosition = CGPoint(x: point.x - width / 2, y: point.y)
        CTLineDraw(line, context)
    }

    private static func polar(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(radians(degrees)), y: center.y + radius * sin(radians(degrees)))
    }

    private static func radians(_ degrees: Double) -> CGFloat { CGFloat(degrees * .pi / 180) }
}
