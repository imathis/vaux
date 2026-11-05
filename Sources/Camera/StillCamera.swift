import AVFoundation
import CoreAudio

/// Tells a virtual camera's picture from the still card it sends while the
/// app behind it isn't running: Camera Hub's "Please run Camera Hub to use
/// Elgato Virtual Camera", about once a second, every frame byte for byte the
/// same. A picture never is: there's always a camera's noise in it. Only
/// virtual cameras are checked: a real one with its shutter closed sends
/// still black, and that's no reason to switch to another.
///
/// A sample of each frame's brightness, one byte in 8 of one row in 8,
/// compared with the frame before: a few thousand bytes, next to no time.
struct StillCheck {
    /// Still this long, or nothing at all, and it's a card.
    static let limit = 3.0

    /// Its picture has moved since it started: changed twice within a
    /// second, not once, as when one card gives way to another.
    private(set) var live = false
    private var changed: Double
    private var last: [UInt8]?

    init(at now: Double) {
        changed = now
    }

    /// Whether Vaux checks this camera: a virtual one, an app's.
    static func applies(to cameraID: String) -> Bool {
        AVCaptureDevice(uniqueID: cameraID)?.transportType == Int32(bitPattern: kAudioDeviceTransportTypeVirtual)
    }

    mutating func take(_ pixels: CVPixelBuffer, at now: Double) {
        let sample = Self.sample(pixels)
        if let last, sample != last {
            if now - changed < 1 { live = true }
            changed = now
        }
        last = sample
    }

    /// Unchanged for `limit` seconds: a card, or nothing coming.
    func isStill(at now: Double) -> Bool {
        now - changed >= Self.limit
    }

    private static func sample(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixels)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixels, 0) : CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) : CVPixelBufferGetBytesPerRow(pixels)
        let rows = planar ? CVPixelBufferGetHeightOfPlane(pixels, 0) : CVPixelBufferGetHeight(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sample: [UInt8] = []
        sample.reserveCapacity((rows / 8 + 1) * (bytesPerRow / 8 + 1))
        for row in stride(from: 0, to: rows, by: 8) {
            for column in stride(from: 0, to: bytesPerRow, by: 8) { sample.append(bytes[row * bytesPerRow + column]) }
        }
        return sample
    }
}

/// While Vaux sends another camera, watches the virtual cameras it skipped
/// for showing a still card (see StillCheck): one whose picture starts moving
/// (its app opened) is reported, to be sent again. A card comes about once a
/// second, so watching costs next to nothing.
final class StillCameraWatch: @unchecked Sendable {
    private let onLive: @MainActor @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.imathis.vaux.still-watch")
    // Queue only.
    private var watching: [String: Watch] = [:]

    init(onLive: @escaping @MainActor @Sendable (String) -> Void) {
        self.onLive = onLive
    }

    /// Watches these cameras, and no others.
    func watch(_ cameraIDs: Set<String>) {
        queue.async { [self] in
            for (id, watch) in watching where !cameraIDs.contains(id) {
                watch.stop()
                watching[id] = nil
            }
            for id in cameraIDs where watching[id] == nil {
                watching[id] = Watch(cameraID: id, onLive: onLive)
            }
        }
    }

    /// One camera's frames, until its picture moves.
    private final class Watch: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let cameraID: String
        private let onLive: @MainActor @Sendable (String) -> Void
        private let session = AVCaptureSession()
        private let frames = DispatchQueue(label: "dev.imathis.vaux.still-watch.frames")
        // Frames queue only.
        private var check = StillCheck(at: 0)
        private var reported = false

        init(cameraID: String, onLive: @escaping @MainActor @Sendable (String) -> Void) {
            self.cameraID = cameraID
            self.onLive = onLive
            super.init()
            guard let device = AVCaptureDevice(uniqueID: cameraID),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frames)
            guard session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            session.startRunning()
        }

        func stop() {
            session.stopRunning()
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !reported, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            check.take(pixels, at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            guard check.live else { return }
            reported = true
            let (onLive, cameraID) = (onLive, cameraID)
            Task { @MainActor in onLive(cameraID) }
        }
    }
}
