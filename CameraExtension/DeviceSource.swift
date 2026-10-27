import CoreMediaIO
import Foundation
import IOKit.audio
import os

extension Logger {
    static let camera = Logger(subsystem: "dev.imathis.vaux", category: "camera")
}

extension CMIOExtensionProperty {
    static let watched = CMIOExtensionProperty(rawValue: CameraSpec.watchedProperty)
}

// Read-only after creation; passed to the frame queue.
extension CMIOExtensionClient: @retroactive @unchecked Sendable {}

/// Vaux Camera. Vaux feeds camera frames into the sink stream and they go
/// straight out to the apps watching. If they stop (Vaux switching cameras,
/// or quitting), the last frame holds briefly, then the placeholder shows.
/// While no app is watching, nothing runs.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: StreamSource!
    private var sink: SinkSource!
    private var clientsObservation: NSKeyValueObservation?
    /// Read when asked for properties, on the provider's queue.
    private let isWatched = OSAllocatedUnfairLock(initialState: false)

    /// Streaming state and frames are all handled here.
    private let queue = DispatchQueue(label: "dev.imathis.vaux.camera.frames", qos: .userInteractive)
    /// Runs while an app is watching, at twice the frame rate: takes Vaux's
    /// frames, and fills in when they stop.
    private var timer: DispatchSourceTimer?
    /// Vaux, while it's feeding the sink.
    private var feeder: CMIOExtensionClient?
    /// A request for Vaux's next frame is out. Asking when none is waiting
    /// comes back empty at once, so requests follow the timer, one at a time.
    private var consuming = false
    /// The size the watching app chose. Vaux sends that.
    private var size = CameraSpec.sizes[0]
    private var lastFrame: CVPixelBuffer?
    /// When Vaux's last frame arrived, and when anything last went out.
    private var lastFrameTime: UInt64 = 0
    private var lastSentTime: UInt64 = 0
    private var format: CMFormatDescription?
    /// Made when first needed, per size.
    private var placeholders: [String: CVPixelBuffer] = [:]

    /// How long the last frame holds before the placeholder shows: covers
    /// Vaux switching cameras.
    private static let hold: UInt64 = 2_000_000_000
    /// Frames are late past the slowest rate a camera sends at.
    private static let frameNanos = UInt64(CameraSpec.slowestFrameDuration.seconds * 1_000_000_000)

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: CameraSpec.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        let formats = CameraSpec.sizes.map(Self.streamFormat)
        source = StreamSource(localizedName: "\(localizedName) Video", streamID: CameraSpec.sourceStreamID, formats: formats, owner: self)
        sink = SinkSource(localizedName: "\(localizedName) Input", streamID: CameraSpec.sinkStreamID, formats: formats, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Couldn't add the streams: \(error)")
        }
        // Who's watching, per the system: the source stream's clients.
        clientsObservation = source.stream.observe(\.streamingClients) { [weak self] _, _ in
            self?.watchersChanged()
        }
    }

    private static func streamFormat(_ size: CMVideoDimensions) -> CMIOExtensionStreamFormat {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CameraSpec.pixelFormat,
            width: size.width,
            height: size.height,
            extensions: CameraSpec.colorExtensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: CameraSpec.slowestFrameDuration,
            minFrameDuration: CameraSpec.frameDuration,
            validFrameDurations: nil
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, .watched] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = CameraSpec.name
        }
        if properties.contains(.watched) {
            deviceProperties.setPropertyState(Self.watchedState(isWatched.withLock { $0 }), forProperty: .watched)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    private static func watchedState(_ watched: Bool) -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState<AnyObject>(value: (watched ? "1" : "0") as NSString)
    }

    /// The watching app chose one of Vaux Camera's formats. Called on the
    /// provider's queue.
    func formatChanged(to index: Int) {
        sink.activeFormatIndex = index
        let size = CameraSpec.sizes[index]
        queue.async { [self] in
            guard size.width != self.size.width || size.height != self.size.height else { return }
            self.size = size
            lastFrame = nil
            Logger.camera.notice("Format: \(size.width)×\(size.height)")
            // Vaux reads the size from the stream; have it look again.
            if timer != nil { device.notifyPropertiesChanged([.watched: Self.watchedState(true)]) }
        }
    }

    private func placeholder() -> CVPixelBuffer? {
        let key = "\(size.width)x\(size.height)"
        if let made = placeholders[key] { return made }
        let made = Placeholder.make(size)
        placeholders[key] = made
        return made
    }

    // MARK: Watching

    /// The source stream started, stopped, or its clients changed.
    func watchersChanged() {
        queue.async { [self] in
            let watched = !source.stream.streamingClients.isEmpty
            guard watched != (timer != nil) else { return }
            if watched {
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                timer.schedule(deadline: .now(), repeating: CameraSpec.frameDuration.seconds / 2, leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                timer.resume()
                self.timer = timer
            } else {
                timer?.cancel()
                timer = nil
            }
            isWatched.withLock { $0 = watched }
            device.notifyPropertiesChanged([.watched: Self.watchedState(watched)])
            Logger.camera.notice("\(watched ? "Watched" : "Not watched", privacy: .public)")
        }
    }

    private func tick() {
        if let feeder, !consuming { consume(from: feeder) }
        // Vaux's frames go out as they arrive. Fill in, at the frame rate,
        // only once they're late.
        let now = Self.hostNanos()
        guard now - lastFrameTime >= Self.frameNanos * 3 / 2,
              now - lastSentTime >= Self.frameNanos * 9 / 10
        else { return }
        if let lastFrame, now - lastFrameTime < Self.hold {
            send(lastFrame, at: now)
        } else {
            lastFrame = nil
            if let placeholder = placeholder() { send(placeholder, at: now) }
        }
    }

    // MARK: Feeding

    func startFeeding(from client: CMIOExtensionClient) {
        queue.async { [self] in
            Logger.camera.notice("Feeding from pid \(client.pid), \(client.signingID ?? "unsigned", privacy: .public)")
            feeder = client
        }
    }

    func stopFeeding() {
        queue.async { [self] in
            Logger.camera.notice("Feeding stopped")
            feeder = nil
        }
    }

    /// Asks for Vaux's next frame.
    private func consume(from client: CMIOExtensionClient) {
        consuming = true
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, hasMore, _ in
            // The pixel buffer is only touched on the frame queue from here.
            nonisolated(unsafe) let frame = sample.flatMap(CMSampleBufferGetImageBuffer)
            guard let self else { return }
            queue.async { self.received(frame, sequence: sequence, hasMore: hasMore, from: client) }
        }
    }

    private func received(_ frame: CVPixelBuffer?, sequence: UInt64, hasMore: Bool, from client: CMIOExtensionClient) {
        consuming = false
        // Nothing waiting yet: the next tick asks again.
        guard feeder?.clientID == client.clientID, let frame else { return }
        let now = Self.hostNanos()
        sink.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now)
        )
        // Behind: skip to the newest rather than send stale frames.
        if hasMore {
            consume(from: client)
            return
        }
        // Sized before the watching app changed format: Vaux is catching up.
        guard CVPixelBufferGetWidth(frame) == Int(size.width), CVPixelBufferGetHeight(frame) == Int(size.height) else { return }
        lastFrame = frame
        lastFrameTime = now
        if timer != nil {
            send(frame, at: now)
        }
    }

    private func send(_ frame: CVPixelBuffer, at now: UInt64) {
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame) }) ?? true {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: CameraSpec.frameDuration,
            presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            Logger.camera.error("Couldn't make a sample buffer: \(status)")
            return
        }
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
        lastSentTime = now
    }

    private static func hostNanos() -> UInt64 {
        let now = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default)
        return UInt64(now.value)
    }
}
