import AVFoundation
import Observation

/// Decides when Vaux runs a camera, which, and how. While Vaux Camera is
/// installed, camera access is allowed, and an app is watching, it sends the
/// highest-ranked connected camera at its zoom, with the overlays showing.
/// While the preview's open, the same camera shows there too, with the
/// preview's effects (just there, when nobody's watching). Otherwise the
/// camera is off.
@MainActor @Observable
final class Feeder {
    enum Status: Equatable {
        /// Setup isn't done: the extension or camera access.
        case notReady
        case noCamera
        /// Approved; the extension is starting.
        case waitingForDevice
        /// Vaux Camera restarted under Vaux, which can't see it again
        /// until it relaunches.
        case needsRelaunch
        /// Nobody's watching Vaux Camera, so the camera is off.
        case standingBy
        /// The camera, in the format the watching app chose.
        case sending(CameraEntry, FrameFormat)
    }

    private(set) var status = Status.notReady
    private(set) var stats = CameraFeed.Stats()
    /// macOS's video effects (Portrait, Studio Light…) on the camera being
    /// sent. They're Vaux's own, set in Control Center's Video Effects, and
    /// apply before overlays are drawn.
    private(set) var systemEffects: [String] = []
    /// The zoom being sent: the camera's own, times the effects' push-in,
    /// and at least what a shake needs.
    private(set) var zoom = 1.0
    /// The preview window's, while it's open.
    var screen: PreviewScreen?
    /// The camera the preview shows, if it's running.
    private(set) var previewing: CameraEntry?
    /// Frames that arrive from the camera broken are skipped (see
    /// BrokenFrame): the call sees the frame before a moment longer.
    var hidesBrokenFrames = UserDefaults.standard.object(forKey: Feeder.hidesBrokenKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hidesBrokenFrames, forKey: Self.hidesBrokenKey)
            feed.hideBrokenFrames(hidesBrokenFrames)
        }
    }

    @ObservationIgnored private let installer: ExtensionInstaller
    @ObservationIgnored private let access: CameraAccess
    @ObservationIgnored private let cameras: CameraPriorityModel
    @ObservationIgnored private let device: CameraDevice
    @ObservationIgnored private let library: EffectLibrary
    @ObservationIgnored private var feed: CameraFeed!
    /// What the feed is running now.
    @ObservationIgnored private var feeding: Feeding?

    private struct Feeding {
        let camera: String
        let format: FrameFormat
        /// None while it runs for the preview alone.
        let sink: SinkConnection?
        var modeZoom: Double
        var call: Zooming
        var preview: Zooming?
    }

    /// An output's zoom, and how it got there.
    private struct Zooming {
        var zoom: Double
        var source: UUID?
        /// How the last effect to push in moved: it moves back out the same
        /// way when it goes.
        var move: Effect.Move
    }

    private struct Wanted {
        let status: Status
        /// The camera to run: the call's, else the preview's.
        let camera: CameraEntry?
        /// The furthest effects can push this camera; its mode keeps that
        /// sharp.
        let modeZoom: Double
        let call: Shown
        /// While the preview's open.
        let preview: Shown?
        let screen: PreviewScreen?
    }

    /// What a stage shows on this camera.
    private struct Shown {
        let zoom: Double
        /// What set the zoom (see EffectStage.zoomSource).
        let zoomSource: UUID?
        let zoomMove: Effect.Move
        let overlays: [OverlayLayer]
        let look: Look?
        let shake: Effect.Shake?
        let shakeBuild: Double?
    }

    init(
        installer: ExtensionInstaller,
        access: CameraAccess,
        cameras: CameraPriorityModel,
        device: CameraDevice,
        library: EffectLibrary
    ) {
        self.installer = installer
        self.access = access
        self.cameras = cameras
        self.device = device
        self.library = library
        feed = CameraFeed { [weak self] stats in
            self?.stats = stats
            self?.readSystemEffects()
        }
        feed.hideBrokenFrames(hidesBrokenFrames)
        observe()
    }

    private func observe() {
        let wanted = withObservationTracking { self.wanted } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(wanted)
    }

    private static let hidesBrokenKey = "hidesBrokenFrames"

    private var wanted: Wanted {
        let status = wantedStatus
        let preview = screen == nil ? nil : library.preview
        var camera: CameraEntry?
        if case .sending(let sending, _) = status {
            camera = sending
        } else if preview != nil, access.isAuthorized {
            camera = cameras.preferred
        }
        let base = camera.map { cameras.zoom(for: $0.uid) } ?? 1
        let most = CameraZoom.range.upperBound
        func shown(_ stage: EffectStage) -> Shown {
            Shown(
                zoom: min(max(base * stage.zoom, stage.shake?.zoom ?? 1), most),
                zoomSource: stage.zoomSource,
                zoomMove: stage.zoomMove,
                overlays: stage.scene,
                look: stage.look,
                shake: stage.shake,
                shakeBuild: stage.shakeBuild
            )
        }
        return Wanted(
            status: status,
            camera: camera,
            modeZoom: min(max(base * library.furthest, library.furthestShake), most),
            call: shown(library.call),
            preview: preview.map(shown),
            screen: preview == nil ? nil : screen
        )
    }

    private var wantedStatus: Status {
        guard installer.state == .ready, access.isAuthorized else { return .notReady }
        guard let camera = cameras.preferred else { return .noCamera }
        guard device.sink != nil else { return device.isLost ? .needsRelaunch : .waitingForDevice }
        guard let format = device.watchedFormat else { return .standingBy }
        return .sending(camera, format)
    }

    private func apply(_ wanted: Wanted) {
        status = wanted.status
        zoom = wanted.call.zoom
        previewing = wanted.preview == nil ? nil : wanted.camera
        feed.showPreview(on: wanted.screen)
        show(wanted.call, on: .call)
        if let preview = wanted.preview { show(preview, on: .preview) }
        let sink: SinkConnection? = if case .sending = wanted.status { device.sink } else { nil }
        let format: FrameFormat? = if case .sending(_, let format) = wanted.status { format } else { nil }
        // A call ended: the next starts at each camera's own zoom.
        if feeding?.sink != nil, sink == nil { library.endCall() }
        guard let camera = wanted.camera else {
            if feeding != nil {
                feeding = nil
                feed.stop()
            }
            return
        }
        // The preview's alone keeps the format the camera's in.
        let running = format ?? feeding?.format ?? .hd
        if var feeding, feeding.camera == camera.uid, feeding.format == running, feeding.sink === sink {
            // Same camera, same format: only the zoom may have moved.
            feeding.call = zoom(.call, from: feeding.call, to: wanted.call)
            feeding.preview = wanted.preview.map { preview in
                feeding.preview.map { zoom(.preview, from: $0, to: preview) } ?? start(.preview, at: preview)
            }
            if feeding.modeZoom != wanted.modeZoom {
                feed.setModeZoom(wanted.modeZoom)
                feeding.modeZoom = wanted.modeZoom
            }
            self.feeding = feeding
        } else {
            feeding = Feeding(
                camera: camera.uid, format: running, sink: sink, modeZoom: wanted.modeZoom,
                call: Zooming(zoom: wanted.call.zoom, source: wanted.call.zoomSource, move: wanted.call.zoomMove),
                preview: wanted.preview.map { start(.preview, at: $0) }
            )
            feed.start(cameraID: camera.uid, format: running, zoom: wanted.call.zoom, modeZoom: wanted.modeZoom, sink: sink)
        }
    }

    private func show(_ shown: Shown, on output: CameraFeed.Output) {
        feed.showOverlays(shown.overlays, on: output)
        feed.showLook(shown.look, on: output)
        feed.showShake(shown.shake, buildingOver: shown.shakeBuild, on: output)
    }

    /// An effect coming on pushes in its way, and back out the same way
    /// when it goes; a slider moves at once.
    private func zoom(_ output: CameraFeed.Output, from was: Zooming, to shown: Shown) -> Zooming {
        if was.zoom != shown.zoom {
            let move = was.source == shown.zoomSource ? nil : shown.zoomSource == nil ? was.move : shown.zoomMove
            feed.setZoom(shown.zoom, moving: move, on: output)
        }
        return Zooming(zoom: shown.zoom, source: shown.zoomSource, move: shown.zoomSource != nil ? shown.zoomMove : was.move)
    }

    /// Where an output starts: at its zoom, at once.
    private func start(_ output: CameraFeed.Output, at shown: Shown) -> Zooming {
        feed.setZoom(shown.zoom, moving: nil, on: output)
        return Zooming(zoom: shown.zoom, source: shown.zoomSource, move: shown.zoomMove)
    }

    /// Read with each second's stats: what Control Center has on for Vaux,
    /// as this camera applies it.
    private func readSystemEffects() {
        guard case .sending(let camera, _) = status, let device = AVCaptureDevice(uniqueID: camera.uid) else {
            if !systemEffects.isEmpty { systemEffects = [] }
            return
        }
        var effects: [String] = []
        if device.isCenterStageActive { effects.append("Center Stage") }
        if device.isPortraitEffectActive { effects.append("Portrait") }
        if device.isStudioLightActive { effects.append("Studio Light") }
        if device.isBackgroundReplacementActive { effects.append("Background") }
        if device.canPerformReactionEffects, AVCaptureDevice.reactionEffectGesturesEnabled { effects.append("Gesture reactions") }
        if effects != systemEffects { systemEffects = effects }
    }
}
