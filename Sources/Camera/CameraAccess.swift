import AppKit
import AVFoundation
import Observation

/// Vaux's camera permission: asking for it, and the way back to it in
/// System Settings once it's been turned down.
@MainActor @Observable
final class CameraAccess {
    /// Privacy & Security → Camera.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    private(set) var status = AVCaptureDevice.authorizationStatus(for: .video)

    var isAuthorized: Bool { status == .authorized }

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        // The user may have changed it in System Settings meanwhile.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func request() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            refresh()
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }
}
