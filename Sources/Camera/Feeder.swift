import AVFoundation
import Observation

/// Decides when Vaux runs a camera, which, and how. While Vaux Camera is
/// installed, camera access is allowed, and an app is watching, it sends the
/// highest-ranked connected camera at its zoom, with the overlays showing;
/// otherwise the camera is off.
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
    /// The zoom being sent: the camera's own, times a zoom shortcut's.
    private(set) var zoom = 1.0

    @ObservationIgnored private let installer: ExtensionInstaller
    @ObservationIgnored private let access: CameraAccess
    @ObservationIgnored private let cameras: CameraPriorityModel
    @ObservationIgnored private let device: CameraDevice
    @ObservationIgnored private let overlays: OverlayLibrary
    @ObservationIgnored private let zoomShortcuts: ZoomShortcuts
    @ObservationIgnored private let looks: LookLibrary
    @ObservationIgnored private var feed: CameraFeed!
    /// What the feed is running now.
    @ObservationIgnored private var feeding: Feeding?

    private struct Feeding {
        let camera: String
        let format: FrameFormat
        let sink: SinkConnection
        var zoom: Double
        var modeZoom: Double
        var shortcut: UUID?
    }

    private struct Wanted {
        let status: Status
        let zoom: Double
        /// The furthest zoom shortcuts can push this camera; its mode keeps
        /// that sharp.
        let modeZoom: Double
        let shortcut: UUID?
        let overlays: [OverlayLayer]
        let look: Look?
    }

    init(
        installer: ExtensionInstaller,
        access: CameraAccess,
        cameras: CameraPriorityModel,
        device: CameraDevice,
        overlays: OverlayLibrary,
        zoomShortcuts: ZoomShortcuts,
        looks: LookLibrary
    ) {
        self.installer = installer
        self.access = access
        self.cameras = cameras
        self.device = device
        self.overlays = overlays
        self.zoomShortcuts = zoomShortcuts
        self.looks = looks
        feed = CameraFeed { [weak self] stats in
            self?.stats = stats
            self?.readSystemEffects()
        }
        observe()
    }

    private func observe() {
        let wanted = withObservationTracking { self.wanted } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(wanted)
    }

    private var wanted: Wanted {
        let status = wantedStatus
        let base = if case .sending(let camera, _) = status { cameras.zoom(for: camera.uid) } else { 1.0 }
        let most = CameraZoom.range.upperBound
        return Wanted(
            status: status,
            zoom: min(base * zoomShortcuts.factor, most),
            modeZoom: min(base * zoomShortcuts.furthest, most),
            shortcut: zoomShortcuts.active,
            overlays: overlays.scene,
            look: looks.activeLook
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
        zoom = wanted.zoom
        feed.showOverlays(wanted.overlays)
        feed.showLook(wanted.look)
        if case .sending(let camera, let format) = wanted.status, let sink = device.sink {
            if let feeding, feeding.camera == camera.uid, feeding.format == format, feeding.sink === sink {
                // Same camera, same format: only the zoom may have moved. A
                // shortcut pushes in or out smoothly; the slider moves at once.
                if feeding.zoom != wanted.zoom {
                    feed.setZoom(wanted.zoom, animated: feeding.shortcut != wanted.shortcut)
                }
                if feeding.modeZoom != wanted.modeZoom {
                    feed.setModeZoom(wanted.modeZoom)
                }
                self.feeding?.zoom = wanted.zoom
                self.feeding?.modeZoom = wanted.modeZoom
                self.feeding?.shortcut = wanted.shortcut
            } else {
                feeding = Feeding(
                    camera: camera.uid, format: format, sink: sink,
                    zoom: wanted.zoom, modeZoom: wanted.modeZoom, shortcut: wanted.shortcut
                )
                feed.start(cameraID: camera.uid, format: format, zoom: wanted.zoom, modeZoom: wanted.modeZoom, sink: sink)
            }
        } else if feeding != nil {
            feeding = nil
            feed.stop()
            // The next call starts at the camera's own zoom.
            zoomShortcuts.reset()
        }
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
