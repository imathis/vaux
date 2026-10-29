import CoreImage
import CoreVideo
import VideoToolbox

/// Fits camera frames to the format Vaux Camera is sending: center
/// cropped to fill it, zoomed in by the camera's zoom, in hardware (a
/// straight copy when the camera's mode already matches). Frames come out in
/// the camera's own color tags, in IOSurface-backed buffers Vaux Camera
/// takes without a copy. While overlays show, Core Image draws just their
/// rectangles; the rest of the frame stays the hardware copy. While a look
/// or a shake is on, Core Image draws the whole frame.
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

    /// A shake this frame: the picture moved off center by a share of it
    /// each way and turned (radians), within the room around it that it's
    /// zoomed in to have (as a zoom); blurred along the way it came from
    /// where it was a frame before (as call apps take frames), or not;
    /// overlays moving with it, or holding still.
    struct Shaken {
        let shift: CGPoint
        let tilt: Double
        let shiftBefore: CGPoint
        let tiltBefore: Double
        let room: Double
        let blur: Bool
        let overlays: Bool
    }

    private let transfer: VTPixelTransferSession
    /// No color management: the frame's values pass through untouched. With
    /// it, Core Image's reading of the camera's Rec. 709 tags didn't round
    /// trip, lifting shadows (Y 50 came back 64; tested).
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolFormat: FrameFormat?
    /// Copies of the camera's crop with room around it, for a shake.
    private var roomyPool: CVPixelBufferPool?
    private var roomySize: CGSize?
    /// Overlay images, by layer key and frame height.
    private var images: [String: CIImage] = [:]
    /// Frames drawn with a look, which moves its grain.
    private var gradedFrames = 0
    /// Motion blur's radius for each pixel moved in a frame: about a film
    /// camera's half-frame shutter (the blur reaches a few radii).
    private static let blurPerPixel = 0.3

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

    func fit(_ camera: CVPixelBuffer, to format: FrameFormat, zoom: Double, shaken: Shaken?, overlays: [Drawn], looks: [Graded]) -> CVPixelBuffer? {
        if poolFormat != format {
            pool = Self.pool(width: Double(format.width), height: Double(format.height), pixelFormat: format.pixelFormat)
            poolFormat = format
        }
        guard let output = Self.makeBuffer(from: pool) else { return nil }
        let visible = overlays.filter { $0.alpha > 0 }
        let looks = looks.filter { $0.alpha > 0 }
        if visible.isEmpty { images = [:] }
        let crop = Self.crop(of: camera, for: format, zoom: zoom)
        if let shaken {
            guard let (picture, move) = shake(camera, crop: crop, for: format, by: shaken) else { return nil }
            CVBufferPropagateAttachments(camera, output)
            draw(visible, looks: looks, height: format.height, on: picture, whole: true, moving: shaken.overlays ? move : nil, into: output)
            return output
        }
        Self.mark(camera, width: crop.width, height: crop.height)
        guard VTPixelTransferSessionTransferImage(transfer, from: camera, to: output) == noErr else { return nil }
        // The camera's color tags, so apps read its color as it was, and so
        // overlays are drawn in the same terms.
        CVBufferPropagateAttachments(camera, output)
        if visible.isEmpty, looks.isEmpty { return output }
        // Drawn over a second copy, since Core Image shouldn't read and
        // write the same buffer.
        if let under = Self.makeBuffer(from: pool), VTPixelTransferSessionTransferImage(transfer, from: camera, to: under) == noErr {
            CVBufferPropagateAttachments(camera, under)
            draw(visible, looks: looks, height: format.height, on: CIImage(cvPixelBuffer: under), whole: !looks.isEmpty, moving: nil, into: output)
        }
        return output
    }

    /// The picture, the looks over it, then each overlay in its spot, full
    /// frame ones underneath; `moving` moves overlays with a shaken picture.
    /// Renders the whole frame, or only the overlays' rectangles, on even
    /// pixels for 4:2:0 chroma, over the hardware copy already there.
    private func draw(_ overlays: [Drawn], looks: [Graded], height: Int32, on picture: CIImage, whole: Bool, moving: ((CIImage) -> CIImage)?, into output: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        let bounds = CGRect(origin: .zero, size: size)
        var composite = picture
        if !looks.isEmpty {
            // Fading out first, then in: one look dissolves into the next.
            gradedFrames += 1
            for graded in looks {
                let looked = graded.look.apply(to: picture, frame: gradedFrames)
                composite = graded.alpha >= 1 ? looked : composite.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: looked,
                    kCIInputTimeKey: graded.alpha,
                ])
            }
        }
        var rects = whole ? [bounds] : []
        var used = Set<String>()
        for drawn in overlays.sorted(by: { ($0.layer.spot == .fullFrame ? 0 : 1) < ($1.layer.spot == .fullFrame ? 0 : 1) }) {
            let key = "\(drawn.layer.key)-\(height)"
            let image: CIImage
            if let video = drawn.layer.video {
                // Nothing until its first frame's ready.
                guard let frame = video.frame() else { continue }
                image = Self.place(frame, as: video, in: size)
            } else {
                guard let still = images[key] ?? drawn.layer.images[height].map({ CIImage(cgImage: $0) }) else { continue }
                image = still
                images[key] = still
                used.insert(key)
            }
            let origin = drawn.layer.spot.origin(for: image.extent.size, in: size)
            let placed = image
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: drawn.alpha)])
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            composite = (moving?(placed) ?? placed).composited(over: composite)
            if !whole { rects.append(Self.evenPixels(placed.extent.intersection(bounds))) }
        }
        images = images.filter { used.contains($0.key) }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = nil
        for rect in rects where !rect.isEmpty {
            _ = try? context.startTask(toRender: composite, from: rect, to: destination, at: rect.origin).waitUntilCompleted()
        }
    }

    /// A video's frame sized and cropped as a still graphic would be, at the
    /// origin.
    private static func place(_ frame: CIImage, as video: OverlayVideo, in size: CGSize) -> CIImage {
        let extent = frame.extent
        let (canvas, drawn) = OverlayRenderer.layout(extent.size, spot: video.spot, size: video.size, fit: video.fit, in: size)
        let scaled = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: drawn.width / extent.width, y: drawn.height / extent.height))
            .concatenating(CGAffineTransform(translationX: drawn.minX, y: drawn.minY)))
        return scaled.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// The picture shaken. The hardware copies the crop with room around it
    /// (as much as the camera's frame has), and Core Image moves and turns
    /// it within that room, both held back together where there's less of
    /// it (while zooming in, or at the zoom limit); blurred along the way it
    /// went since the last frame, if it blurs. Also returns the same move,
    /// for overlays that move with it.
    private func shake(_ camera: CVPixelBuffer, crop: Crop, for format: FrameFormat, by shaken: Shaken) -> (CIImage, (CIImage) -> CIImage)? {
        let width = Double(format.width)
        let height = Double(format.height)
        let roomy = CGSize(width: Self.even(width * shaken.room, .up), height: Self.even(height * shaken.room, .up))
        if roomySize != roomy {
            roomyPool = Self.pool(width: roomy.width, height: roomy.height, pixelFormat: format.pixelFormat)
            roomySize = roomy
        }
        // The room the camera's frame has, in the crop's shape.
        let room = min(shaken.room, crop.cameraWidth / crop.width, crop.cameraHeight / crop.height)
        let copied = CGSize(width: Self.even(crop.width * room, .down), height: Self.even(crop.height * room, .down))
        Self.mark(camera, width: copied.width, height: copied.height)
        guard let copy = Self.makeBuffer(from: roomyPool), VTPixelTransferSessionTransferImage(transfer, from: camera, to: copy) == noErr else { return nil }
        CVBufferPropagateAttachments(camera, copy)

        // How far the copy reaches past each edge of the sent frame, in its
        // pixels: the move, and the corners a turn swings out, stay inside.
        let marginX = (copied.width / crop.width - 1) * width / 2
        let marginY = (copied.height / crop.height - 1) * height / 2
        var dx = shaken.shift.x * width
        var dy = shaken.shift.y * height
        var angle = shaken.tilt
        let needX = abs(dx) + height / 2 * abs(sin(angle))
        let needY = abs(dy) + width / 2 * abs(sin(angle))
        let held = min(1, needX > marginX ? marginX / needX : 1, needY > marginY ? marginY / needY : 1)
        dx *= held
        dy *= held
        angle *= held

        // Moved, then turned about the frame's middle.
        let shift = CGAffineTransform(translationX: dx, y: dy)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: width / 2, y: height / 2))
        // The copy's middle to the frame's, at the frame's scale.
        let scale = CGAffineTransform(translationX: -roomy.width / 2, y: -roomy.height / 2)
            .concatenating(CGAffineTransform(
                scaleX: copied.width / crop.width * width / roomy.width,
                y: copied.height / crop.height * height / roomy.height
            ))
        var picture = CIImage(cvPixelBuffer: copy).clampedToExtent().transformed(by: scale.concatenating(shift))

        // The picture's middle, now and a frame before: the same whichever
        // frames an app takes.
        let middle = CGPoint(x: dx, y: dy).applying(CGAffineTransform(rotationAngle: angle))
        let before = CGPoint(x: shaken.shiftBefore.x * width * held, y: shaken.shiftBefore.y * height * held)
            .applying(CGAffineTransform(rotationAngle: shaken.tiltBefore * held))
        var blur: [String: Any]?
        if shaken.blur {
            let along = CGVector(dx: middle.x - before.x, dy: middle.y - before.y)
            let radius = min(hypot(along.dx, along.dy) * Self.blurPerPixel, 40)
            // Barely moving: not worth a blur.
            if radius >= 0.5 { blur = [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(along.dy, along.dx)] }
        }
        if let blur { picture = picture.applyingFilter("CIMotionBlur", parameters: blur) }

        let overlays = CGAffineTransform(translationX: -width / 2, y: -height / 2).concatenating(shift)
        return (picture.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), { image in
            let moved = image.transformed(by: overlays)
            return blur.map { moved.applyingFilter("CIMotionBlur", parameters: $0) } ?? moved
        })
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

    /// Even, for 4:2:0 chroma.
    private static func even(_ value: Double, _ rule: FloatingPointRoundingRule) -> Double {
        (value / 2).rounded(rule) * 2
    }

    /// The part of the camera frame to send: the largest center crop in the
    /// sent shape, zoomed in.
    private struct Crop {
        let width: Double
        let height: Double
        let cameraWidth: Double
        let cameraHeight: Double
    }

    private static func crop(of camera: CVPixelBuffer, for format: FrameFormat, zoom: Double) -> Crop {
        let width = Double(CVPixelBufferGetWidth(camera))
        let height = Double(CVPixelBufferGetHeight(camera))
        let aspect = Double(format.width) / Double(format.height)
        let (cropWidth, cropHeight) = width / height > aspect ? (height * aspect, height) : (width, width / aspect)
        return Crop(width: even(cropWidth / zoom, .down), height: even(cropHeight / zoom, .down), cameraWidth: width, cameraHeight: height)
    }

    /// Marks the middle of the camera frame, this big, for the hardware to
    /// copy (its clean aperture).
    private static func mark(_ camera: CVPixelBuffer, width: Double, height: Double) {
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: width,
            kCVImageBufferCleanApertureHeightKey: height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0,
        ]
        CVBufferSetAttachment(camera, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
    }

    private static func makeBuffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private static func pool(width: Double, height: Double, pixelFormat: OSType) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height),
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
