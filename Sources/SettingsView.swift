import AppKit
import KeyboardShortcuts
import SwiftUI

/// Microphone: dictation (solo mode), mute, and preferred inputs.
struct MicrophoneSettings: View {
    @AppStorage(AppStorageKey.unmuteVolume) private var unmuteVolume =
        AppStorageKey.unmuteVolumeDefault
    @AppStorage(AppStorageKey.enforcePreferred) private var autoSwitch = false
    @AppStorage(AppStorageKey.soloSpeakerLevel) private var soloSpeakerLevel =
        AppStorageKey.soloSpeakerLevelDefault
    @AppStorage(AppStorageKey.dictateWith) private var dictateWith = AppStorageKey.macOSDictation
    @State private var followChoices: [FollowChoice] = []
    @State private var accessibilityTrusted = CallMuter.isTrusted
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
                Picker(selection: $dictateWith) {
                    Label { Text("macOS Dictation") } icon: { Image(systemName: "mic") }
                        .tag(AppStorageKey.macOSDictation)
                    if !followChoices.isEmpty { Divider() }
                    ForEach(followChoices) { choice in
                        Label { Text(choice.name) } icon: { Image(nsImage: choice.icon) }
                            .tag(choice.id)
                    }
                } label: {
                    Text("Dictate with")
                    Text(dictateWith == AppStorageKey.macOSDictation
                        ? "Solo follows its 🎤 key; Escape ends it"
                        : "Solo is on while it's listening")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker volume")
                    VolumeSlider(value: $soloSpeakerLevel, icons: .speaker)
                        .frame(height: 28)
                        .padding(.horizontal, -14) // line the icons up with the text
                }
            } header: {
                SettingsHeader("Dictation", "While you dictate, solo mode mutes you in calls and pauses media.")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unmute volume")
                    VolumeSlider(value: $unmuteVolume)
                        .frame(height: 28)
                        .padding(.horizontal, -14)
                }
            } header: {
                SettingsHeader("Mute")
            }

            Section {
                Toggle("Auto switch", isOn: $autoSwitch)
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
                SettingsHeader("Preferred Inputs", "Switches to the highest-ranked mic that's connected.")
            }
        }
        .formStyle(.grouped)
        .onAppear { followChoices = FollowChoice.all(including: Self.followed(dictateWith)) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = CallMuter.isTrusted
            followChoices = FollowChoice.all(including: Self.followed(dictateWith))
        }
        // Accessibility granted or revoked in System Settings, which stays in
        // front. The new state lands a moment after the notification.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Self.accessibilityChanged)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { accessibilityTrusted = CallMuter.isTrusted }
        }
        .frame(width: SettingsHeader.pageWidth)
    }

    private static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")

    /// The app followed, if dictating with one: kept in the list even when
    /// it isn't running.
    private static func followed(_ dictateWith: String) -> String {
        dictateWith == AppStorageKey.macOSDictation ? "" : dictateWith
    }
}

/// Effects for Vaux Camera, once it's on.
struct EffectsSettings: View {
    let camera: VauxCamera
    let showCamera: () -> Void

    var body: some View {
        if let effects = camera.effects {
            EffectsPage(effects: effects)
        } else {
            ContentUnavailableView {
                Label("Effects", systemImage: "wand.and.stars")
            } description: {
                Text("Text, graphics, looks and more over \(CameraSpec.name), on your keys.")
            } actions: {
                Button("Set Up Camera…", action: showCamera)
            }
            .frame(width: SettingsHeader.pageWidth, height: 280)
        }
    }
}

/// A section title with its one-line description under it.
struct SettingsHeader: View {
    /// Every settings page's width.
    static let pageWidth: CGFloat = 540

    let title: String
    let description: String?

    init(_ title: String, _ description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let description {
                Text(description)
                    .font(.callout)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Text(unmuteOverride.percentText)
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
                value: Binding(get: { unmuteOverride ?? defaultUnmute }, set: { setUnmuteOverride($0) }))
                .frame(width: 300, height: 28)
                .padding(.horizontal, -14) // line the icons up with the text
            Button("Use Default (\(defaultUnmute.percentText))") { setUnmuteOverride(nil) }
                .disabled(unmuteOverride == nil)
        }
        .padding(16)
    }
}

/// An app solo can follow: running apps that use audio (a dictation app
/// connects at launch), plus the chosen one even if it isn't running.
private struct FollowChoice: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    static func all(including chosen: String) -> [FollowChoice] {
        let excluded = CallApp.bundleIDs.union([Bundle.main.bundleIdentifier ?? ""])
        var choices = AudioController.audioClientBundleIDs()
            .filter { !AudioController.bundle($0, belongsToAnyOf: excluded) }
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
