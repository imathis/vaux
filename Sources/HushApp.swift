import SwiftUI

@main
struct HushApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            Image(systemName: appState.muted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(appState.muted ? Color.red : Color.primary)
                .accessibilityLabel(appState.muted ? "Microphone muted" : "Microphone live")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
