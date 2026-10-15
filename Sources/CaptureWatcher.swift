import CoreAudio
import Foundation

/// Reports when apps start or stop capturing input — a call app joining or
/// leaving a call, a dictation app starting to listen — from Core Audio
/// process objects: no streams, no mic permission.
///
/// The process "running input" flag never notifies its listeners; the
/// "running any IO" flag does. So that's what's listened to, and input is
/// read when it fires. Input can also start while the app is already
/// playing sound, which changes nothing there, so while a watched app has
/// any IO running its input is checked twice a second as well.
@MainActor
final class CaptureWatcher {
    /// Apps to watch. Their helpers count too (Slack captures in
    /// `com.tinyspeck.slackmacgap.helper`).
    var bundleIDs: Set<String> = [] {
        didSet { if bundleIDs != oldValue, onChange != nil { rescan() } }
    }

    private var onChange: ((_ bundleID: String, _ capturing: Bool) -> Void)?
    private var capturing: Set<String> = []
    private var listListener: AudioPropertyListener?
    /// IsRunning listeners on the watched apps' process objects.
    private var inputListeners: [AudioObjectID: AudioPropertyListener] = [:]
    private var poll: Timer?

    /// Reports current state right away (apps already capturing), then changes.
    func start(onChange: @escaping (_ bundleID: String, _ capturing: Bool) -> Void) {
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
        var listeners: [AudioObjectID: AudioPropertyListener] = [:]
        for process in AudioController.processObjects() {
            let bundle = AudioController.bundleID(ofProcess: process)
            guard bundleIDs.contains(where: { AudioController.bundle(bundle, belongsTo: $0) }) else { continue }
            listeners[process] = inputListeners[process] ?? AudioPropertyListener(
                objectID: process,
                selector: kAudioProcessPropertyIsRunning,
                scope: kAudioObjectPropertyScopeGlobal
            ) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        inputListeners = listeners // dropped listeners unregister on deinit
        capturing.formIntersection(bundleIDs) // unwatched apps are dropped silently
        evaluate()
    }

    private func evaluate() {
        for id in bundleIDs {
            let now = AudioController.isCapturingInput(id)
            guard now != capturing.contains(id) else { continue }
            if now { capturing.insert(id) } else { capturing.remove(id) }
            onChange?(id, now)
        }
        let busy = inputListeners.keys.contains(where: AudioController.isRunning)
        if busy, poll == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        } else if !busy {
            poll?.invalidate()
            poll = nil
        }
    }
}
