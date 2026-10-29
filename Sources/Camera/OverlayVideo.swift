import AppKit
import AVFoundation
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

/// A graphic that moves: a movie (MOV, MP4) or an animated GIF, playing
/// from its start when its effect comes on, round and round. A movie with
/// an alpha channel (HEVC with alpha, ProRes 4444) keeps its transparency,
/// as a GIF does. No sound: Vaux Camera is video only.
///
/// Made on the main actor; `frame()` is read on the camera's video queue,
/// each frame, and nowhere else.
final class OverlayVideo: @unchecked Sendable {
    /// Where it goes and how it's sized, as a still graphic would be.
    let spot: Overlay.Spot
    let size: Overlay.Size
    let fit: Overlay.Fit

    private enum Source {
        case movie(AVPlayer, AVPlayerItemVideoOutput)
        case gif(CGImageSource, delays: [Double])
    }

    private let source: Source
    private let started = CACurrentMediaTime()
    private var looping: NSObjectProtocol?
    /// The frame showing, kept until there's a newer one.
    private var last: CIImage?
    private var lastGIFFrame = -1

    @MainActor
    init?(_ name: String, overlay: Overlay) {
        let url = EffectLibrary.graphicsFolder.appending(path: name)
        spot = overlay.spot
        size = overlay.size
        fit = overlay.fit
        if Self.isGIF(name) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 else { return nil }
            self.source = .gif(source, delays: Self.delays(of: source))
        } else {
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .none
            source = .movie(player, output)
            // Round and round.
            looping = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
            }
            player.play()
        }
    }

    deinit {
        if let looping { NotificationCenter.default.removeObserver(looping) }
        if case .movie(let player, _) = source {
            DispatchQueue.main.async { player.pause() }
        }
    }

    /// The frame to show now, or none before the first is ready.
    func frame() -> CIImage? {
        switch source {
        case .movie(_, let output):
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                last = CIImage(cvPixelBuffer: buffer)
            }
        case .gif(let source, let delays):
            let index = Self.index(at: CACurrentMediaTime() - started, delays: delays)
            if index != lastGIFFrame, let image = CGImageSourceCreateImageAtIndex(source, index, nil) {
                last = CIImage(cgImage: image)
                lastGIFFrame = index
            }
        }
        return last
    }

    // MARK: Telling them apart

    /// A movie, or a GIF with more than one frame. Read once each.
    @MainActor
    static func isVideo(_ name: String) -> Bool {
        if let known = videos[name] { return known }
        let url = EffectLibrary.graphicsFolder.appending(path: name)
        let video = isMovie(name) || isGIF(name) && (CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) > 1 } ?? false)
        videos[name] = video
        return video
    }

    @MainActor private static var videos: [String: Bool] = [:]

    /// A movie file, not a GIF; read with AVFoundation.
    static func isMovie(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) ?? false
    }

    static func isGIF(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .gif) ?? false
    }

    // MARK: GIFs

    /// Each frame's time on screen, as the GIF says (a tenth of a second
    /// for ones that say less than a fiftieth, as browsers do).
    static func delays(of source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return delay < 0.02 ? 0.1 : delay
        }
    }

    private static func index(at elapsed: Double, delays: [Double]) -> Int {
        let total = delays.reduce(0, +)
        guard total > 0 else { return 0 }
        var time = elapsed.truncatingRemainder(dividingBy: total)
        for (index, delay) in delays.enumerated() {
            if time < delay { return index }
            time -= delay
        }
        return delays.count - 1
    }
}

/// Videos' first frames and lengths, for the editor: read in the background,
/// once each, and shown when they're in.
@MainActor @Observable
final class VideoPosters {
    static let shared = VideoPosters()

    struct Poster {
        let image: NSImage
        let seconds: Double
    }

    private(set) var posters: [String: Poster] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// Its first frame and length, or none until they're read.
    func poster(_ name: String) -> Poster? {
        if let poster = posters[name] { return poster }
        load(name)
        return nil
    }

    private func load(_ name: String) {
        guard loading.insert(name).inserted else { return }
        let url = EffectLibrary.graphicsFolder.appending(path: name)
        Task {
            if let poster = await Self.read(url) { posters[name] = poster }
        }
    }

    private nonisolated static func read(_ url: URL) async -> Poster? {
        if OverlayVideo.isGIF(url.lastPathComponent) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return Poster(image: NSImage(cgImage: first, size: .zero), seconds: OverlayVideo.delays(of: source).reduce(0, +))
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let duration = try? await asset.load(.duration), let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return Poster(image: NSImage(cgImage: image, size: .zero), seconds: duration.seconds)
    }
}
