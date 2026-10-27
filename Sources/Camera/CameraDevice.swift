import CoreMediaIO
import Foundation
import Observation
import os

/// The frames Vaux Camera wants: the format the watching app chose.
struct FrameFormat: Equatable, Sendable, CustomStringConvertible {
    let width: Int32
    let height: Int32
    let pixelFormat: OSType

    /// What extensions before the 720p/1080p YUV formats took, all they said.
    static let original = FrameFormat(width: 1280, height: 720, pixelFormat: kCVPixelFormatType_32BGRA)
    static let hd = FrameFormat(width: 1280, height: 720, pixelFormat: CameraSpec.pixelFormat)
    static let fullHD = FrameFormat(width: 1920, height: 1080, pixelFormat: CameraSpec.pixelFormat)

    init(width: Int32, height: Int32, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    init(_ description: CMFormatDescription) {
        let size = description.dimensions
        self.init(width: size.width, height: size.height, pixelFormat: description.mediaSubType.rawValue)
    }

    var description: String { "\(width)×\(height)" }
}

/// Vaux Camera as Vaux sees it, through the CoreMediaIO C API: whether
/// it's running, whether an app is watching it and in what format, and its
/// sink to feed.
@MainActor @Observable
final class CameraDevice {
    /// Feeds the sink of the Vaux Camera running now; nil while it isn't.
    /// A new one each time the extension starts (an update restarts it).
    private(set) var sink: SinkConnection?
    /// The format an app watching Vaux Camera chose; nil while none is.
    /// Read from the stream rather than assumed, so Vaux works with
    /// whichever extension build is installed.
    private(set) var watchedFormat: FrameFormat?
    /// Vaux Camera isn't showing up for this process: it went away (the
    /// extension restarted) or hasn't appeared. A running process never sees
    /// it come back, so Vaux has to relaunch.
    private(set) var isLost = false

    @ObservationIgnored private var device = CMIOObjectID(kCMIOObjectUnknown)
    /// The stream apps watch; its format is the one they chose.
    @ObservationIgnored private var videoStream = CMIOObjectID(kCMIOObjectUnknown)
    /// Polls in a row without the device.
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var devicesListener: CMIOPropertyListener?
    @ObservationIgnored private var watchedListener: CMIOPropertyListener?
    @ObservationIgnored private var formatListener: CMIOPropertyListener?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.imathis.vaux", category: "device")

    init() {
        devicesListener = CMIOPropertyListener(
            objectID: CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.find(from: "listener") }
        }
        find(from: "start")
        // Every 2 s: rereads watched, backing up its listener (whether the
        // listener alone is enough is a spike question; the log says which
        // saw a change), and gives up on a device that doesn't show.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard device == CMIOObjectID(kCMIOObjectUnknown) else {
            readWatched(from: "poll")
            return
        }
        find(from: "poll")
        guard device == CMIOObjectID(kCMIOObjectUnknown) else { return }
        misses += 1
        if misses >= 3, !isLost {
            log.notice("Vaux Camera hasn't shown up; Vaux needs a relaunch")
            isLost = true
        }
    }

    private func find(from source: String) {
        let found = CMIO.objects(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), of: CMIOObjectID(kCMIOObjectSystemObject))
            .first { CMIO.string(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID), of: $0) == CameraSpec.deviceID.uuidString }
            ?? CMIOObjectID(kCMIOObjectUnknown)
        guard found != device else { return }
        sink?.stop()
        sink = nil
        watchedListener = nil
        formatListener = nil
        device = found
        videoStream = CMIOObjectID(kCMIOObjectUnknown)
        guard found != CMIOObjectID(kCMIOObjectUnknown) else {
            log.notice("Vaux Camera is gone")
            watchedFormat = nil
            isLost = true
            return
        }
        misses = 0
        isLost = false
        // The sink is the device's output stream (direction 0); the video apps
        // read is, from the device's side, an input (1).
        let streams = CMIO.objects(CMIOObjectPropertySelector(kCMIODevicePropertyStreams), of: found)
        let direction = CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)
        guard let stream = streams.first(where: { CMIO.uint32(direction, of: $0) == 0 }),
              let video = streams.first(where: { CMIO.uint32(direction, of: $0) == 1 })
        else {
            log.error("Vaux Camera is missing a stream (\(streams.count) streams)")
            return
        }
        log.notice("Found Vaux Camera: device \(found), sink \(stream), seen by \(source, privacy: .public)")
        sink = SinkConnection(device: found, stream: stream)
        videoStream = video
        watchedListener = CMIOPropertyListener(objectID: found, selector: CameraSpec.watchedSelector) { [weak self] in
            MainActor.assumeIsolated { self?.readWatched(from: "listener") }
        }
        formatListener = CMIOPropertyListener(objectID: video, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription)) { [weak self] in
            MainActor.assumeIsolated { self?.readWatched(from: "format listener") }
        }
        readWatched(from: "start")
    }

    private func readWatched(from source: String) {
        guard device != CMIOObjectID(kCMIOObjectUnknown) else { return }
        let watched = CMIO.string(CameraSpec.watchedSelector, of: device) == "1"
        let format = watched ? (CMIO.formatDescription(of: videoStream).map(FrameFormat.init) ?? .original) : nil
        guard format != watchedFormat else { return }
        log.notice("Watched: \(format?.description ?? "no", privacy: .public), seen by \(source, privacy: .public)")
        watchedFormat = format
    }
}

/// Feeds one Vaux Camera device's sink stream. Frames go in from the video
/// queue; start and stop come from elsewhere.
final class SinkConnection: @unchecked Sendable {
    private let device: CMIODeviceID
    private let stream: CMIOStreamID
    private let lock = NSLock()
    private var queue: CMSimpleQueue?
    private var format: CMFormatDescription?
    private let log = Logger(subsystem: "dev.imathis.vaux", category: "sink")

    init(device: CMIODeviceID, stream: CMIOStreamID) {
        self.device = device
        self.stream = stream
    }

    func start() {
        lock.withLock {
            guard queue == nil else { return }
            var unmanaged: Unmanaged<CMSimpleQueue>?
            let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanaged)
            guard status == noErr, let copied = unmanaged?.takeRetainedValue() else {
                log.error("No sink queue: \(status)")
                return
            }
            let started = CMIODeviceStartStream(device, stream)
            guard started == noErr else {
                log.error("Sink didn't start: \(started)")
                return
            }
            queue = copied
            log.notice("Sink started")
        }
    }

    func stop() {
        lock.withLock {
            guard queue != nil else { return }
            CMIODeviceStopStream(device, stream)
            queue = nil
            log.notice("Sink stopped")
        }
    }

    /// Hands a frame to Vaux Camera. False if it was dropped: not started,
    /// or Vaux Camera is behind (a late frame is better dropped).
    func enqueue(_ frame: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        lock.withLock {
            guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return false }
            if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame) }) ?? true {
                format = nil
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &format)
            }
            guard let format else { return false }
            var timing = CMSampleTimingInfo(duration: CameraSpec.frameDuration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sample
            ) == noErr, let sample else { return false }
            // The queue holds a reference until Vaux Camera takes the frame.
            let element = Unmanaged.passRetained(sample).toOpaque()
            guard CMSimpleQueueEnqueue(queue, element: element) == noErr else {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
                return false
            }
            return true
        }
    }
}

/// A CoreMediaIO property listener, called on the main queue; removed when
/// released.
final class CMIOPropertyListener {
    private let objectID: CMIOObjectID
    private var address: CMIOObjectPropertyAddress
    private let block: CMIOObjectPropertyListenerBlock

    init?(objectID: CMIOObjectID, selector: CMIOObjectPropertySelector, handler: @escaping @Sendable () -> Void) {
        self.objectID = objectID
        self.address = CMIO.address(selector)
        self.block = { _, _ in handler() }
        guard CMIOObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        CMIOObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}

/// CoreMediaIO property reads.
enum CMIO {
    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    /// A list of object IDs: devices, streams.
    static func objects(_ selector: CMIOObjectPropertySelector, of object: CMIOObjectID) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func string(_ selector: CMIOObjectPropertySelector, of object: CMIOObjectID) -> String? {
        var addr = address(selector)
        // Copied out: the caller owns (and here releases) the string.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func formatDescription(of stream: CMIOStreamID) -> CMFormatDescription? {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
        var value: Unmanaged<CMFormatDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size)
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, size, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    static func uint32(_ selector: CMIOObjectPropertySelector, of object: CMIOObjectID) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &size, &value) == noErr else { return nil }
        return value
    }
}
