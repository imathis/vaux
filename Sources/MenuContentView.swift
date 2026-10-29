import AppKit
import AVFoundation
import CoreAudio
import KeyboardShortcuts
import os
import SwiftUI

struct MenuInputDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let symbol: String
    let isCurrent: Bool
    let isPreferred: Bool
}

/// The menu contents, drawn as a custom SwiftUI view so we can match the
/// system Control Center menus (grey rounded hover, exact metrics) — which a
/// standard NSMenu (accent-blue highlight) can't do.
struct MenuContentView: View {
    @Bindable var appState: AppState
    let camera: VauxCamera
    let openAbout: () -> Void
    let openSettings: () -> Void
    let dismiss: () -> Void
    let resized: (CGSize) -> Void

    @State private var inputs: [MenuInputDevice] = []
    @State private var volume: Double = 0
    @State private var canSetVolume = false
    @State private var currentDeviceID: AudioDeviceID?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(AppStorageKey.enforcePreferred) private var autoSwitch = false
    /// While the camera is on, the menu has two tabs; it opens on the last.
    @AppStorage(AppStorageKey.menuTab) private var storedTab = Tab.devices
    /// Snapshots draw a tab without changing the stored one.
    private let forcedTab: Tab?

    enum Tab: String {
        case devices, effects
    }

    init(appState: AppState, camera: VauxCamera, openAbout: @escaping () -> Void, openSettings: @escaping () -> Void,
         dismiss: @escaping () -> Void, resized: @escaping (CGSize) -> Void, tab: Tab? = nil) {
        _appState = Bindable(wrappedValue: appState)
        self.camera = camera
        forcedTab = tab
        self.openAbout = openAbout
        self.openSettings = openSettings
        self.dismiss = dismiss
        self.resized = resized
        // Seed the slider with the real value so it doesn't animate up from 0.
        let input = Self.currentInput()
        _currentDeviceID = State(initialValue: input.id)
        _canSetVolume = State(initialValue: input.canSetVolume)
        _volume = State(initialValue: input.volume)
    }

    /// The default input and its volume.
    private static func currentInput() -> (id: AudioDeviceID?, canSetVolume: Bool, volume: Double) {
        guard let id = AudioController.defaultInputDevice() else { return (nil, false, 0) }
        return (id, AudioController.canSetInputVolume(id), Double(AudioController.volume(on: id) ?? 0))
    }

    static let width: CGFloat = 308
    private let edgeInset: CGFloat = 5   // hover background inset from the menu edge
    private let contentInset: CGFloat = 14 // text/divider inset from the menu edge

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let effects = camera.effects {
                tabPicker
                if tab == .effects {
                    effectsTab(effects)
                } else {
                    devicesTab
                }
            } else {
                devicesTab
            }
            // Vaux's own actions, whichever tab is showing.
            divider()
            textRow(appState.muted ? "Unmute" : "Mute", trailing: muteShortcut) { appState.toggle() }
            textRow(appState.soloActive ? "End Solo Mode" : "Solo Mode", trailing: nil, trailingSymbol: soloKeySymbol) {
                appState.toggleSolo()
            }
            soloStatus
            divider()
            launchAtLoginRow
            textRow("About Vaux", trailing: nil) { openAbout(); dismiss() }
            textRow("Settings…", trailing: "⌘,") { openSettings(); dismiss() }
            textRow("Quit Vaux", trailing: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { resized($0) }
        .onAppear(perform: reload)
    }

    // MARK: Tabs

    private var tab: Tab { forcedTab ?? storedTab }

    /// Two equal halves across the menu (a segmented picker only takes
    /// its labels' width), in the menu's own grays.
    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach([(Tab.devices, "Devices"), (Tab.effects, "Effects")], id: \.0) { option, title in
                Button { storedTab = option } label: {
                    Text(title)
                        .font(.system(size: 12, weight: tab == option ? .semibold : .regular))
                        .foregroundStyle(tab == option ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == option ? Color.primary.opacity(0.14) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, contentInset)
        .padding(.top, 5)
        .padding(.bottom, 4)
    }

    /// The mic's volume, the mics, and while the camera is on, the cameras.
    @ViewBuilder private var devicesTab: some View {
        header("Volume", color: .primary, trailing: canSetVolume ? nil : "managed by device")
        volumeRow
        divider()
        header("Input", color: .secondary)
        ForEach(inputs) { inputRow($0) }
        autoSwitchRow
        if let side = camera.side, side.access.isAuthorized {
            divider()
            header("Camera", color: .secondary)
            ForEach(side.priority.entries.filter(side.priority.isConnected)) { cameraRow($0, side) }
        }
    }

    /// A camera, in Vaux's ranking: the one it sends is marked, Live while
    /// a video app is using it. Clicking one puts it at the top.
    private func cameraRow(_ entry: CameraEntry, _ side: CameraSide) -> some View {
        let sent = side.priority.preferred?.uid == entry.uid
        let live = if case .sending(let camera, _) = side.feeder.status { camera.uid == entry.uid } else { false }
        return MenuRow(height: 32, edgeInset: edgeInset, contentInset: contentInset) {
            side.priority.makeFirst(entry)
        } content: {
            HStack(spacing: 9) {
                deviceIcon(symbol: Self.cameraSymbol(entry.uid), current: sent)
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                if live {
                    badge("Live", fill: .red, text: .white)
                } else if sent {
                    preferredBadge
                }
            }
        }
    }

    /// The laptop's, an iPhone (which reports itself as external), or a
    /// webcam.
    private static func cameraSymbol(_ uid: String) -> String {
        guard let device = AVCaptureDevice(uniqueID: uid) else { return "web.camera" }
        if device.isContinuityCamera { return "iphone" }
        return device.deviceType == .builtInWideAngleCamera ? "laptopcomputer" : "web.camera"
    }

    // MARK: Sections

    private func header(_ text: String, color: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, contentInset)
        .padding(.top, 5)
        .padding(.bottom, 2)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic").font(.system(size: 14)).foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1)
                .controlSize(.regular)
                .disabled(!canSetVolume)
                .onChange(of: volume) { _, newValue in
                    if let dev = currentDeviceID { VolumeWriter.write(Float(newValue), to: dev) }
                }
            Image(systemName: "mic.fill").font(.system(size: 17)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, contentInset)
        .frame(height: 32)
    }

    private func inputRow(_ device: MenuInputDevice) -> some View {
        MenuRow(height: 32, edgeInset: edgeInset, contentInset: contentInset) {
            select(device)
        } content: {
            HStack(spacing: 9) {
                deviceIcon(symbol: device.symbol, current: device.isCurrent)
                Text(device.name).font(.system(size: 13))
                Spacer(minLength: 6)
                if device.isPreferred, autoSwitch { preferredBadge }
            }
        }
    }

    /// Lives here rather than in Settings: set once, like most menu bar apps.
    private var launchAtLoginRow: some View {
        HStack {
            Text("Launch at Login").font(.system(size: 13))
            Spacer()
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: {
                    launchAtLogin = $0
                    LaunchAtLogin.isEnabled = $0
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, contentInset)
        .frame(height: 26)
    }

    /// Switch to the preferred input as devices come and go (Settings ranks them).
    private var autoSwitchRow: some View {
        HStack {
            Text("Auto Switch").font(.system(size: 13))
            Spacer()
            Toggle("Auto Switch", isOn: $autoSwitch)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, contentInset)
        .frame(height: 26)
    }

    /// `trailingSymbol`: an SF Symbol shown instead of `trailing`, for keys
    /// with no text name (the 🎤 Dictation key).
    private func textRow(_ title: String, trailing: String?, trailingSymbol: String? = nil, action: @escaping () -> Void) -> some View {
        MenuRow(height: 22, edgeInset: edgeInset, contentInset: contentInset, action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let trailingSymbol {
                    Image(systemName: trailingSymbol).font(.system(size: 13)).foregroundStyle(.secondary)
                } else if let trailing, !trailing.isEmpty {
                    Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Live, then your effects, each checked while it's on. Keys live in
    /// the Quick Menu.
    @ViewBuilder private func effectsTab(_ effects: Effects) -> some View {
        let items = effects.triggers.items
        let list = items.filter { if case .effect = $0.action { true } else { false } }
        let live = items.first { $0.action == .live }
        cameraHeader(anythingOn: effects.library.anythingOn) { effects.library.clearAll() }
        if let live {
            effectRow(live) {
                dismiss()
                effects.live.show()
            }
        }
        effectList("Effects", list, effects)
    }

    /// Camera, its state, and Clear while effects are on.
    private func cameraHeader(anythingOn: Bool, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
                Text("Camera").font(.system(size: 13, weight: .semibold))
                Text(cameraStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if anythingOn {
                    Button(action: clear) {
                        Text("Clear")
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    }
                    .buttonStyle(.plain)
                    .help("Turn every effect off")
                }
        }
        .padding(.horizontal, contentInset)
        .frame(height: 26)
    }

    /// A titled list of effects, checked while on, each group's under its
    /// name and set off from what follows.
    @ViewBuilder private func effectList(_ title: String, _ items: [Triggers.Item], _ effects: Effects) -> some View {
        if !items.isEmpty {
            let starts = items.groupStarts
            let ends = items.groupEnds
            if items.first?.group == nil { subheader(title) }
            ForEach(items) { item in
                if ends.contains(item.id) { divider() }
                if let group = starts[item.id] { subheader(group.name) }
                effectRow(item) { effects.triggers.trigger(item.action) }
            }
        }
    }

    /// An effect, checked while it's on.
    private func effectRow(_ item: Triggers.Item, action: @escaping () -> Void) -> some View {
        MenuRow(height: 22, edgeInset: edgeInset, contentInset: contentInset, action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(item.isOn ? 1 : 0)
                    .frame(width: 14)
                Text(item.title).font(.system(size: 13)).lineLimit(1)
            }
        }
    }

    private func subheader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, contentInset)
            .padding(.top, 4)
            .padding(.bottom, 1)
    }

    /// The camera's state, in a word or two.
    private var cameraStatus: String {
        switch camera.installer?.state {
        case .ready: break
        case .awaitingApproval: return "Needs your approval"
        case .disabled: return "Turned off in System Settings"
        case .failed: return "Couldn't install"
        case .restartNeeded: return "Restart to finish"
        default: return "Setting up"
        }
        guard let side = camera.side else { return "Starting…" }
        guard side.access.isAuthorized else { return "Needs camera access" }
        return switch side.feeder.status {
        case .notReady: "Setting up"
        case .noCamera: "No camera connected"
        case .waitingForDevice: "Starting…"
        case .needsRelaunch: "Needs a relaunch"
        case .standingBy: "Standing by"
        case .sending(let source, _): "Live: \(source.name)"
        }
    }

    /// What solo is doing (or what went wrong), under the Solo row.
    @ViewBuilder private var soloStatus: some View {
        let lines = soloStatusLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i].text)
                        .font(.system(size: 11))
                        .foregroundStyle(lines[i].warning ? Color.orange : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, contentInset)
            .padding(.bottom, 3)
        }
    }

    private var soloStatusLines: [(text: String, warning: Bool)] {
        var lines: [(text: String, warning: Bool)] = []
        if appState.soloBusy {
            lines.append((appState.soloActive ? "Unmuting calls…" : "Muting calls…", false))
        } else if appState.soloActive {
            var parts = [appState.soloMutedApps.isEmpty
                ? "No calls to mute"
                : "Muted in " + appState.soloMutedApps.joined(separator: ", ")]
            if let ducked = appState.soloDuckedTo {
                parts.append("speakers at \(ducked.percentText)")
            }
            lines.append((parts.joined(separator: " · "), false))
        }
        return lines + appState.soloProblems.map { ($0, true) }
    }

    /// A mic's or camera's icon, filled in for the one in use.
    private func deviceIcon(symbol: String, current: Bool) -> some View {
        ZStack {
            Circle()
                .fill(current ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(current ? Color.white : Color(nsColor: .secondaryLabelColor))
                .frame(width: 19, height: 19)
        }
        .frame(width: 26, height: 26)
    }

    private var preferredBadge: some View {
        badge("Preferred", fill: Color(nsColor: .quaternaryLabelColor), text: .secondary)
    }

    private func badge(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: title == "Live" ? .semibold : .regular))
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
    }

    private func divider() -> some View {
        Divider().padding(.horizontal, contentInset).padding(.vertical, 4)
    }

    // MARK: Data + actions

    private var muteShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleMicMute)?.description ?? ""
    }

    /// The 🎤 key starts solo when you dictate with macOS Dictation.
    private var soloKeySymbol: String? {
        UserDefaults.standard.string(forKey: AppStorageKey.dictateWith) == AppStorageKey.macOSDictation ? "mic" : nil
    }

    private func select(_ device: MenuInputDevice) {
        appState.selectInput(device.id)
        reload()
    }

    private func reload() {
        // Changed in System Settings → Login Items meanwhile, maybe.
        launchAtLogin = LaunchAtLogin.isEnabled
        let all = AudioController.inputDevices()
        let input = Self.currentInput()
        let order = PreferredInput.order
        let preferredID = PreferredInput.preferred(among: all, in: order, uid: \.uid)?.id
        // Order the menu like the priority list: ranked devices first (in
        // priority order), then any others in their natural order.
        let ranked = all.enumerated().sorted { lhs, rhs in
            let r1 = order.firstIndex { $0.uid == lhs.element.uid } ?? Int.max
            let r2 = order.firstIndex { $0.uid == rhs.element.uid } ?? Int.max
            return r1 == r2 ? lhs.offset < rhs.offset : r1 < r2
        }.map(\.element)
        inputs = ranked.map { device in
            MenuInputDevice(
                id: device.id,
                name: device.name,
                symbol: AudioController.inputSymbolName(device.id, name: device.name),
                isCurrent: device.id == input.id,
                isPreferred: device.id == preferredID)
        }
        currentDeviceID = input.id
        canSetVolume = input.canSetVolume
        if input.id != nil { volume = input.volume }
    }
}

/// An interactive menu row with the system's grey rounded hover background.
private struct MenuRow<Content: View>: View {
    let height: CGFloat
    let edgeInset: CGFloat
    let contentInset: CGFloat
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, contentInset)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous) // squircle, like the system
                    .fill(hovering ? Color.primary.opacity(0.09) : .clear) // translucent over the glass
                    .padding(.horizontal, edgeInset)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// Serializes input-volume writes off the main thread so dragging stays smooth.
/// Only the latest value is written: a drag sends far more than the device
/// needs, and each write notifies every audio client.
enum VolumeWriter {
    private static let queue = DispatchQueue(label: "dev.imathis.vaux.volume")
    private static let latest = OSAllocatedUnfairLock<(value: Float, device: AudioDeviceID)?>(initialState: nil)

    static func write(_ value: Float, to device: AudioDeviceID) {
        let idle = latest.withLock { pending in defer { pending = (value, device) }; return pending == nil }
        guard idle else { return }
        queue.async {
            guard let next = latest.withLock({ pending in defer { pending = nil }; return pending }) else { return }
            AudioController.setVolume(next.value, on: next.device)
        }
    }
}
