import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppStorageKey.unmuteVolume) private var unmuteVolume =
        AppStorageKey.unmuteVolumeDefault
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Toggle mic mute:", name: .toggleMicMute)

            LabeledContent("Unmute volume:") {
                VStack(alignment: .leading) {
                    Slider(value: $unmuteVolume, in: 0...1)
                        .frame(width: 200)
                    Text("\(Int((unmuteVolume * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
