import AppKit
import CoreAudio
import os

/// An app using the mic: the app a capturing process works for (Slack for
/// its helper, Safari for its WebKit process, or the process itself).
struct MicUser: Sendable, Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
}

/// Which apps are using the mic: calls, dictation apps, browsers. Read from
/// Core Audio process objects — no streams, no mic permission. One for the
/// whole app.
///
/// The process "running input" flag never notifies its listeners; the
/// "running any IO" flag does. So that's what's listened to, on every
/// process, and input is read only on the few processes with IO running.
/// Input can also start while a process is already playing sound, which
/// changes nothing there, so while any process has IO running their input
/// is checked twice a second as well. Who a process works for is worked out
/// once, when it appears.
@MainActor
final class CaptureWatcher {
    /// The apps on the mic now. Readable from any thread: solo's call work
    /// runs off the main thread.
    nonisolated static var current: [MicUser] { snapshot.withLock { $0 } }

    /// Whether the app, or a process working for it, is on the mic.
    nonisolated static func isCapturing(_ app: String) -> Bool {
        current.contains { AudioController.bundle($0.bundleID, belongsTo: app) }
    }

    nonisolated private static let snapshot = OSAllocatedUnfairLock(initialState: [MicUser]())

    private struct Process {
        let user: MicUser
        let listener: AudioPropertyListener?
    }

    private var onChange: ((_ user: MicUser, _ capturing: Bool) -> Void)?
    private var processes: [AudioObjectID: Process] = [:]
    /// Processes with any IO running.
    private var running: Set<AudioObjectID> = []
    private var listListener: AudioPropertyListener?
    private var poll: Timer?

    /// Reports the apps on the mic right away, then changes.
    func start(onChange: @escaping (_ user: MicUser, _ capturing: Bool) -> Void) {
        self.onChange = onChange
        // Process objects come and go as apps connect to the audio server.
        listListener = AudioPropertyListener(
            objectID: AudioController.system,
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        rescan()
    }

    private func rescan() {
        var next: [AudioObjectID: Process] = [:]
        for process in AudioController.processObjects() {
            if let known = processes[process] {
                next[process] = known
                continue
            }
            next[process] = Process(
                user: Self.user(of: process),
                listener: AudioPropertyListener(
                    objectID: process,
                    selector: kAudioProcessPropertyIsRunning,
                    scope: kAudioObjectPropertyScopeGlobal
                ) { [weak self] in
                    MainActor.assumeIsolated { self?.runningChanged(process) }
                })
            if AudioController.isRunning(process) { running.insert(process) }
        }
        processes = next // dropped listeners unregister on deinit
        running.formIntersection(next.keys)
        evaluate()
    }

    private func runningChanged(_ process: AudioObjectID) {
        if AudioController.isRunning(process) { running.insert(process) } else { running.remove(process) }
        evaluate()
    }

    private func evaluate() {
        var users: [MicUser] = []
        for process in running where AudioController.isRunningInput(process) {
            guard let user = processes[process]?.user, !user.bundleID.isEmpty,
                  !users.contains(where: { $0.bundleID == user.bundleID }) else { continue }
            users.append(user)
        }
        let now = users
        let before = Self.snapshot.withLock { old in defer { old = now }; return old }
        for user in users where !before.contains(where: { $0.bundleID == user.bundleID }) {
            onChange?(user, true)
        }
        for user in before where !users.contains(where: { $0.bundleID == user.bundleID }) {
            onChange?(user, false)
        }

        if running.isEmpty {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }
    }

    /// The app a process works for.
    private static func user(of process: AudioObjectID) -> MicUser {
        let bundle = AudioController.bundleID(ofProcess: process)
        let pid = AudioController.responsiblePID(AudioController.pid(ofProcess: process))
        let app = NSRunningApplication(processIdentifier: pid)
        let id = app?.bundleIdentifier ?? bundle
        return MicUser(bundleID: id, name: app?.localizedName ?? id, pid: pid)
    }
}
