import Darwin
import Foundation
import os

/// `Vaux -uninstallCamera`: removes Vaux Camera and exits, without the menu
/// bar app. For Homebrew's `brew uninstall`: only the app that installed a
/// system extension can remove it, and only while it's in /Applications,
/// so the cask runs this before the app goes. Quiet if the camera was never
/// turned on. Homebrew runs a cask's uninstall steps on upgrade and
/// reinstall too, when the camera should stay: then it does nothing.
@MainActor
enum CameraUninstall {
    static let argument = "-uninstallCamera"

    static func runIfAsked() {
        guard CommandLine.arguments.contains(argument) else { return }
        if homebrewIsReplacing {
            print("Vaux Camera: kept (Homebrew is upgrading or reinstalling Vaux)")
            exit(0)
        }
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

    /// Homebrew upgrading or reinstalling: its command, a few processes up
    /// (brew, then Ruby, then this), says so.
    private static var homebrewIsReplacing: Bool {
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            let arguments = arguments(of: pid)
            if arguments.contains("upgrade") || arguments.contains("reinstall") { return true }
            pid = parent(of: pid)
        }
        return false
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// A process's arguments: argc, its executable's path and padding, then
    /// argc NUL-terminated strings.
    private static func arguments(of pid: pid_t) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
