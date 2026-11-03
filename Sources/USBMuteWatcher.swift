import CoreAudio
import Foundation
import IOKit.usb
import os

/// Some USB mics mute from their own button without telling macOS (the
/// Elgato Wave:3 does): the mic's mute changes, macOS's copy of it doesn't,
/// so Vaux, and anything else reading the input's mute, shows the old
/// state. This reads the mute from the mic itself, a few times a second,
/// and when the mic's has changed on its own, sets macOS's to match, which
/// the mic takes as no change, and Vaux follows like a mute changed
/// anywhere else.
///
/// A request on the mic's control pipe: not audio (no stream, no mic
/// permission), and shared (the mic's own apps can still open it).
///
/// Only once the mic's mute has been seen following macOS's (a mute from
/// Vaux or another app reaching it), remembered per mic, until it misses a
/// few in a row: one that doesn't follow is some other control, and
/// copying it would undo mutes.
final class USBMuteWatcher: @unchecked Sendable {
    let device: AudioDeviceID
    private let uid: String
    private let name: String
    private let usb: USBDevice
    private let control: MuteControl
    private let since = Date()
    private var timer: DispatchSourceTimer?
    // On the timer's queue:
    private var last: (mic: Bool, mac: Bool)?
    /// macOS's changed and the mic's hadn't yet: what it should change to.
    private var expected: Bool?
    /// macOS changes in a row the mic's didn't follow. One can be a press
    /// of its button just after.
    private var misses = 0

    private static let interval = DispatchTimeInterval.milliseconds(400)
    private static let log = Logger(subsystem: "dev.imathis.vaux", category: "inputs")

    /// Nil unless the input is a USB mic whose mute Vaux can read.
    init?(device: AudioDeviceID) {
        guard AudioController.transportType(device) == kAudioDeviceTransportTypeUSB,
              AudioController.supportsMute(device),
              let uid = AudioController.deviceUID(device),
              let usb = USBDevice(audioUID: uid),
              let configuration = usb.configuration,
              let control = MuteControl(in: configuration)
        else { return nil }
        self.device = device
        self.uid = uid
        self.name = AudioController.deviceName(device)
        self.usb = usb
        self.control = control
        guard readMic() != nil else { return nil }
        Self.log.notice("Reading \(self.name, privacy: .public)'s own mute\(self.follows ? "" : " (followed once it follows macOS's)", privacy: .public)")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.imathis.vaux.usb-mute"))
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// Each tick: whether the mic's mute followed a change of macOS's, or
    /// changed by itself, then macOS's is set to the mic's.
    private func check() {
        guard let mic = readMic() else { return }
        let mac = AudioController.isMuted(device)
        defer { last = (mic, mac) }
        guard let last else { return }
        if mac != last.mac {
            // By Vaux or anything: the mic's should follow.
            if mic != mac { expected = mac } else if mic != last.mic { followed(true) }
            return
        }
        if let expected {
            self.expected = nil
            followed(mic == expected)
        }
        // Differing a tick on, not a change from macOS still on its way;
        // and not just as the input switched, as Vaux puts its mute on it
        // (AppState.applyMuteIntent, a second at most).
        guard mic != mac, mic == last.mic, follows, Date().timeIntervalSince(since) > 2 else { return }
        Self.log.notice("\(self.name, privacy: .public) \(mic ? "muted" : "unmuted", privacy: .public) on the mic")
        AudioController.setMuted(mic, on: device)
    }

    private func readMic() -> Bool? {
        // Mute, master channel.
        usb.readControl(request: control.request, value: 0x0100, index: control.index).map { $0 != 0 }
    }

    /// Mics seen following macOS's mute, by UID: theirs is the one macOS sets.
    private static var following: [String] {
        get { UserDefaults.standard.stringArray(forKey: "usbMuteFollows") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "usbMuteFollows") }
    }

    private var follows: Bool { Self.following.contains(uid) }

    private func followed(_ didFollow: Bool) {
        misses = didFollow ? 0 : misses + 1
        guard didFollow != follows, didFollow || misses >= 3 else { return }
        Self.following = didFollow ? Self.following + [uid] : Self.following.filter { $0 != uid }
        Self.log.notice("\(self.name, privacy: .public)'s own mute \(didFollow ? "follows macOS's" : "didn't follow macOS's 3 times: not followed", privacy: .public)")
    }
}

/// A USB mic's mute, per its descriptors: the feature unit with a master
/// mute on the way to the host (the USB-streaming output terminal), in its
/// first audio control interface. As the request that reads it.
private struct MuteControl {
    /// GET_CUR in USB Audio 1, CUR in 2.
    let request: UInt8
    /// The unit, and its interface.
    let index: UInt16

    init?(in configuration: [UInt8]) {
        var audioControl: (interface: UInt8, audio2: Bool)?
        var entities: [UInt8: [UInt8]] = [:]
        var toHost: UInt8?
        var offset = 0
        walk: while offset + 2 <= configuration.count {
            let length = Int(configuration[offset])
            guard length >= 2, offset + length <= configuration.count else { break }
            let descriptor = Array(configuration[offset..<offset + length])
            offset += length
            switch descriptor[1] {
            case 0x04 where length >= 9:
                // An interface: the first audio control one (class 1,
                // subclass 1), up to the next.
                if audioControl != nil { break walk }
                if descriptor[5] == 1, descriptor[6] == 1 { audioControl = (descriptor[2], descriptor[7] == 0x20) }
            case 0x24 where audioControl != nil && length >= 4:
                // Its terminals and units, by ID; the output terminal to USB
                // streaming is where the mic's audio leaves.
                if descriptor[2] == 0x03, length >= 8, UInt16(descriptor[4]) | UInt16(descriptor[5]) << 8 == 0x0101 {
                    toHost = toHost ?? descriptor[7]
                } else if descriptor[2] != 0x01 {
                    entities[descriptor[3]] = descriptor
                }
            default:
                break
            }
        }
        guard let audioControl, var id = toHost else { return nil }
        // Back from the host through feature units, and selectors of one
        // input, to the first with a master mute.
        for _ in 0..<8 {
            guard let unit = entities[id], unit.count >= 5 else { return nil }
            switch unit[2] {
            case 0x06:
                // Audio 1: bControlSize, then bmaControls(0); 2: four bytes
                // of bmaControls(0). Mute is the lowest bit either way.
                let mute = audioControl.audio2 ? unit.count >= 9 && unit[5] & 0x01 != 0 : unit.count >= 7 && unit[5] >= 1 && unit[6] & 0x01 != 0
                if mute {
                    request = audioControl.audio2 ? 0x01 : 0x81
                    index = UInt16(id) << 8 | UInt16(audioControl.interface)
                    return
                }
                id = unit[4]
            case 0x05 where unit.count >= 6 && unit[4] == 1:
                id = unit[5]
            default:
                return nil
            }
        }
        return nil
    }
}

/// A USB device's control pipe, through IOUSBLib, never opened: opening is
/// exclusive (it'd lock out the mic's own apps), and requests don't need it.
private final class USBDevice {
    private typealias Interface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface182>?>
    private let interface: Interface

    // IOUSBLib's IDs are C macros, which Swift doesn't see.
    private static var userClientType: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4, 0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61) }
    private static var plugInType: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F) }
    private static var deviceType: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x15, 0x2F, 0xC4, 0x96, 0x48, 0x91, 0x11, 0xD5, 0x9D, 0x52, 0x00, 0x0A, 0x27, 0x80, 0x1E, 0x86) }

    /// The USB device a Core Audio one is, by the UID macOS gives it
    /// ("AppleUSBAudioEngine:<maker>:<product>:<serial>:<interfaces>"); one
    /// without a serial number isn't found.
    init?(audioUID uid: String) {
        guard let service = Self.service(forAudioUID: uid) else { return nil }
        defer { IOObjectRelease(service) }
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, Self.userClientType, Self.plugInType, &plugIn, &score) == KERN_SUCCESS,
              let plugIn, let functions = plugIn.pointee?.pointee
        else { return nil }
        defer { _ = functions.Release(plugIn) }
        var interface: LPVOID?
        guard functions.QueryInterface(plugIn, CFUUIDGetUUIDBytes(Self.deviceType), &interface) == S_OK, let interface else { return nil }
        self.interface = interface.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface182>?.self)
    }

    deinit { _ = interface.pointee?.pointee.Release(interface) }

    private static func service(forAudioUID uid: String) -> io_service_t? {
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(devices) }
        while case let service = IOIteratorNext(devices), service != 0 {
            let string = { (key: String) in IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String }
            if let maker = string("kUSBVendorString"), let product = string("kUSBProductString"), let serial = string("kUSBSerialNumberString"),
               uid.hasPrefix("AppleUSBAudioEngine:\(maker):\(product):\(serial):") {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    /// The first configuration's descriptors, all of them.
    var configuration: [UInt8]? {
        var descriptor: IOUSBConfigurationDescriptorPtr?
        guard interface.pointee?.pointee.GetConfigurationDescriptorPtr(interface, 0, &descriptor) == kIOReturnSuccess, let descriptor else { return nil }
        return [UInt8](UnsafeRawBufferPointer(start: descriptor, count: Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))))
    }

    /// A one-byte control's value, by a class request to an interface's
    /// entity.
    func readControl(request: UInt8, value: UInt16, index: UInt16) -> UInt8? {
        var control: UInt8 = 0
        let done = withUnsafeMutableBytes(of: &control) { buffer -> Bool in
            var request = IOUSBDevRequestTO(
                bmRequestType: 0xA1, bRequest: request, wValue: value, wIndex: index, wLength: 1,
                pData: buffer.baseAddress, wLenDone: 0, noDataTimeout: 250, completionTimeout: 250
            )
            return interface.pointee?.pointee.DeviceRequestTO(interface, &request) == kIOReturnSuccess && request.wLenDone == 1
        }
        return done ? control : nil
    }
}
