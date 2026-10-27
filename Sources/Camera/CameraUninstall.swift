import Foundation
import os

/// `Vaux -uninstallCamera`: removes Vaux Camera and exits, without the menu
/// bar app. For Homebrew's `brew uninstall`: only the app that installed a
/// system extension can remove it, and only while it's in /Applications,
/// so the cask runs this before the app goes. Quiet if the camera was never
/// turned on.
@MainActor
enum CameraUninstall {
    static let argument = "-uninstallCamera"

    static func runIfAsked() {
        guard CommandLine.arguments.contains(argument) else { return }
        let installer = ExtensionInstaller()
        var result: String?
        // What macOS has installed, then removal (as Turn Off does it).
        // macOS may ask the user; don't hold up the uninstall forever.
        let deadline = Date().addingTimeInterval(45)
        func wait(until done: () -> Bool) {
            while !done(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
        }
        wait { installer.state != .checking }
        if installer.installedBuild == nil, installer.state == .notInstalled {
            result = "not installed"
        } else {
            installer.uninstall { gone in result = gone ? "removed" : "failed" }
            wait { result != nil }
        }
        UserDefaults.standard.set(false, forKey: AppStorageKey.cameraOn)
        let outcome = result ?? "timed out"
        Logger(subsystem: "dev.imathis.vaux", category: "installer").notice("Uninstall camera: \(outcome, privacy: .public)")
        print("Vaux Camera: \(outcome)")
        exit(outcome == "failed" || outcome == "timed out" ? 1 : 0)
    }
}
