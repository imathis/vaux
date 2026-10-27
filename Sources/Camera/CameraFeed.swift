import AVFoundation
import os

/// Runs a camera and feeds its frames, fitted to the format Vaux Camera is
/// sending, into Vaux Camera's sink.
final class CameraFeed: NSObject, @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var format: FrameFormat?
        var fps = 0
        var dropped = 0
        /// Capture to handoff, averaged over the last second.
        var latencyMS = 0.0
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "dev.imathis.vaux.session")
    private let videoQueue = DispatchQueue(label: "dev.imathis.vaux.video", qos: .userInteractive)
    private let onStats: @MainActor @Sendable (Stats) -> Void
    private let log = Logger(subsystem: "dev.imathis.vaux", category: "feed")

    // Session queue only.
    private var input: AVCaptureDeviceInput?
    private var configuredFor: FrameFormat?
    /// The zoom the camera's mode was chosen to keep sharp.
    private var configuredZoom = 1.0
    /// The latest mode-zoom change; earlier ones waiting out the pause are
    /// dropped.
    private var zoomChange = 0

    // Video queue only.
    private let compositor: Compositor
    private var sink: SinkConnection?
    private var format: FrameFormat?
    private var zoom = 1.0
    /// A push in or out under way: from, to, and when it began.
    private var zoomMove: (from: Double, to: Double, start: CMTime)?
    /// Overlays showing and fading: each eases toward shown or gone.
    private var overlays: [(layer: OverlayLayer, alpha: Double, shown: Bool)] = []
    /// Looks fading in and out, by ID: one is shown at a time.
    private var looks: [(look: Look, alpha: Double, shown: Bool)] = []
    private var sent = 0
    private var dropped = 0
    private var latency = 0.0
    private var countingSince = CMClockGetTime(CMClockGetHostTimeClock())
    /// The last frame taken: ones closer together than Vaux Camera's rate
    /// are skipped. Cameras can run faster than asked: macOS resets their
    /// rate when its video effects change (a Facecam went back to 60 fps
    /// when Portrait was turned off, doubling the work).
    private var lastTaken = CMTime.invalid

    /// Overlays fade in and out over a quarter second.
    private static let fadeStep = 1 / (0.25 * Double(CameraSpec.fps))
    /// Pushing in or out takes this long, eased.
    private static let zoomMoveSeconds = 0.3

    init(onStats: @escaping @MainActor @Sendable (Stats) -> Void) {
        self.onStats = onStats
        compositor = Compositor()
        super.init()
        // Cameras' own format; the compositor converts if it must.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
    }

    /// Runs the camera with this unique ID into `sink`, in `format`, zoomed
    /// in by `zoom`, switching from what's running, if anything. The camera
    /// runs in a mode that keeps `modeZoom` sharp: at least `zoom`, more when
    /// zoom shortcuts may push further.
    func start(cameraID: String, format: FrameFormat, zoom: Double, modeZoom: Double, sink: SinkConnection) {
        sessionQueue.async { [self] in
            if input?.device.uniqueID != cameraID || configuredFor != format || configuredZoom != modeZoom {
                use(cameraID, for: format, zoom: modeZoom)
            }
            let previous = videoQueue.sync {
                defer {
                    self.sink = sink
                    self.format = format
                    self.zoom = zoom
                    zoomMove = nil
                }
                return self.sink
            }
            if previous !== sink { previous?.stop() }
            sink.start()
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Zooms the running camera, from the next frame: at once (the slider),
    /// or eased over a moment (a zoom shortcut pushing in or out).
    func setZoom(_ zoom: Double, animated: Bool) {
        videoQueue.async { [self] in
            if animated {
                zoomMove = (from: self.zoom, to: zoom, start: CMClockGetTime(CMClockGetHostTimeClock()))
            } else {
                zoomMove = nil
                self.zoom = zoom
            }
        }
    }

    /// Picks the camera mode that keeps `zoom` sharp, if the camera has one,
    /// once it stops changing, so dragging the slider doesn't keep
    /// reconfiguring the camera.
    func setModeZoom(_ zoom: Double) {
        sessionQueue.async { [self] in
            zoomChange += 1
            let change = zoomChange
            sessionQueue.asyncAfter(deadline: .now() + 0.4) { [self] in
                guard change == zoomChange, let device = input?.device, let format = configuredFor, zoom != configuredZoom else { return }
                configuredZoom = zoom
                configure(device, for: format, zoom: zoom)
                logMode(of: device, for: format)
            }
        }
    }

    /// Advances a push in or out, per frame.
    private func easeZoom() {
        guard let move = zoomMove else { return }
        let t = min((CMClockGetTime(CMClockGetHostTimeClock()) - move.start).seconds / Self.zoomMoveSeconds, 1)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        zoom = move.from + (move.to - move.from) * eased
        if t >= 1 { zoomMove = nil }
    }

    /// The overlays to show. New ones fade in; ones no longer listed fade out.
    func showOverlays(_ layers: [OverlayLayer]) {
        videoQueue.async { [self] in
            let keys = Set(layers.map(\.key))
            for index in overlays.indices { overlays[index].shown = keys.contains(overlays[index].layer.key) }
            for layer in layers where !overlays.contains(where: { $0.layer.key == layer.key }) {
                overlays.append((layer: layer, alpha: 0, shown: true))
            }
        }
    }

    /// The look to show, or none. It fades in over the last; an edit to the
    /// one showing applies at once, so its sliders can be watched.
    func showLook(_ look: Look?) {
        videoQueue.async { [self] in
            for index in looks.indices {
                if looks[index].look.id == look?.id, let look {
                    looks[index].look = look
                    looks[index].shown = true
                } else {
                    looks[index].shown = false
                }
            }
            if let look, !looks.contains(where: { $0.look.id == look.id }) {
                looks.append((look: look, alpha: 0, shown: true))
            }
        }
    }

    /// Advances look fades, per frame.
    private func fadeLooks() {
        for index in looks.indices {
            let alpha = looks[index].alpha + (looks[index].shown ? Self.fadeStep : -Self.fadeStep)
            looks[index].alpha = min(max(alpha, 0), 1)
        }
        looks.removeAll { !$0.shown && $0.alpha <= 0 }
    }

    /// Advances overlay fades, per frame.
    private func fadeOverlays() {
        for index in overlays.indices {
            let alpha = overlays[index].alpha + (overlays[index].shown ? Self.fadeStep : -Self.fadeStep)
            overlays[index].alpha = min(max(alpha, 0), 1)
        }
        overlays.removeAll { !$0.shown && $0.alpha <= 0 }
    }

    /// Stops the camera (its light goes off) and the sink.
    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            let sink = videoQueue.sync {
                defer { self.sink = nil }
                return self.sink
            }
            sink?.stop()
            let onStats = self.onStats
            Task { @MainActor in onStats(Stats()) }
        }
    }

    private func use(_ cameraID: String, for format: FrameFormat, zoom: Double) {
        session.beginConfiguration()
        if input?.device.uniqueID != cameraID {
            if let input {
                session.removeInput(input)
                self.input = nil
            }
            if let device = AVCaptureDevice(uniqueID: cameraID) {
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                        self.input = input
                    } else {
                        log.error("Can't use \(device.localizedName, privacy: .public)")
                    }
                } catch {
                    log.error("Can't open \(device.localizedName, privacy: .public): \(error)")
                }
            } else {
                log.error("No camera \(cameraID, privacy: .public)")
            }
        }
        if let device = input?.device { configure(device, for: format, zoom: zoom) }
        configuredFor = format
        configuredZoom = zoom
        session.commitConfiguration()
        if let device = input?.device { logMode(of: device, for: format) }
    }

    private func logMode(of device: AVCaptureDevice, for format: FrameFormat) {
        let mode = device.activeFormat.formatDescription
        log.notice("Camera: \(device.localizedName, privacy: .public), \(mode.dimensions.width)×\(mode.dimensions.height) \(Self.fourCC(mode.mediaSubType.rawValue), privacy: .public) for \(format.description, privacy: .public) at \(self.configuredZoom.zoomText, privacy: .public)")
    }

    /// How far a camera can zoom into `format` and stay sharp: past this, its
    /// largest mode is being scaled up.
    static func sharpZoom(cameraID: String, for format: FrameFormat) -> Double {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else { return 1 }
        let largest = usableModes(of: device).map { mode in
            let size = mode.formatDescription.dimensions
            return min(Double(size.width) / Double(format.width), Double(size.height) / Double(format.height))
        }.max() ?? 1
        return max(largest, 1)
    }

    private static func usableModes(of device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        let fps = Double(CameraSpec.fps)
        return device.formats.filter { mode in
            mode.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
    }

    /// Runs the camera in the mode closest to what's being sent, zoomed:
    /// that exact size if it has it (a straight copy, no scaling), else its
    /// smallest mode that still fills it, else its largest. Caps it at Vaux
    /// Camera's rate, so a 60 fps camera doesn't do twice the work; the
    /// slowest rate is left alone, since cameras slow down in low light to
    /// keep exposure.
    private func configure(_ device: AVCaptureDevice, for format: FrameFormat, zoom: Double) {
        let usable = Self.usableModes(of: device)
        let filling = usable.filter { mode in
            let size = mode.formatDescription.dimensions
            return Double(size.width) >= Double(format.width) * zoom && Double(size.height) >= Double(format.height) * zoom
        }
        // Among equal sizes, uncompressed YUV before anything that needs
        // decoding (USB cameras often offer MJPEG too).
        let ordered: (AVCaptureDevice.Format, AVCaptureDevice.Format) -> Bool = { a, b in
            let (areaA, areaB) = (Self.area(a), Self.area(b))
            return areaA != areaB ? areaA < areaB : Self.cost(a) < Self.cost(b)
        }
        let best = filling.isEmpty ? usable.max(by: ordered) : filling.min(by: ordered)
        guard let best, (try? device.lockForConfiguration()) != nil else { return }
        // Setting the mode directly also keeps the session from applying a
        // preset over it.
        if best != device.activeFormat { device.activeFormat = best }
        device.activeVideoMinFrameDuration = CameraSpec.frameDuration
        device.unlockForConfiguration()
    }

    private static func area(_ mode: AVCaptureDevice.Format) -> Int {
        let size = mode.formatDescription.dimensions
        return Int(size.width) * Int(size.height)
    }

    private static func cost(_ mode: AVCaptureDevice.Format) -> Int {
        switch mode.formatDescription.mediaSubType.rawValue {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: 0
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: 1
        default: 2
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    /// Reports once a second, on the video queue.
    private func count(sent didSend: Bool, latency seconds: Double = 0) {
        if didSend {
            sent += 1
            latency += seconds
        } else {
            dropped += 1
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard (now - countingSince).seconds >= 1 else { return }
        let stats = Stats(format: format, fps: sent, dropped: dropped, latencyMS: sent > 0 ? latency / Double(sent) * 1000 : 0)
        sent = 0
        dropped = 0
        latency = 0
        countingSince = now
        let onStats = self.onStats
        Task { @MainActor in onStats(stats) }
    }
}

extension CameraFeed: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let captured = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastTaken.isValid, (captured - lastTaken).seconds < CameraSpec.frameDuration.seconds * 0.75 { return }
        lastTaken = captured
        fadeOverlays()
        fadeLooks()
        easeZoom()
        let drawn = overlays.map { Compositor.Drawn(layer: $0.layer, alpha: $0.alpha) }
        // The one fading out under the one fading in.
        let graded = (looks.filter { !$0.shown } + looks.filter(\.shown)).map { Compositor.Graded(look: $0.look, alpha: $0.alpha) }
        guard let sink, let format, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = compositor.fit(pixels, to: format, zoom: zoom, overlays: drawn, looks: graded)
        else {
            count(sent: false)
            return
        }
        guard sink.enqueue(frame, presentationTime: captured) else {
            count(sent: false)
            return
        }
        // Capture times are host time on macOS.
        count(sent: true, latency: (CMClockGetTime(CMClockGetHostTimeClock()) - captured).seconds)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        count(sent: false)
    }
}
