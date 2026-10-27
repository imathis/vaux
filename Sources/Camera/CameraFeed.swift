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
    /// The last frame taken: ones closer together than Vaux Camera's
    /// fastest rate are skipped, should a camera run faster than asked.
    private var lastTaken = CMTime.invalid

    /// Overlays fade in and out over a quarter second.
    private static let fadeSeconds = 0.25
    /// When the last frame was taken: fades go by time, so they take as
    /// long at 30 fps as at 60.
    private var lastFaded = CMTime.invalid
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
            } else if !session.isRunning, let device = input?.device {
                // Starting again: while stopped, the camera may have been
                // used by another app in its own mode (or reset to its
                // default, 30 fps), so set Vaux's again.
                configure(device, for: format, zoom: modeZoom)
                logMode(of: device, for: format)
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

    /// How far this frame's fades move: the time since the last frame, as
    /// a share of a fade (a first frame counts as a 30 fps one).
    private func fadeStep(at time: CMTime) -> Double {
        defer { lastFaded = time }
        let elapsed = lastFaded.isValid ? (time - lastFaded).seconds : CameraSpec.slowestFrameDuration.seconds
        return min(max(elapsed, 0), 0.1) / Self.fadeSeconds
    }

    /// Advances look fades, per frame.
    private func fadeLooks(by fadeStep: Double) {
        for index in looks.indices {
            let alpha = looks[index].alpha + (looks[index].shown ? fadeStep : -fadeStep)
            looks[index].alpha = min(max(alpha, 0), 1)
        }
        looks.removeAll { !$0.shown && $0.alpha <= 0 }
    }

    /// Advances overlay fades, per frame.
    private func fadeOverlays(by fadeStep: Double) {
        for index in overlays.indices {
            let alpha = overlays[index].alpha + (overlays[index].shown ? fadeStep : -fadeStep)
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

    /// Modes that run at 30 fps or better (29.97 included).
    private static func usableModes(of device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        let slowest = 1 / CameraSpec.slowestFrameDuration.seconds
        return device.formats.filter { fastest(of: $0) * nearly >= slowest }
    }

    private static func fastest(of mode: AVCaptureDevice.Format) -> Double {
        mode.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    /// Runs the camera in the mode closest to what's being sent, zoomed:
    /// that exact size if it has it (a straight copy, no scaling), else its
    /// smallest mode that still fills it, else its largest; of those, the
    /// fastest, up to Vaux Camera's 60 fps. The slowest rate is left alone,
    /// since cameras slow down in low light to keep exposure.
    private func configure(_ device: AVCaptureDevice, for format: FrameFormat, zoom: Double) {
        let usable = Self.usableModes(of: device)
        let filling = usable.filter { mode in
            let size = mode.formatDescription.dimensions
            return Double(size.width) >= Double(format.width) * zoom && Double(size.height) >= Double(format.height) * zoom
        }
        // Among equal sizes, uncompressed YUV before anything that needs
        // decoding (USB cameras often offer MJPEG too), then the faster.
        let better: (AVCaptureDevice.Format, AVCaptureDevice.Format) -> Bool = { a, b in
            Self.cost(a) != Self.cost(b) ? Self.cost(a) < Self.cost(b) : Self.rate(a) > Self.rate(b)
        }
        let best = filling.isEmpty
            ? usable.max { a, b in Self.area(a) != Self.area(b) ? Self.area(a) < Self.area(b) : better(b, a) }
            : filling.min { a, b in Self.area(a) != Self.area(b) ? Self.area(a) < Self.area(b) : better(a, b) }
        guard let best, (try? device.lockForConfiguration()) != nil else { return }
        // Setting the mode directly also keeps the session from applying a
        // preset over it.
        if best != device.activeFormat { device.activeFormat = best }
        // A duration the mode itself reports, never one worked out: one a
        // hair outside its range (60 against a 59.94 fps mode) throws, and
        // takes Vaux down with it.
        if let duration = Self.frameDuration(of: best) { device.activeVideoMinFrameDuration = duration }
        device.unlockForConfiguration()
    }

    /// The mode's fastest frame duration, held to Vaux Camera's 60 fps, or
    /// nil if every rate it has is faster. Past either end of a range, the
    /// range's own value: cameras say 60.00024 or 59.94 where they mean 60,
    /// and plain 1/60 against those is out of range.
    private static func frameDuration(of mode: AVCaptureDevice.Format) -> CMTime? {
        mode.videoSupportedFrameRateRanges
            .map { range in
                if CMTimeCompare(CameraSpec.frameDuration, range.minFrameDuration) < 0 { return range.minFrameDuration }
                if CMTimeCompare(CameraSpec.frameDuration, range.maxFrameDuration) > 0 { return range.maxFrameDuration }
                return CameraSpec.frameDuration
            }
            .filter { 1 / $0.seconds <= Double(CameraSpec.fps) * nearly }
            .min { CMTimeCompare($0, $1) < 0 }
    }

    /// How far off a camera's rate can be and still count: 60.00024 is 60,
    /// 29.97 is 30.
    private static let nearly = 1.01

    /// Its fastest rate, up to Vaux Camera's.
    private static func rate(_ mode: AVCaptureDevice.Format) -> Double {
        min(fastest(of: mode), Double(CameraSpec.fps))
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
        let fadeStep = fadeStep(at: captured)
        fadeOverlays(by: fadeStep)
        fadeLooks(by: fadeStep)
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
