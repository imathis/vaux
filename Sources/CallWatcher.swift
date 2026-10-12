import CoreAudio
import Foundation

/// Reports when a call app starts or stops capturing input (joins or leaves a
/// call), from Core Audio process objects — property listeners only, no
/// streams, no mic permission.
@MainActor
final class CallWatcher {
    private var onChange: ((CallApp, _ inCall: Bool) -> Void)?
    private var inCall: Set<String> = []
    private var listListener: AudioPropertyListener?
    /// IsRunningInput listeners on the call apps' process objects.
    private var inputListeners: [AudioObjectID: AudioPropertyListener] = [:]

    /// Reports current state right away (apps already in a call), then changes.
    func start(onChange: @escaping (CallApp, _ inCall: Bool) -> Void) {
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
            guard CallApp.all.contains(where: { bundle.hasPrefix($0.bundleID) }) else { continue }
            listeners[process] = inputListeners[process] ?? AudioPropertyListener(
                objectID: process,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal
            ) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        inputListeners = listeners // dropped listeners unregister on deinit
        evaluate()
    }

    private func evaluate() {
        for app in CallApp.all {
            let capturing = AudioController.isCapturingInput(bundlePrefix: app.bundleID)
            guard capturing != inCall.contains(app.bundleID) else { continue }
            if capturing { inCall.insert(app.bundleID) } else { inCall.remove(app.bundleID) }
            onChange?(app, capturing)
        }
    }
}
