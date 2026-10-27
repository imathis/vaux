import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Vaux Camera: turning it on; then a line saying whether it's working,
/// with Turn Off beside it, cards only when there's something to do, and
/// the cameras with their zoom.
struct CameraSettings: View {
    let camera: VauxCamera

    @State private var confirmingTurnOff = false

    var body: some View {
        Form {
            if let installer = camera.installer {
                Section {
                    CameraStatusLine(camera: camera, installer: installer) { confirmingTurnOff = true }
                    CameraAttention(installer: installer, side: camera.side)
                    if camera.turnOffFailed {
                        Text("\(CameraSpec.name) is still installed. Try again, or remove it in System Settings → General → Login Items & Extensions → Camera Extensions.")
                            .foregroundStyle(.orange)
                            .wraps()
                    }
                }
                if installer.state == .ready, let side = camera.side, side.access.isAuthorized {
                    Section {
                        CameraList(cameras: side.priority, feeder: side.feeder)
                        // Its panel lists only apps using a camera.
                        if case .sending = side.feeder.status {
                            SystemEffectsRow(effects: side.feeder.systemEffects)
                        }
                    } header: {
                        SettingsHeader("Cameras", "\(VauxCamera.appName) sends the highest-ranked camera that's connected. Drag to reorder.")
                    }
                }
                #if DEBUG
                Diagnostics(installer: installer, feeder: camera.side?.feeder)
                #endif
            } else {
                Section {
                    TurnOnView(camera: camera)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsHeader.pageWidth)
        .confirmationDialog("Turn off \(CameraSpec.name)?", isPresented: $confirmingTurnOff) {
            Button("Turn Off Camera", role: .destructive) { camera.turnOff() }
        } message: {
            Text("Video apps lose \(CameraSpec.name), and \(VauxCamera.appName) reopens. Your effects and camera order are kept for next time.")
        }
    }
}

/// Whether Vaux Camera is working, in a line, and Turn Off.
private struct CameraStatusLine: View {
    let camera: VauxCamera
    let installer: ExtensionInstaller
    let turnOff: () -> Void

    var body: some View {
        let (text, tint) = status
        HStack(spacing: 10) {
            Image(systemName: "video.fill")
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(CameraSpec.name).font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .wraps()
            }
            .help("A video app that was already open may need reopening to list \(CameraSpec.name).")
            Spacer(minLength: 8)
            if camera.turningOff || installer.isBusy { ProgressView().controlSize(.small) }
            Button("Turn Off…", action: turnOff)
                .disabled(camera.turningOff)
        }
        .padding(.vertical, 2)
    }

    /// What's happening, and its color: red while an app is using it (like
    /// a camera's light), green when ready, orange when it needs you.
    private var status: (String, Color) {
        switch installer.state {
        case .checking: return ("Checking…", .secondary)
        case .working(let message): return (message, .secondary)
        case .notInstalled: return ("Not installed", .orange)
        case .awaitingApproval: return ("Waiting for your approval", .orange)
        case .disabled: return ("Turned off in System Settings", .orange)
        case .restartNeeded: return ("Restart your Mac to finish", .orange)
        case .failed: return ("Couldn't install", .red)
        case .ready: break
        }
        guard let side = camera.side else { return ("Starting…", .secondary) }
        guard side.access.isAuthorized else { return ("Needs camera access", .orange) }
        return switch side.feeder.status {
        case .sending(let source, _): ("In use: sending \(source.name)", .red)
        case .standingBy: ("Ready. Choose \(CameraSpec.name) in your video app.", .green)
        case .noCamera: ("No camera connected", .orange)
        case .waitingForDevice, .notReady: ("Starting…", .secondary)
        case .needsRelaunch: ("Needs a relaunch", .orange)
        }
    }
}

/// The one thing to do, when there is one: approve, install, update, allow
/// camera access, relaunch.
private struct CameraAttention: View {
    let installer: ExtensionInstaller
    let side: CameraSide?

    var body: some View {
        CameraStatusView(installer: installer)
        if installer.state == .ready, let side {
            if !side.access.isAuthorized {
                CameraAccessView(access: side.access)
            } else if side.feeder.status == .needsRelaunch {
                StatusRow(
                    symbol: "arrow.clockwise.circle.fill",
                    tint: .orange,
                    title: "Relaunch \(VauxCamera.appName) to reconnect",
                    detail: "\(CameraSpec.name) restarted, and macOS only shows it again to apps opened afterward. Video apps that were already open need reopening too.",
                    action: .init(title: "Relaunch \(VauxCamera.appName)") { VauxCamera.relaunch(continuingSetup: false) }
                )
            }
        }
    }
}

#if DEBUG
/// For development: what's being sent and how well, and the extension's
/// builds.
private struct Diagnostics: View {
    let installer: ExtensionInstaller
    let feeder: Feeder?

    var body: some View {
        Section {
            if let feeder, case .sending(_, let format) = feeder.status {
                LabeledContent("Sending", value: "\(format)\(feeder.zoom > 1 ? " at \(feeder.zoom.zoomText)" : "")")
                LabeledContent("Frame rate", value: "\(feeder.stats.fps) fps, \(feeder.stats.dropped) dropped")
                LabeledContent("Capture to \(CameraSpec.name)", value: "\(feeder.stats.latencyMS.formatted(.number.precision(.fractionLength(1)))) ms")
            }
            LabeledContent("\(CameraSpec.name) in this app", value: ExtensionInstaller.bundledBuild)
            LabeledContent("Installed", value: installer.installedBuild ?? "None")
        } header: {
            SettingsHeader("Diagnostics", "Development builds only.")
        }
    }
}
#endif

/// The camera, before it's on: what it is, what turning it on does.
private struct TurnOnView: View {
    let camera: VauxCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(CameraSpec.name).font(.headline)
            } icon: {
                Image(systemName: "video").foregroundStyle(Color.accentColor)
            }
            Text("A camera for your video calls: your real camera, with overlays and push-ins on your keys, and a sign while you dictate so nobody wonders why you're talking but muted.")
                .wraps()
            Text("Turning it on installs \(CameraSpec.name), which macOS asks you to approve in System Settings, then asks for camera access. Your camera turns on only while an app is using \(CameraSpec.name).")
                .foregroundStyle(.secondary)
                .wraps()
            Button("Turn On Camera") { camera.turnOn() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}

extension View {
    /// Lets text wrap to the width it's given. Without it, a long line in a
    /// form asks for its full length and widens the whole form past the
    /// window.
    func wraps() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// A status: icon, title, detail, and the one thing to do next.
private struct StatusRow: View {
    struct Action {
        let title: String
        var disabled = false
        let run: () -> Void
    }

    var busy = false
    var symbol = "circle"
    var tint: Color = .secondary
    let title: String
    var detail: String?
    var action: Action?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(tint).font(.title2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(.borderedProminent)
                        .disabled(action.disabled)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

/// Setup, when it needs you: install, approve, turn back on, update,
/// restart, try again. Nothing while it's ready or busy (the status line
/// says so).
private struct CameraStatusView: View {
    let installer: ExtensionInstaller

    var body: some View {
        switch installer.state {
        case .checking, .working:
            EmptyView()
        case .notInstalled:
            StatusRow(
                symbol: "camera",
                title: "Not installed",
                detail: ExtensionInstaller.isInApplications
                    ? "Install \(CameraSpec.name) so video apps can use it. macOS asks you to approve it in System Settings."
                    : "\(VauxCamera.appName) has to be in the Applications folder to install its camera. Move it there and open it again.",
                action: .init(title: "Install \(CameraSpec.name)", disabled: !ExtensionInstaller.isInApplications) { installer.install() }
            )
        case .awaitingApproval:
            StatusRow(
                symbol: "exclamationmark.circle.fill",
                tint: .orange,
                title: "Waiting for your approval",
                detail: "In System Settings, under Camera Extensions, turn on \(VauxCamera.appName).",
                action: openSettings
            )
        case .disabled:
            StatusRow(
                symbol: "pause.circle.fill",
                tint: .orange,
                title: "Turned off",
                detail: "\(CameraSpec.name) is turned off. Turn \(VauxCamera.appName) on under Camera Extensions in System Settings.",
                action: openSettings
            )
        case .ready:
            if installer.needsUpdate {
                StatusRow(
                    symbol: "arrow.down.circle.fill",
                    tint: .accentColor,
                    title: "\(CameraSpec.name) update",
                    detail: "Updating restarts \(CameraSpec.name), so video apps that are open lose it until you reopen them. Best done between calls. \(VauxCamera.appName) reopens itself after.",
                    action: .init(title: "Update \(CameraSpec.name)") { installer.install() }
                )
            }
        case .restartNeeded:
            StatusRow(
                symbol: "arrow.clockwise.circle.fill",
                tint: .orange,
                title: "Restart to finish",
                detail: "macOS finishes this change after you restart your Mac."
            )
        case .failed(let message):
            StatusRow(
                symbol: "xmark.octagon.fill",
                tint: .red,
                title: "Couldn't install \(CameraSpec.name)",
                detail: message,
                action: .init(title: "Try Again") { installer.install() }
            )
        }
    }

    // An older build waiting for approval is replaced first; that asks for
    // approval again and opens System Settings.
    private var openSettings: StatusRow.Action {
        .init(title: "Open System Settings") {
            if installer.needsUpdate { installer.install() } else { installer.openSettings() }
        }
    }
}

/// Asks for camera access, or leads back to it once it's been turned down.
private struct CameraAccessView: View {
    let access: CameraAccess

    var body: some View {
        switch access.status {
        case .denied:
            StatusRow(
                symbol: "video.slash.fill",
                tint: .orange,
                title: "Camera access is off",
                detail: "\(VauxCamera.appName) needs your camera to send it through \(CameraSpec.name). Turn on \(VauxCamera.appName) in System Settings → Privacy & Security → Camera.",
                action: .init(title: "Open System Settings") { access.openSettings() }
            )
        case .restricted:
            StatusRow(
                symbol: "video.slash.fill",
                tint: .orange,
                title: "Camera access is restricted",
                detail: "This Mac's settings, possibly a management profile, don't allow \(VauxCamera.appName) to use the camera."
            )
        default:
            StatusRow(
                symbol: "video.fill",
                tint: .accentColor,
                title: "Allow camera access",
                detail: "\(VauxCamera.appName) sends your camera through \(CameraSpec.name). It only turns the camera on while an app is using \(CameraSpec.name).",
                action: .init(title: "Allow Camera Access") { access.request() }
            )
        }
    }
}

/// The camera priority list, like the preferred inputs.
private struct CameraList: View {
    @Bindable var cameras: CameraPriorityModel
    let feeder: Feeder

    private let rowHeight: CGFloat = 36

    var body: some View {
        if cameras.entries.isEmpty {
            Text("No cameras connected.")
                .foregroundStyle(.secondary)
        } else {
            List {
                ForEach(cameras.entries) { entry in
                    CameraRow(
                        entry: entry,
                        connected: cameras.isConnected(entry),
                        docked: cameras.dockedCamera?.uid == entry.uid,
                        live: isLive(entry),
                        zoom: cameras.zoom(for: entry.uid)
                    ) { cameras.setZoom($0, for: entry) }
                        .frame(height: 22)
                        .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                        .contextMenu {
                            if !cameras.isConnected(entry) {
                                Button("Forget \(entry.name)") { cameras.forget(entry) }
                            }
                        }
                }
                .onMove(perform: cameras.move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(min(cameras.entries.count, 8)) * rowHeight)
        }
        Toggle(isOn: $cameras.followsDocking) {
            Text("Use iPhone when it's set up as a camera")
            Text("Propped up in landscape and locked, it goes ahead of this list until you pick it up.")
                .wraps()
        }
    }

    private func isLive(_ entry: CameraEntry) -> Bool {
        if case .sending(let camera, _) = feeder.status { camera.uid == entry.uid } else { false }
    }
}

/// A camera row: drag handle, connection dot, name, whether it's a docked
/// iPhone, whether it's the one being sent, and its zoom: a faint control
/// at 1×, its level when zoomed. Either opens a popover to set it.
private struct CameraRow: View {
    let entry: CameraEntry
    let connected: Bool
    let docked: Bool
    let live: Bool
    let zoom: Double
    let setZoom: @MainActor @Sendable (Double) -> Void

    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(entry.name)
                .foregroundStyle(connected ? .primary : .secondary)
            Spacer()
            if docked {
                Text("docked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if live {
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            } else if !connected {
                Text("disconnected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button { editing = true } label: {
                // A fixed, fully hittable target either way; the popover
                // points at the icon or pill.
                zoomLabel
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        ZoomPopover(entry: entry, connected: connected, zoom: zoom, setZoom: setZoom)
                    }
                    .frame(width: 48, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom for this camera")
        }
    }

    @ViewBuilder private var zoomLabel: some View {
        if zoom > 1 {
            Text(zoom.zoomText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        } else {
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.tertiary)
        }
    }
}

/// Sets a camera's zoom, and says how far it stays sharp.
private struct ZoomPopover: View {
    let entry: CameraEntry
    let connected: Bool
    let zoom: Double
    let setZoom: @MainActor @Sendable (Double) -> Void

    @State private var sharp: (hd: Double, fullHD: Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zoom")
                .font(.headline)
            Text(entry.name)
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: Binding(get: { zoom }, set: setZoom), in: CameraZoom.range, step: 0.05)
                Text(zoom.zoomText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            if let sharp {
                Text("Stays sharp up to \(sharp.hd.zoomText) at 720p and \(sharp.fullHD.zoomText) at 1080p. Past that, the camera's picture is scaled up and a little softer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Reset to 1×") { setZoom(1) }
                .disabled(zoom <= 1)
        }
        .frame(width: 300, alignment: .leading)
        .padding(16)
        .task {
            guard connected else { return }
            sharp = (
                CameraFeed.sharpZoom(cameraID: entry.uid, for: .hd),
                CameraFeed.sharpZoom(cameraID: entry.uid, for: .fullHD)
            )
        }
    }
}


/// macOS's video effects as they apply to Vaux's camera, and the way to
/// change them. Only open while Vaux is using a camera: the panel lists
/// apps that are.
struct SystemEffectsRow: View {
    let effects: [String]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Video effects")
                Text("Set them for \(VauxCamera.appName), not your call app, so overlays stay sharp.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .wraps()
            }
            Spacer(minLength: 8)
            Text(effects.isEmpty ? "Off" : effects.joined(separator: ", "))
                .foregroundStyle(.secondary)
            Button("Video Effects…") { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
        }
    }
}
