import AppKit
import AudioToolbox
import CoreAudio

/// Thin wrapper over the Core Audio HAL property API.
///
/// Hard rule for Vaux: we touch audio **only** through HAL property
/// reads/writes/listeners. No streams, no I/O procs, no aggregate devices,
/// no capture. Setting these properties does not trigger TCC, so the app
/// needs no microphone permission.
enum AudioController {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Property access

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func has(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(id, &address)
    }

    /// A fixed-size value (number, ID, flag).
    private static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, as initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    private static func write<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    private static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func readIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty, AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        read(system, address(selector), as: AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    // MARK: Default input device

    static func defaultInputDevice() -> AudioDeviceID? {
        device(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        readString(id, kAudioObjectPropertyName) ?? "Unknown input"
    }

    // MARK: Mute

    private static let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)

    static func supportsMute(_ id: AudioDeviceID) -> Bool {
        has(id, muteAddress)
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        read(id, muteAddress, as: UInt32(0)) == 1
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on id: AudioDeviceID) -> Bool {
        supportsMute(id) && write(id, muteAddress, UInt32(muted ? 1 : 0))
    }

    // MARK: Input volume (0.0...1.0)
    //
    // Used for the unmute level and as the mute fallback on devices that
    // don't expose `kAudioDevicePropertyMute`. Some devices expose volume
    // on the Main element; others only per-channel — try Main, then the
    // first couple of channels.

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
    }

    /// The elements that carry the device's input volume.
    static func volumeElements(on id: AudioDeviceID) -> [UInt32] {
        [kAudioObjectPropertyElementMain, 1, 2].filter { has(id, volumeAddress(element: $0)) }
    }

    static func volume(on id: AudioDeviceID) -> Float32? {
        volumeElements(on: id).lazy.compactMap { read(id, volumeAddress(element: $0), as: Float32(0)) }.first
    }

    /// No mute property: input at ~0 volume counts as muted.
    static func isSilent(_ id: AudioDeviceID) -> Bool {
        (volume(on: id) ?? 1) <= 0.0001
    }

    @discardableResult
    static func setVolume(_ scalar: Float32, on id: AudioDeviceID) -> Bool {
        let clamped = max(0, min(1, scalar))
        var didSet = false
        for element in volumeElements(on: id) {
            if write(id, volumeAddress(element: element), clamped) { didSet = true }
            // The Main element alone is enough when it takes the write.
            if element == kAudioObjectPropertyElementMain, didSet { return true }
        }
        return didSet
    }

    /// Whether the device exposes a *settable* input volume control. Many USB
    /// mics and Bluetooth headsets manage their own gain and report false here.
    static func canSetInputVolume(_ id: AudioDeviceID) -> Bool {
        volumeElements(on: id).contains { element in
            var a = volumeAddress(element: element)
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
        }
    }

    // MARK: Output volume (solo-mode ducking)
    //
    // Virtual main volume is the same control as the menu bar Sound slider; it
    // works on devices that only expose per-channel volume (e.g. AirPods).

    static func defaultOutputDevice() -> AudioDeviceID? {
        device(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static let outputVolumeAddress = address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)

    static func outputVolume(on id: AudioDeviceID) -> Float32? {
        read(id, outputVolumeAddress, as: Float32(0))
    }

    @discardableResult
    static func setOutputVolume(_ scalar: Float32, on id: AudioDeviceID) -> Bool {
        write(id, outputVolumeAddress, max(0, min(1, scalar)))
    }

    // MARK: Processes
    //
    // Core Audio process objects (read-only properties): which apps are
    // running audio right now. No stream, no mic permission. See
    // CaptureWatcher for who's on the mic.

    /// Every process the audio server knows about.
    static func processObjects() -> [AudioObjectID] {
        readIDs(system, kAudioHardwarePropertyProcessObjectList)
    }

    /// Apps the audio server knows (ones that have played or recorded sound
    /// since launch), by bundle ID — candidates for solo to follow.
    static func audioClientBundleIDs() -> Set<String> {
        Set(processObjects().map(bundleID(ofProcess:)).filter { !$0.isEmpty })
    }

    /// Any IO at all. Unlike the input and output flags, this one notifies
    /// its listeners when it changes.
    static func isRunning(_ process: AudioObjectID) -> Bool {
        read(process, address(kAudioProcessPropertyIsRunning), as: UInt32(0)) == 1
    }

    static func isRunningInput(_ process: AudioObjectID) -> Bool {
        read(process, address(kAudioProcessPropertyIsRunningInput), as: UInt32(0)) == 1
    }

    static func pid(ofProcess process: AudioObjectID) -> pid_t {
        read(process, address(kAudioProcessPropertyPID), as: pid_t(-1)) ?? -1
    }

    static func bundleID(ofProcess process: AudioObjectID) -> String {
        readString(process, kAudioProcessPropertyBundleID) ?? ""
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// The app a process works for (Safari for its WebKit processes, Slack for
    /// its helpers), from a private libsystem call; the process itself if
    /// that's missing.
    private static let responsibleFor: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t {
        guard let responsibleFor else { return pid }
        let app = responsibleFor(pid)
        return app > 0 ? app : pid
    }

    /// The app itself or one of its helpers (`<app id>.helper…`).
    static func bundle(_ bundle: String, belongsTo app: String) -> Bool {
        bundle == app || bundle.hasPrefix(app + ".")
    }

    static func bundle(_ bundle: String, belongsToAnyOf apps: some Sequence<String>) -> Bool {
        apps.contains { self.bundle(bundle, belongsTo: $0) }
    }

    // MARK: Device enumeration / default-input selection
    //
    // All property reads/writes — listing devices, reading the input channel
    // count, and setting the system default input — no streams, no IOProcs.

    /// All devices that expose at least one input channel, in HAL order.
    /// `uid` is the stable identifier (empty string if the device has none).
    static func inputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        readIDs(system, kAudioHardwarePropertyDevices)
            .filter { hasInput($0) }
            .map { (id: $0, uid: deviceUID($0) ?? "", name: deviceName($0)) }
    }

    /// True if the device has any input channels. Reads the stream
    /// *configuration* (channel layout) — this does not open a stream.
    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
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
        readString(id, kAudioDevicePropertyDeviceUID)
    }

    /// Change the system default input device (the Sound-settings input picker).
    /// A property write on the system object — does not touch output.
    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        write(system, address(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    /// Connection transport (built-in, USB, Bluetooth, HDMI, …) used to pick a
    /// device-type icon, like the system Sound menu.
    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        read(id, address(kAudioDevicePropertyTransportType), as: UInt32(0)) ?? 0
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

/// Registers a HAL property listener on the main queue and removes it when
/// released.
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(objectID: AudioObjectID,
          selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope,
          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
          handler: @escaping @Sendable () -> Void) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}
