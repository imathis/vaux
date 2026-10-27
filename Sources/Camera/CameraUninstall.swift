import Foundation
import os
import SystemExtensions

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
        let delegate = Delegate()
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: ExtensionInstaller.extensionID, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
        // macOS may ask the user first; don't hold up the uninstall forever.
        let deadline = Date().addingTimeInterval(30)
        while delegate.result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        UserDefaults.standard.set(false, forKey: AppStorageKey.cameraOn)
        let result = delegate.result ?? "timed out"
        Logger(subsystem: "dev.imathis.vaux", category: "installer").notice("Uninstall camera: \(result, privacy: .public)")
        print("Vaux Camera: \(result)")
        exit(result == "failed" ? 1 : 0)
    }

    private final class Delegate: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
        var result: String?

        func request(
            _ request: OSSystemExtensionRequest,
            actionForReplacingExtension existing: OSSystemExtensionProperties,
            withExtension replacement: OSSystemExtensionProperties
        ) -> OSSystemExtensionRequest.ReplacementAction {
            .replace
        }

        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

        func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
            self.result = result == .willCompleteAfterReboot ? "removed at the next restart" : "removed"
        }

        func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
            // Never turned on: nothing to remove.
            result = (error as? OSSystemExtensionError)?.code == .extensionNotFound ? "not installed" : "failed"
        }
    }
}
