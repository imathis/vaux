import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppStorageKey.unmuteVolume) private var unmuteVolume =
        AppStorageKey.unmuteVolumeDefault
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var priority = InputPriorityModel()

    private let rowHeight: CGFloat = 36

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle mute:", name: .toggleMicMute)
                KeyboardShortcuts.Recorder("Use preferred input:", name: .applyPreferredInput)
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
            }

            Section("Preferred Inputs") {
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
                    .frame(height: CGFloat(priority.entries.count) * rowHeight)
                }
                Text("Drag to reorder. “Use preferred input” switches to the highest connected device. Green dot = connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
