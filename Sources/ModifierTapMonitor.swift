import AppKit
import Carbon.HIToolbox

/// Fires on a lone tap of a modifier key: pressed and released with nothing
/// else in between — no other key, modifier, or click. That's the rule
/// FluidVoice uses for its modifier-only trigger (any hold length), so the two
/// can share one key and stay in step.
///
/// Carbon hotkeys (KeyboardShortcuts) can't express modifier-only shortcuts, so
/// this watches modifier changes with a listen-only event tap at the HID level.
/// It has to sit that low: dictation apps' session-level taps swallow their own
/// trigger, so NSEvent monitors never see it. Needs Accessibility (solo already
/// has it). Keystrokes are never observed: "was anything else pressed?" is
/// answered by asking how long ago the last key or click was.
@MainActor
final class ModifierTapMonitor {
    enum Key: String, CaseIterable, Identifiable {
        case off, rightOption, rightCommand, rightControl, rightShift

        var id: String { rawValue }

        /// Shown in the recorder and the menu's shortcut column.
        var symbol: String {
            switch self {
            case .off: ""
            case .rightOption: "Right ⌥"
            case .rightCommand: "Right ⌘"
            case .rightControl: "Right ⌃"
            case .rightShift: "Right ⇧"
            }
        }

        fileprivate var keyCode: Int {
            switch self {
            case .off: -1
            case .rightOption: kVK_RightOption
            case .rightCommand: kVK_RightCommand
            case .rightControl: kVK_RightControl
            case .rightShift: kVK_RightShift
            }
        }

        /// Side-specific flag bit (NX_DEVICER*KEYMASK in IOLLEvent.h).
        fileprivate var deviceBit: UInt64 {
            switch self {
            case .off: 0
            case .rightOption: 0x40
            case .rightCommand: 0x10
            case .rightControl: 0x2000
            case .rightShift: 0x04
            }
        }

        static var current: Key {
            get { UserDefaults.standard.string(forKey: AppStorageKey.soloTapKey).flatMap(Key.init) ?? .off }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: AppStorageKey.soloTapKey) }
        }
    }

    /// Posted (object: the tapped `Key`) instead of firing while a shortcut
    /// recorder is capturing, so the solo recorder can record the tap.
    static let recordedTap = Notification.Name("HushModifierTapRecorded")

    /// KeyboardShortcuts' recorders post this (userInfo "isActive": Bool).
    static let recorderStatus = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    private let onTap: () -> Void
    private var eventTap: CFMachPort?
    private var detector = ModifierTapDetector()
    private var recording = false

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
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
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    /// Only watch modifiers while a tap key is chosen, or one may be recorded.
    private func update() {
        let wanted = Key.current != .off || recording
        guard wanted != (eventTap != nil) else { return }
        if wanted {
            startTap()
        } else if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            detector = ModifierTapDetector()
        }
    }

    private func startTap() {
        // Listen-only is preferred; it can need Input Monitoring, so fall back
        // to a pass-through tap, which Accessibility alone allows.
        let tap = [CGEventTapOptions.listenOnly, .defaultTap].lazy.compactMap { options in
            CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
                callback: { _, type, event, refcon in
                    if let refcon {
                        let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        MainActor.assumeIsolated { monitor.handle(type, event) }
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }.first
        guard let tap else { return } // no Accessibility yet; retried when it's granted
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        eventTap = tap
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = detector.tap(keyCode: keyCode, flags: event.flags.rawValue) else { return }
            if recording {
                NotificationCenter.default.post(name: Self.recordedTap, object: key)
            } else if key == Key.current {
                onTap()
            }
        default:
            break
        }
    }
}

/// Picks lone right-modifier taps out of a stream of modifier changes.
struct ModifierTapDetector {
    /// Every left/right modifier bit, to tell "pressed alone" from a chord.
    private static let sideBits: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    private var pressed: (key: ModifierTapMonitor.Key, at: Date)?

    /// The key, if this change completes a clean tap of it.
    mutating func tap(keyCode: Int, flags: UInt64) -> ModifierTapMonitor.Key? {
        guard let key = ModifierTapMonitor.Key.allCases.first(where: { $0 != .off && $0.keyCode == keyCode }) else {
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
