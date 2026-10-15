import AppKit
import CoreAudio
import IOKit.pwr_mgt
import os

/// Pauses media that's playing when solo starts and plays it again when solo
/// ends, so it doesn't bleed into dictation.
///
/// What's playing comes from power assertions: apps hold one while media
/// actually plays ("com.apple.Music.playback", WebKit's "HTMLMediaElement
/// playback", Chromium's "Playing audio") and drop it the moment it pauses.
/// Audio output can't tell: Safari keeps its output running with nothing
/// playing. Commands go through MediaRemote, the system's Now Playing
/// controls: explicit pause and play, which don't toggle as the Play/Pause
/// key does. MediaRemote is private; if it's missing, this does nothing.
@MainActor
final class MediaPauser {
    private static let log = Logger(subsystem: "dev.imathis.vaux", category: "media")
    /// After solo ends, how long a pause still has to show before play is skipped.
    private static let grace: TimeInterval = 2

    /// Playback assertions held when solo paused. One going away shows the
    /// pause took; until then nothing is resumed, so a pause that reached
    /// nothing is never answered with a play that starts something.
    private var paused: Set<UInt64> = []
    private var pauseTook = false
    /// Solo ended before the pause showed: resume if it does by this time.
    private var resumeDeadline: Date?
    /// Polls assertions while a pause hasn't shown yet.
    private var timer: Timer?

    /// Pause what's playing, leaving out `apps` (and their helpers) and any
    /// app using the mic: a call, or the dictation app.
    func pause(ignoring apps: Set<String>) {
        reset()
        let playing = Self.playback(ignoring: apps)
        guard !playing.isEmpty else { return }
        paused = Set(playing.keys)
        Self.log.notice("pausing \(Set(playing.values).sorted().joined(separator: ", "), privacy: .public)")
        Self.send(.pause)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Play again if the pause took. Explicit play: a no-op on anything
    /// resumed by hand meanwhile.
    func resume() {
        guard !paused.isEmpty else { return }
        if pauseTook {
            reset()
            Self.log.notice("resuming")
            Self.send(.play)
        } else {
            resumeDeadline = Date().addingTimeInterval(Self.grace)
        }
    }

    private func check() {
        let held = Set(Self.assertions().map(\.id))
        if !paused.isSubset(of: held) {
            pauseTook = true
            timer?.invalidate()
            timer = nil
            Self.log.notice("pause took")
            if resumeDeadline != nil { resume() }
        } else if let resumeDeadline, Date() >= resumeDeadline {
            Self.log.notice("not resuming: the pause didn't take")
            reset()
        }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        paused = []
        pauseTook = false
        resumeDeadline = nil
    }

    // MARK: What's playing

    private struct Assertion {
        let id: UInt64
        /// The app it's for: daemons hold some on an app's behalf (runningboardd
        /// for WebKit), and helpers hold some for their app.
        let app: pid_t
        let name: String
    }

    /// Playback assertions by ID, with the bundle ID of the app playing.
    private static func playback(ignoring apps: Set<String>) -> [UInt64: String] {
        let onMic = Set(AudioController.processObjects()
            .filter(AudioController.isRunningInput)
            .map { responsiblePID(AudioController.pid(ofProcess: $0)) })
        var playing: [UInt64: String] = [:]
        for assertion in assertions() where isPlayback(assertion.name) && !onMic.contains(assertion.app) {
            let bundle = NSRunningApplication(processIdentifier: assertion.app)?.bundleIdentifier ?? ""
            guard !apps.contains(where: { AudioController.bundle(bundle, belongsTo: $0) }) else { continue }
            playing[assertion.id] = bundle.isEmpty ? "pid \(assertion.app)" : bundle
        }
        return playing
    }

    private static func assertions() -> [Assertion] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return all.flatMap { owner, list in
            list.compactMap { info -> Assertion? in
                guard let id = (info["GlobalUniqueID"] as? NSNumber)?.uint64Value else { return nil }
                let pid = (info["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? owner.int32Value
                return Assertion(id: id, app: responsiblePID(pid), name: info["AssertName"] as? String ?? "")
            }
        }
    }

    /// "…playback" or "Playing …" as a word ("displaying" doesn't count).
    private static func isPlayback(_ name: String) -> Bool {
        name.range(of: #"\bplay(back|ing)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// The app a process works for (Safari for its WebKit processes), from a
    /// private libsystem call; the process itself if that's missing.
    private static let responsibleFor: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t {
        guard let responsibleFor else { return pid }
        let app = responsibleFor(pid)
        return app > 0 ? app : pid
    }

    // MARK: MediaRemote

    private enum Command: UInt32 {
        case play = 0
        case pause = 1
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(framework, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private static func send(_ command: Command) {
        guard let sendCommand else {
            log.error("MediaRemote unavailable")
            return
        }
        let sent = sendCommand(command.rawValue, nil)
        log.notice("sent \(String(describing: command), privacy: .public): \(sent)")
    }
}
