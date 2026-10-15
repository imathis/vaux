import AppKit
import Carbon.HIToolbox

/// Watches a solo trigger shared with a dictation app: the 🎤 Dictation key
/// (macOS Dictation's) or a lone tap of a right-side modifier (FluidVoice's).
/// Neither is claimed as a hotkey, so the dictation app still gets the key and
/// the two stay in step. While a solo started this way is on, it also watches
/// Escape, which ends dictation in both, so solo ends with it.
///
/// Carbon hotkeys (KeyboardShortcuts) can't do this: they swallow the key, and
/// can't express modifier-only shortcuts. So this is a listen-only event tap at
/// the HID level. It has to sit that low: dictation apps' session-level taps
/// swallow their own trigger, so NSEvent monitors never see it. Needs
/// Accessibility (solo already has it). Key presses are watched only while the
/// Dictation key is the trigger or Escape matters, and only those two keys are
/// looked at. A modifier tap is told apart from typing by asking how long ago
/// the last key or click was, not by watching keys.
@MainActor
final class SoloKeyMonitor {
    enum Key: String, CaseIterable, Identifiable {
        case off, dictation, rightOption, rightCommand, rightControl, rightShift

        var id: String { rawValue }

        /// Shown in the recorder field.
        var symbol: String {
            switch self {
            case .off: ""
            case .dictation: "Dictation Key"
            case .rightOption: "Right ⌥"
            case .rightCommand: "Right ⌘"
            case .rightControl: "Right ⌃"
            case .rightShift: "Right ⇧"
            }
        }

        var isModifier: Bool { self != .off && self != .dictation }

        fileprivate var keyCode: Int {
            switch self {
            case .off: -1
            case .dictation: SoloKeyMonitor.dictationKeyCode
            case .rightOption: kVK_RightOption
            case .rightCommand: kVK_RightCommand
            case .rightControl: kVK_RightControl
            case .rightShift: kVK_RightShift
            }
        }

        /// Side-specific flag bit (NX_DEVICER*KEYMASK in IOLLEvent.h).
        fileprivate var deviceBit: UInt64 {
            switch self {
            case .off, .dictation: 0
            case .rightOption: 0x40
            case .rightCommand: 0x10
            case .rightControl: 0x2000
            case .rightShift: 0x04
            }
        }

        /// Unset means the Dictation key: macOS Dictation's own trigger, so solo
        /// works with it out of the box.
        static var current: Key {
            get {
                guard let raw = UserDefaults.standard.string(forKey: AppStorageKey.soloTapKey) else { return .dictation }
                return Key(rawValue: raw) ?? .off
            }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: AppStorageKey.soloTapKey) }
        }
    }

    /// The 🎤 key on Apple keyboards (top row, F5). Not in Carbon's key list.
    nonisolated fileprivate static let dictationKeyCode = 176

    /// Posted (object: the pressed `Key`) instead of firing while a shortcut
    /// recorder is capturing, so the solo recorder can record it.
    static let recordedTap = Notification.Name("VauxSoloKeyRecorded")

    /// KeyboardShortcuts' recorders post this (userInfo "isActive": Bool).
    static let recorderStatus = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    /// Watch Escape: on while a solo started by the key is on.
    var watchesEscape = false {
        didSet { if watchesEscape != oldValue { update() } }
    }

    private let onKey: () -> Void
    private let onEscape: () -> Void
    private var eventTap: CFMachPort?
    /// The events the tap was created for; 0 when there's no tap.
    private var tapMask: CGEventMask = 0
    private var relay: TapRelay?
    private var detector = ModifierTapDetector()
    private var recording = false

    init(onKey: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.onKey = onKey
        self.onEscape = onEscape
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NotificationCenter.default.addObserver(
            forName: Self.recorderStatus, object: nil, queue: .main
        ) { [weak self] note in
            let active = note.userInfo?["isActive"] as? Bool ?? false
            MainActor.assumeIsolated {
                self?.recording = active
                self?.update()
            }
        }
        // Accessibility was granted or revoked: the tap may work now.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new trust state lands a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    self?.stopTap() // a tap made before the change may be dead
                    self?.update()
                }
            }
        }
        update()
    }

    /// Watch only what the trigger needs: modifier changes for a modifier tap,
    /// key presses for the Dictation key or Escape. Both while recording.
    private func update() {
        let key = Key.current
        var mask: CGEventMask = 0
        if key.isModifier || recording { mask |= CGEventMask(1) << CGEventType.flagsChanged.rawValue }
        if key == .dictation || recording || watchesEscape { mask |= CGEventMask(1) << CGEventType.keyDown.rawValue }
        guard mask != tapMask else { return }
        stopTap()
        if mask != 0 { startTap(mask) }
    }

    private func stopTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let relay {
            // Let go of it on the tap thread, after any callback in progress.
            CFRunLoopPerformBlock(TapRelay.runLoop, CFRunLoopMode.commonModes.rawValue) { withExtendedLifetime(relay) {} }
            CFRunLoopWakeUp(TapRelay.runLoop)
        }
        eventTap = nil
        relay = nil
        tapMask = 0
        detector = ModifierTapDetector()
    }

    private func startTap(_ mask: CGEventMask) {
        let relay = TapRelay { [weak self] type, keyCode, flags, isRepeat in
            self?.handle(type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }
        // Listen-only is preferred; it can need Input Monitoring, so fall back
        // to a pass-through tap, which Accessibility alone allows.
        var tap: CFMachPort?
        for options in [CGEventTapOptions.listenOnly, .defaultTap] where tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: TapRelay.callback,
                userInfo: Unmanaged.passUnretained(relay).toOpaque()
            )
        }
        guard let tap else { return } // no Accessibility yet; retried when it's granted
        relay.tap = tap
        CFRunLoopAddSource(TapRelay.runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        eventTap = tap
        self.relay = relay
        tapMask = mask
    }

    private func handle(_ type: CGEventType, keyCode: Int, flags: UInt64, isRepeat: Bool) {
        switch type {
        case .flagsChanged:
            guard let key = detector.tap(keyCode: keyCode, flags: flags) else { return }
            fire(key)
        case .keyDown:
            // Only the key code is read, and only two values mean anything.
            if keyCode == Self.dictationKeyCode, !isRepeat {
                fire(.dictation)
            } else if keyCode == kVK_Escape, watchesEscape {
                onEscape()
            }
        default:
            break
        }
    }

    private func fire(_ key: Key) {
        if recording {
            NotificationCenter.default.post(name: Self.recordedTap, object: key)
        } else if key == Key.current {
            onKey()
        }
    }
}

/// Runs the event tap on a thread of its own and hands the keys it cares
/// about to the main thread. The fallback tap is active: every keystroke in
/// the system waits for its callback, so that must never wait on main-thread
/// work.
private final class TapRelay: @unchecked Sendable {
    typealias Handler = @MainActor (_ type: CGEventType, _ keyCode: Int, _ flags: UInt64, _ isRepeat: Bool) -> Void

    private let handler: Handler
    /// Set once, before the tap is added to the run loop.
    var tap: CFMachPort?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let relay = Unmanaged<TapRelay>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = relay.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            let raw = type.rawValue
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let type = CGEventType(rawValue: raw) else { return }
                    relay.handler(type, keyCode, flags, isRepeat)
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// The tap thread's run loop, started on first use. Adding and removing
    /// sources and waking a run loop are safe from any thread.
    nonisolated(unsafe) static let runLoop: CFRunLoop = {
        final class Box: @unchecked Sendable { var loop: CFRunLoop? }
        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive while no tap is installed.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "dev.imathis.vaux.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return box.loop!
    }()
}

/// Picks lone right-modifier taps out of a stream of modifier changes: pressed
/// and released with nothing else in between — no other key, modifier, or
/// click. That's the rule FluidVoice uses for its modifier-only trigger (any
/// hold length), so the two can share one key and stay in step.
struct ModifierTapDetector {
    /// Every left/right modifier bit, to tell "pressed alone" from a chord.
    private static let sideBits: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    private var pressed: (key: SoloKeyMonitor.Key, at: Date)?

    /// The key, if this change completes a clean tap of it.
    mutating func tap(keyCode: Int, flags: UInt64) -> SoloKeyMonitor.Key? {
        guard let key = SoloKeyMonitor.Key.allCases.first(where: { $0.isModifier && $0.keyCode == keyCode }) else {
            pressed = nil // some other modifier joined in: a chord, not a tap
            return nil
        }
        let sides = flags & Self.sideBits
        if sides & key.deviceBit != 0 {
            // Pressed — arm only if it's the only modifier down.
            pressed = sides == key.deviceBit ? (key, Date()) : nil
            return nil
        }
        defer { pressed = nil }
        guard let pressed, pressed.key == key, !Self.otherInput(since: pressed.at) else { return nil }
        return key
    }

    /// Whether a key or click happened since `date`.
    private static func otherInput(since date: Date) -> Bool {
        let held = Date().timeIntervalSince(date)
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < held }
    }
}
