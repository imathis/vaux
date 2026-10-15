import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppStorageKey.unmuteVolume) private var unmuteVolume =
        AppStorageKey.unmuteVolumeDefault
    @AppStorage(AppStorageKey.enforcePreferred) private var autoSwitch = false
    @AppStorage(AppStorageKey.soloPauseMedia) private var soloPauseMedia = true
    @AppStorage(AppStorageKey.soloSpeakerLevel) private var soloSpeakerLevel =
        AppStorageKey.soloSpeakerLevelDefault
    @AppStorage(AppStorageKey.soloFollowApp) private var soloFollowApp = ""
    @State private var followChoices: [FollowChoice] = []
    @State private var accessibilityTrusted = CallMuter.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var priority = InputPriorityModel()

    private let rowHeight: CGFloat = 36

    var body: some View {
        Form {
            Section {
                if !accessibilityTrusted {
                    HStack {
                        Text("Solo mode needs Accessibility access.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings…") {
                            CallMuter.requestTrust()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                SoloShortcutRecorder(title: "Shortcut")
                Picker(selection: $soloFollowApp) {
                    Text("Off").tag("")
                    ForEach(followChoices) { choice in
                        Label { Text(choice.name) } icon: { Image(nsImage: choice.icon) }
                            .tag(choice.id)
                    }
                } label: {
                    Text("Turn on automatically")
                    Text("While this app is using the mic")
                }
                Toggle("Pause playing media", isOn: $soloPauseMedia)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker volume")
                    VolumeSlider(
                        value: $soloSpeakerLevel, icons: .speaker, range: 0.05...1,
                        showsPercent: true)
                        .frame(height: 28)
                        .padding(.horizontal, -14) // line the icons up with the text
                }
            } header: {
                header("Solo Mode", "While you dictate, mutes you in Slack and Discord calls.")
            }

            Section {
                KeyboardShortcuts.Recorder("Shortcut", name: .toggleMicMute)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unmute volume")
                    // Never 0%: unmuting to silence would look live and hear nothing.
                    VolumeSlider(value: $unmuteVolume, range: 0.05...1, showsPercent: true)
                        .frame(height: 28)
                        .padding(.horizontal, -14)
                }
            } header: {
                header("Mute")
            }

            Section {
                Toggle("Auto switch", isOn: $autoSwitch)
                    .onChange(of: autoSwitch) { _, on in
                        if on { NotificationCenter.default.post(name: .enforcePreferredInput, object: nil) }
                    }
                if autoSwitch {
                    if priority.entries.isEmpty {
                        Text("No input devices seen yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(priority.entries) { entry in
                                InputRow(
                                    entry: entry,
                                    connected: priority.isConnected(entry),
                                    unmuteOverride: priority.unmuteOverrides[entry.uid],
                                    defaultUnmute: unmuteVolume
                                ) { priority.setUnmuteOverride($0, for: entry) }
                                .frame(height: 22)
                                .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                            }
                            .onMove(perform: priority.move)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(height: CGFloat(min(priority.entries.count, 6)) * rowHeight)
                    }
                }
            } header: {
                header("Preferred Inputs", "Switches to the highest-ranked mic that's connected.")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear { followChoices = FollowChoice.all(including: soloFollowApp) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = CallMuter.isTrusted
            followChoices = FollowChoice.all(including: soloFollowApp)
        }
        .frame(width: 460)
    }

    /// A section title with its one-line description under it.
    private func header(_ title: String, _ description: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let description {
                Text(description)
                    .font(.callout)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A preferred-input row: drag handle, connection dot, name, and the input's
/// unmute level — a faint control when it uses the default, its percentage
/// when it has its own. Either opens a popover to set it.
private struct InputRow: View {
    let entry: InputEntry
    let connected: Bool
    let unmuteOverride: Double?
    let defaultUnmute: Double
    let setUnmuteOverride: (Double?) -> Void

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
            if !connected {
                Text("disconnected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button { editing = true } label: {
                // A fixed, fully hittable target either way (the icon alone is
                // tiny); the popover points at the icon or pill, not the target.
                levelLabel
                    .popover(isPresented: $editing, arrowEdge: .bottom) { levelPopover }
                    .frame(width: 48, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unmute volume for this input")
        }
    }

    @ViewBuilder private var levelLabel: some View {
        if let unmuteOverride {
            Text("\(Self.percent(unmuteOverride))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        } else {
            Image(systemName: "dial.medium")
                .foregroundStyle(.tertiary)
        }
    }

    private var levelPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unmute Volume")
                .font(.headline)
            Text(entry.name)
                .foregroundStyle(.secondary)
            VolumeSlider(
                value: Binding(get: { unmuteOverride ?? defaultUnmute }, set: { setUnmuteOverride($0) }),
                range: 0.05...1,
                showsPercent: true)
                .frame(width: 300, height: 28)
                .padding(.horizontal, -14) // line the icons up with the text
            Button("Use Default (\(Self.percent(defaultUnmute)))") { setUnmuteOverride(nil) }
                .disabled(unmuteOverride == nil)
        }
        .padding(16)
    }

    private static func percent(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }
}

/// An app solo can follow: running apps that use audio (a dictation app
/// connects at launch), plus the chosen one even if it isn't running.
private struct FollowChoice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    static func all(including chosen: String) -> [FollowChoice] {
        let excluded = CallApp.all.map(\.bundleID) + [Bundle.main.bundleIdentifier ?? ""]
        var choices = AudioController.audioClientBundleIDs()
            .filter { id in !excluded.contains { AudioController.bundle(id, belongsTo: $0) } }
            .compactMap { id -> FollowChoice? in
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                      app.activationPolicy != .prohibited,
                      let path = app.bundleURL?.path,
                      !path.hasPrefix("/System/"), // Control Center, Siri…
                      !path.contains(".app/Contents/"), // helpers inside another app
                      let name = app.localizedName, let icon = app.icon else { return nil }
                return FollowChoice(id: id, name: name, icon: icon)
            }
        if !chosen.isEmpty, !choices.contains(where: { $0.id == chosen }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) {
            choices.append(FollowChoice(
                id: chosen,
                name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
        return choices
            .map { FollowChoice(id: $0.id, name: $0.name, icon: $0.icon.menuSized) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private extension NSImage {
    /// A 16pt copy, so menu rows don't take the icon's full size.
    var menuSized: NSImage {
        let image = copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
