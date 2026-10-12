import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppStorageKey.unmuteVolume) private var unmuteVolume =
        AppStorageKey.unmuteVolumeDefault
    @AppStorage(AppStorageKey.enforcePreferred) private var enforcePreferred = false
    @AppStorage(AppStorageKey.soloDuck) private var soloDuck = false
    @AppStorage(AppStorageKey.soloDuckLevel) private var soloDuckLevel =
        AppStorageKey.soloDuckLevelDefault
    @State private var accessibilityTrusted = CallMuter.isTrusted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var priority = InputPriorityModel()

    private let rowHeight: CGFloat = 36

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle mute:", name: .toggleMicMute)
                KeyboardShortcuts.Recorder("Use preferred input:", name: .applyPreferredInput)
                SoloShortcutRecorder(title: "Toggle solo mode:")
            } header: {
                Text("Shortcuts")
            }

            Section {
                Toggle("Lower speakers while solo", isOn: $soloDuck)
                HStack {
                    Slider(value: $soloDuckLevel, in: 0.05...0.8)
                    Text("\(Int((soloDuckLevel * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(!soloDuck)
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
            } header: {
                Text("Solo Mode")
            } footer: {
                Text("For dictating on a call: mutes Slack and Discord in the app and keeps your mic live. Speakers drop to this share of their level.")
            }

            Section {
                VolumeSlider(value: $unmuteVolume)
                    .frame(height: 28)
            } header: {
                HStack {
                    Text("Unmute volume")
                    Spacer()
                    Text("\(Int((unmuteVolume * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } footer: {
                Text("Inputs will be set to this volume when unmuted.")
            }

            Section {
                Toggle("Auto switch", isOn: $enforcePreferred)
                    .onChange(of: enforcePreferred) { _, on in
                        if on { NotificationCenter.default.post(name: .hushEnforcePreferred, object: nil) }
                    }

                if priority.entries.isEmpty {
                    Text("No input devices seen yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(priority.entries) { entry in
                            let connected = priority.isConnected(entry)
                            HStack(spacing: 8) {
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
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(height: 22)
                            .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                        }
                        .onMove(perform: priority.move)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(min(priority.entries.count, 6)) * rowHeight)
                }
            } header: {
                Text("Preferred Inputs")
            } footer: {
                Text("Switch to inputs as available in this order.")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = CallMuter.isTrusted
        }
        .frame(width: 460)
    }
}
