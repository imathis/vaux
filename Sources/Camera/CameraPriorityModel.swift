import AVFoundation
import Observation
import os

/// The camera priority list: the stored order merged with the cameras
/// connected now, kept live. Vaux sends the highest-ranked connected one,
/// or a docked iPhone ahead of them if the user wants that.
@MainActor @Observable
final class CameraPriorityModel {
    private(set) var entries: [CameraEntry] = []
    private(set) var connected: Set<String> = []
    /// macOS lists Vaux Camera: it's approved and running.
    private(set) var listsVauxCamera = false
    /// An iPhone set up as a camera (Continuity Camera: propped up near the
    /// Mac, in landscape, still and locked), per macOS.
    private(set) var dockedCamera: CameraEntry?
    /// Per-camera zoom (see `CameraZoom`).
    private(set) var zooms = CameraZoom.levels
    /// Send a docked iPhone ahead of the ranking, as apps' Automatic Camera
    /// Selection would, but inside Vaux Camera, so apps never switch.
    var followsDocking = UserDefaults.standard.object(forKey: CameraPriorityModel.followsDockingKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(followsDocking, forKey: Self.followsDockingKey) }
    }

    private static let followsDockingKey = "followsDocking"
    @ObservationIgnored private var dockingObserver: SystemPreferredCameraObserver?
    @ObservationIgnored private let log = Logger(subsystem: "dev.imathis.vaux", category: "cameras")

    @ObservationIgnored private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
        mediaType: .video,
        position: .unspecified
    )
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        reload(Self.cameras(discovery.devices))
        observation = discovery.observe(\.devices) { [weak self] session, _ in
            let cameras = Self.cameras(session.devices)
            Task { @MainActor in self?.reload(cameras) }
        }
        dockingObserver = SystemPreferredCameraObserver { [weak self] in
            Task { @MainActor in self?.readDocked() }
        }
        readDocked()
    }

    /// The camera to send: a docked iPhone if following docking, else the
    /// highest-ranked camera that's connected.
    var preferred: CameraEntry? {
        if followsDocking, let dockedCamera, connected.contains(dockedCamera.uid) { return dockedCamera }
        return entries.first { connected.contains($0.uid) }
    }

    /// Vaux never sets its own preferred camera, so macOS's pick for it is
    /// its default until an iPhone is set up as a camera, then that iPhone.
    private func readDocked() {
        let system = AVCaptureDevice.systemPreferredCamera
        let docked = system.flatMap { $0.isContinuityCamera ? CameraEntry(uid: $0.uniqueID, name: $0.localizedName) : nil }
        guard docked != dockedCamera else { return }
        log.notice("Docked: \(docked?.name ?? "none", privacy: .public) (macOS prefers \(system?.localizedName ?? "none", privacy: .public))")
        dockedCamera = docked
    }

    func isConnected(_ entry: CameraEntry) -> Bool { connected.contains(entry.uid) }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        PreferredCamera.order = entries
    }

    /// Puts a camera at the top: Vaux sends it from now on (a docked iPhone
    /// still goes ahead while docking is followed).
    func makeFirst(_ entry: CameraEntry) {
        guard let index = entries.firstIndex(where: { $0.uid == entry.uid }), index > 0 else { return }
        entries.move(fromOffsets: [index], toOffset: 0)
        PreferredCamera.order = entries
    }

    /// Drops a disconnected camera from the list. It's added back, last, if
    /// it connects again.
    func forget(_ entry: CameraEntry) {
        entries.removeAll { $0.uid == entry.uid }
        PreferredCamera.order = entries
    }

    func zoom(for uid: String) -> Double { zooms[uid] ?? 1 }

    /// Zooms a camera in; 1× clears it.
    func setZoom(_ zoom: Double, for entry: CameraEntry) {
        let zoom = min(max(zoom, CameraZoom.range.lowerBound), CameraZoom.range.upperBound)
        zooms[entry.uid] = zoom > 1.001 ? zoom : nil
        CameraZoom.levels = zooms
    }

    private nonisolated static func cameras(_ devices: [AVCaptureDevice]) -> [CameraEntry] {
        devices.map { CameraEntry(uid: $0.uniqueID, name: $0.localizedName) }
    }

    private func reload(_ cameras: [CameraEntry]) {
        let vauxCamera = CameraSpec.deviceID.uuidString
        listsVauxCamera = cameras.contains { $0.uid == vauxCamera }
        // Vaux Camera would feed itself.
        let present = cameras.filter { $0.uid != vauxCamera }
        var stored = PreferredCamera.order
        for camera in present {
            if let index = stored.firstIndex(where: { $0.uid == camera.uid }) {
                stored[index].name = camera.name
            } else {
                stored.append(camera)
            }
        }
        entries = stored
        connected = Set(present.map(\.uid))
        if stored != PreferredCamera.order { PreferredCamera.order = stored }
        readDocked()
    }
}

/// Calls back when macOS's pick of camera changes: it moves to an iPhone as
/// it's set up as a camera, and back when it's picked up. A class property,
/// so observed by key path on the class itself.
private final class SystemPreferredCameraObserver: NSObject {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: nil)
    }

    deinit {
        (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: "systemPreferredCamera")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }
}
