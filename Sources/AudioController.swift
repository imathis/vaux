import AudioToolbox
import CoreAudio
import Foundation

/// Thin wrapper over the Core Audio HAL property API.
///
/// Hard rule for Vaux: we touch audio **only** through HAL property
/// reads/writes/listeners. No streams, no I/O procs, no aggregate devices,
/// no capture. Setting these properties does not trigger TCC, so the app
/// needs no microphone permission.
enum AudioController {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Default input device

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard err == noErr, let cf = name?.takeRetainedValue() else { return "Unknown input" }
        return cf as String
    }

    // MARK: Mute

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func supportsMute(_ id: AudioDeviceID) -> Bool {
        var a = muteAddress()
        return AudioObjectHasProperty(id, &a)
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        var a = muteAddress()
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return err == noErr && v == 1
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on id: AudioDeviceID) -> Bool {
        var a = muteAddress()
        guard AudioObjectHasProperty(id, &a) else { return false }
        var v: UInt32 = muted ? 1 : 0
        let err = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        return err == noErr
    }

    // MARK: Input volume (0.0...1.0)
    //
    // Used for the unmute level and as the mute fallback on devices that
    // don't expose `kAudioDevicePropertyMute`. Some devices expose volume
    // on the Main element; others only per-channel — try Main, then the
    // first couple of channels.

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: element)
    }

    private static let volumeElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

    static func volume(on id: AudioDeviceID) -> Float32? {
        for element in volumeElements {
            var a = volumeAddress(element: element)
            guard AudioObjectHasProperty(id, &a) else { continue }
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    @discardableResult
    static func setVolume(_ scalar: Float32, on id: AudioDeviceID) -> Bool {
        let clamped = max(0, min(1, scalar))
        var didSet = false
        for element in volumeElements {
            var a = volumeAddress(element: element)
            guard AudioObjectHasProperty(id, &a) else { continue }
            var v = clamped
            if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                didSet = true
            }
            // Prefer the Main element alone when it exists.
            if element == kAudioObjectPropertyElementMain { return didSet }
        }
        return didSet
    }

    /// Whether the device exposes a *settable* input volume control. Many USB
    /// mics and Bluetooth headsets manage their own gain and report false here.
    static func canSetInputVolume(_ id: AudioDeviceID) -> Bool {
        for element in volumeElements {
            var a = volumeAddress(element: element)
            guard AudioObjectHasProperty(id, &a) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    // MARK: Output volume (solo-mode ducking)
    //
    // Virtual main volume is the same control as the menu bar Sound slider; it
    // works on devices that only expose per-channel volume (e.g. AirPods).

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    private static func outputVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func outputVolume(on id: AudioDeviceID) -> Float32? {
        var a = outputVolumeAddress()
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setOutputVolume(_ scalar: Float32, on id: AudioDeviceID) -> Bool {
        var a = outputVolumeAddress()
        var v = max(0, min(1, scalar))
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    // MARK: Processes using input
    //
    // Core Audio process objects (read-only properties): which apps are
    // running input right now. No stream, no mic permission.

    /// True if the app (bundle ID) or one of its helpers is running input.
    /// Helpers count because Electron apps capture in one (Slack's audio runs
    /// in `com.tinyspeck.slackmacgap.helper`).
    static func isCapturingInput(_ app: String) -> Bool {
        processObjects().contains { isRunningInput($0) && bundle(bundleID(ofProcess: $0), belongsTo: app) }
    }

    /// The app itself or one of its helpers (`<app id>.helper…`).
    static func bundle(_ bundle: String, belongsTo app: String) -> Bool {
        bundle == app || bundle.hasPrefix(app + ".")
    }

    /// Apps the audio server knows (ones that have played or recorded sound
    /// since launch), by bundle ID — candidates for solo to follow.
    static func audioClientBundleIDs() -> Set<String> {
        Set(processObjects().map(bundleID(ofProcess:)).filter { !$0.isEmpty })
    }

    /// Every process the audio server knows about.
    static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !processes.isEmpty,
              AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &processes) == noErr else { return [] }
        return processes
    }

    /// Any IO at all. Unlike the input and output flags, this one notifies
    /// its listeners when it changes.
    static func isRunning(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr && running == 1
    }

    static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr && running == 1
    }

    static func pid(ofProcess process: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid) == noErr ? pid : -1
    }

    static func bundleID(ofProcess process: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var bundle: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &bundle) == noErr,
              let id = bundle?.takeRetainedValue() else { return "" }
        return id as String
    }

    // MARK: Device enumeration / default-input selection
    //
    // All property reads/writes — listing devices, reading the input channel
    // count, and setting the system default input — no streams, no IOProcs.

    /// All devices that expose at least one input channel, in HAL order.
    /// `uid` is the stable identifier (empty string if the device has none).
    static func inputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasInput($0) }.map { (id: $0, uid: deviceUID($0) ?? "", name: deviceName($0)) }
    }

    /// True if the device has any input channels. Reads the stream
    /// *configuration* (channel layout) — this does not open a stream.
    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    /// Stable per-device identifier that survives reconnects (unlike the
    /// ephemeral AudioDeviceID). Used to persist a preferred-input order.
    static func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Change the system default input device (the Sound-settings input picker).
    /// A property write on the system object — does not touch output.
    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = id
        return AudioObjectSetPropertyData(
            system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    /// Connection transport (built-in, USB, Bluetooth, HDMI, …) used to pick a
    /// device-type icon, like the system Sound menu.
    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type)
        return type
    }

    /// SF Symbol name for a device, by transport (and name for AirPods models).
    static func inputSymbolName(_ id: AudioDeviceID, name: String) -> String {
        switch transportType(id) {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "rectangle.3.group"
        default: return "mic"
        }
    }
}

/// Registers a HAL property listener and removes it on `invalidate()`/`deinit`.
/// The handler runs on the supplied queue (main by default).
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init?(objectID: AudioObjectID,
          selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope,
          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
          queue: DispatchQueue = .main,
          handler: @escaping @Sendable () -> Void) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        self.queue = queue
        self.block = { _, _ in handler() }
        let err = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard err == noErr else { return nil }
        active = true
    }

    func invalidate() {
        guard active else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        active = false
    }

    deinit { invalidate() }
}
