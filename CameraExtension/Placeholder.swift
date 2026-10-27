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
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Centered, so it stays inside the 4:3 that some apps crop to; sized
        // to the frame.
        let scale = height / 720
        drawCentered(CameraSpec.name, size: 64 * scale, gray: 0.9, y: height / 2 + 8 * scale, width: width, in: context)
        drawCentered("Waiting for Vaux to send a camera", size: 30 * scale, gray: 0.6, y: height / 2 - 52 * scale, width: width, in: context)
    }

    private static func drawCentered(_ text: String, size: CGFloat, gray: CGFloat, y: CGFloat, width: CGFloat, in context: CGContext) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateUIFontForLanguage(.system, size, nil)!,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        )
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (width - lineWidth) / 2, y: y)
        CTLineDraw(line, context)
    }
}
