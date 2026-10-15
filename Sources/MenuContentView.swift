import AppKit
import CoreAudio
import KeyboardShortcuts
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
    let openSettings: () -> Void
    let dismiss: () -> Void

    @State private var inputs: [MenuInputDevice] = []
    @State private var volume: Double = 0
    @State private var canSetVolume = false
    @State private var currentDeviceID: AudioDeviceID?

    init(appState: AppState, openSettings: @escaping () -> Void, dismiss: @escaping () -> Void) {
        _appState = Bindable(wrappedValue: appState)
        self.openSettings = openSettings
        self.dismiss = dismiss
        // Seed the slider with the real value so it doesn't animate up from 0.
        let current = AudioController.defaultInputDevice()
        _currentDeviceID = State(initialValue: current)
        _canSetVolume = State(initialValue: current.map(AudioController.canSetInputVolume) ?? false)
        _volume = State(initialValue: current.flatMap { AudioController.volume(on: $0) }.map(Double.init) ?? 0)
    }

    private let menuWidth: CGFloat = 308
    private let edgeInset: CGFloat = 5   // hover background inset from the menu edge
    private let contentInset: CGFloat = 14 // text/divider inset from the menu edge

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Volume", color: .primary, trailing: canSetVolume ? nil : "managed by device")
            volumeRow
            divider()
            header("Input", color: .secondary)
            ForEach(inputs) { inputRow($0) }
            divider()
            textRow(appState.muted ? "Unmute" : "Mute", trailing: muteShortcut) { appState.toggle() }
            textRow(appState.soloActive ? "End Solo Mode" : "Solo Mode", trailing: soloShortcut) {
                appState.toggleSolo()
            }
            soloStatus
            divider()
            textRow("Settings…", trailing: "⌘,") { openSettings(); dismiss() }
            textRow("Quit Vaux", trailing: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 5)
        .frame(width: menuWidth)
        .onAppear(perform: reload)
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
                deviceIcon(device)
                Text(device.name).font(.system(size: 13))
                Spacer(minLength: 6)
                if device.isPreferred { preferredBadge }
            }
        }
    }

    private func textRow(_ title: String, trailing: String?, action: @escaping () -> Void) -> some View {
        MenuRow(height: 22, edgeInset: edgeInset, contentInset: contentInset, action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let trailing, !trailing.isEmpty {
                    Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
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
                parts.append("speakers at \(Int((ducked * 100).rounded()))%")
            }
            lines.append((parts.joined(separator: " · "), false))
        }
        return lines + appState.soloProblems.map { ($0, true) }
    }

    private func deviceIcon(_ device: MenuInputDevice) -> some View {
        ZStack {
            Circle()
                .fill(device.isCurrent ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            Image(systemName: device.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(device.isCurrent ? Color.white : Color(nsColor: .secondaryLabelColor))
                .frame(width: 19, height: 19)
        }
        .frame(width: 26, height: 26)
    }

    private var preferredBadge: some View {
        Text("Preferred")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
    }

    private func divider() -> some View {
        Divider().padding(.horizontal, contentInset).padding(.vertical, 4)
    }

    // MARK: Data + actions

    private var muteShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleMicMute)?.description ?? ""
    }

    private var soloShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleSolo)?.description ?? ModifierTapMonitor.Key.current.symbol
    }

    private func select(_ device: MenuInputDevice) {
        AudioController.setDefaultInputDevice(device.id)
        reload()
    }

    private func reload() {
        let all = AudioController.inputDevices()
        let current = AudioController.defaultInputDevice()
        var preferredID: AudioDeviceID?
        for entry in PreferredInput.order where !entry.uid.isEmpty {
            if let match = all.first(where: { $0.uid == entry.uid }) { preferredID = match.id; break }
        }
        // Order the menu like the priority list: ranked devices first (in
        // priority order), then any others in their natural order.
        let order = PreferredInput.order
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
                isCurrent: device.id == current,
                isPreferred: device.id == preferredID)
        }
        currentDeviceID = current
        if let current {
            canSetVolume = AudioController.canSetInputVolume(current)
            volume = Double(AudioController.volume(on: current) ?? 0)
        } else {
            canSetVolume = false
        }
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
enum VolumeWriter {
    private static let queue = DispatchQueue(label: "dev.imathis.vaux.volume")
    static func write(_ value: Float, to device: AudioDeviceID) {
        queue.async { AudioController.setVolume(value, on: device) }
    }
}
