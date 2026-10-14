import CoreAudio
import Foundation

/// Reports when apps start or stop capturing input — a call app joining or
/// leaving a call, a dictation app starting to listen — from Core Audio
/// process objects: property listeners only, no streams, no mic permission.
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
    /// IsRunningInput listeners on the watched apps' process objects.
    private var inputListeners: [AudioObjectID: AudioPropertyListener] = [:]

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
                selector: kAudioProcessPropertyIsRunningInput,
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
    }
}
