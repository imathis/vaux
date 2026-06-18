import AppKit
import SwiftUI

/// The `.menu`-style MenuBarExtra contents.
struct MenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let name = appState.deviceName {
            // Non-interactive "what will it toggle" readout.
            Text("Input: \(name)")
            if !appState.supportsMute {
                Text("Mute unsupported — using volume")
            }
        } else {
            Text("No input device")
        }

        Divider()

        Button(appState.muted ? "Unmute" : "Mute") {
            appState.toggle()
        }
        .disabled(!appState.hasDevice)

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Quit Hush") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
