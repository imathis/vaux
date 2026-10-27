import CoreImage
import CoreVideo
import VideoToolbox

/// Fits camera frames to the format Vaux Camera is sending: center
/// cropped to fill it, zoomed in by the camera's zoom, in hardware (a
/// straight copy when the camera's mode already matches). Frames come out in
/// the camera's own color tags, in IOSurface-backed buffers Vaux Camera
/// takes without a copy. While overlays show, Core Image draws just their
/// rectangles; the rest of the frame stays the hardware copy. While a look
/// is on, Core Image draws the whole frame.
final class Compositor {
    /// An overlay to draw, and how visible it is, 0 to 1 (fading).
    struct Drawn {
        let layer: OverlayLayer
        let alpha: Double
    }

    /// A look over the frame, and how much of it, 0 to 1 (fading).
    struct Graded {
        let look: Look
        let alpha: Double
    }

    private let transfer: VTPixelTransferSession
    /// No color management: the frame's values pass through untouched. With
    /// it, Core Image's reading of the camera's Rec. 709 tags didn't round
    /// trip, lifting shadows (Y 50 came back 64; tested).
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolFormat: FrameFormat?
    /// Overlay images, by layer key and frame height.
    private var images: [String: CIImage] = [:]
    /// Frames drawn with a look, which moves its grain.
    private var gradedFrames = 0

    init() {
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        self.transfer = transfer!
        // Scales the crop marked on each camera frame (its clean aperture).
        VTSessionSetProperty(self.transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
        VTSessionSetProperty(self.transfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    deinit {
        VTPixelTransferSessionInvalidate(transfer)
    }

    func fit(_ camera: CVPixelBuffer, to format: FrameFormat, zoom: Double, overlays: [Drawn], looks: [Graded]) -> CVPixelBuffer? {
        if poolFormat != format {
            pool = Self.pool(for: format)
            poolFormat = format
        }
        guard let output = makeBuffer() else { return nil }
        Self.markCrop(on: camera, for: format, zoom: zoom)
        guard VTPixelTransferSessionTransferImage(transfer, from: camera, to: output) == noErr else { return nil }
        // The camera's color tags, so apps read its color as it was, and so
        // overlays are drawn in the same terms.
        CVBufferPropagateAttachments(camera, output)
        let visible = overlays.filter { $0.alpha > 0 }
        let looks = looks.filter { $0.alpha > 0 }
        if visible.isEmpty {
            images = [:]
            if looks.isEmpty { return output }
        }
        // Drawn over a second copy, since Core Image shouldn't read and
        // write the same buffer.
        if let under = makeBuffer(), VTPixelTransferSessionTransferImage(transfer, from: camera, to: under) == noErr {
            CVBufferPropagateAttachments(camera, under)
            draw(visible, looks: looks, height: format.height, over: under, into: output)
        }
        return output
    }

    /// The looks over the whole frame, then each overlay in its spot, full
    /// frame ones underneath. Without a look, renders only the overlays'
    /// rectangles, on even pixels for 4:2:0 chroma.
    private func draw(_ overlays: [Drawn], looks: [Graded], height: Int32, over frame: CVPixelBuffer, into output: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let bounds = CGRect(origin: .zero, size: size)
        let original = CIImage(cvPixelBuffer: frame)
        var composite = original
        var rects: [CGRect] = []
        if !looks.isEmpty {
            // Fading out first, then in: one look dissolves into the next.
            gradedFrames += 1
            for graded in looks {
                let looked = graded.look.apply(to: original, frame: gradedFrames)
                composite = graded.alpha >= 1 ? looked : composite.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: looked,
                    kCIInputTimeKey: graded.alpha,
                ])
            }
            rects = [bounds]
        }
        var used = Set<String>()
        for drawn in overlays.sorted(by: { ($0.layer.spot == .fullFrame ? 0 : 1) < ($1.layer.spot == .fullFrame ? 0 : 1) }) {
            let key = "\(drawn.layer.key)-\(height)"
            guard let image = images[key] ?? drawn.layer.images[height].map({ CIImage(cgImage: $0) }) else { continue }
            images[key] = image
            used.insert(key)
            let origin = drawn.layer.spot.origin(for: image.extent.size, in: size)
            let placed = image
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: drawn.alpha)])
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            composite = placed.composited(over: composite)
            if looks.isEmpty { rects.append(Self.evenPixels(placed.extent.intersection(bounds))) }
        }
        images = images.filter { used.contains($0.key) }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = nil
        for rect in rects where !rect.isEmpty {
            _ = try? context.startTask(toRender: composite, from: rect, to: destination, at: rect.origin).waitUntilCompleted()
        }
    }

    private static func evenPixels(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return .zero }
        let minX = (rect.minX / 2).rounded(.down) * 2
        let minY = (rect.minY / 2).rounded(.down) * 2
        return CGRect(
            x: minX,
            y: minY,
            width: ((rect.maxX - minX) / 2).rounded(.up) * 2,
            height: ((rect.maxY - minY) / 2).rounded(.up) * 2
        )
    }

    /// Marks the part of the camera frame to send: the largest center crop
    /// in the sent shape, zoomed in.
    private static func markCrop(on camera: CVPixelBuffer, for format: FrameFormat, zoom: Double) {
        let width = Double(CVPixelBufferGetWidth(camera))
        let height = Double(CVPixelBufferGetHeight(camera))
        let aspect = Double(format.width) / Double(format.height)
        var (cropWidth, cropHeight) = width / height > aspect ? (height * aspect, height) : (width, width / aspect)
        // Even sizes, for 4:2:0 chroma.
        cropWidth = (cropWidth / zoom / 2).rounded(.down) * 2
        cropHeight = (cropHeight / zoom / 2).rounded(.down) * 2
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: cropWidth,
            kCVImageBufferCleanApertureHeightKey: cropHeight,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0,
        ]
        CVBufferSetAttachment(camera, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
    }

    private func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private static func pool(for format: FrameFormat) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height,
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
