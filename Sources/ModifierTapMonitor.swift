import AppKit
import Carbon.HIToolbox

/// Fires on a lone tap of a right-side modifier key: pressed and let go in
/// under a second with nothing else in between, no other key, modifier,
/// click or scroll. FluidVoice's modifier trigger works the same way.
///
/// Carbon hotkeys can't be a modifier alone, so this watches modifier
/// changes with a `KeyTap` (so needs Accessibility), only while a key is
/// chosen. Keystrokes are never looked at: whether anything else was pressed
/// is answered by asking macOS how long ago the last key or click was.
@MainActor
final class ModifierTapMonitor {
    enum Key: String, CaseIterable, Identifiable, Sendable {
        case off, rightShift, rightOption, rightCommand, rightControl

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .off: ""
            case .rightShift: "Right ⇧"
            case .rightOption: "Right ⌥"
            case .rightCommand: "Right ⌘"
            case .rightControl: "Right ⌃"
            }
        }

        fileprivate var keyCode: Int {
            switch self {
            case .off: -1
            case .rightShift: kVK_RightShift
            case .rightOption: kVK_RightOption
            case .rightCommand: kVK_RightCommand
            case .rightControl: kVK_RightControl
            }
        }

        /// Its side's flag bit (NX_DEVICER*KEYMASK in IOLLEvent.h).
        fileprivate var deviceBit: UInt64 {
            switch self {
            case .off: 0
            case .rightShift: 0x04
            case .rightOption: 0x40
            case .rightCommand: 0x10
            case .rightControl: 0x2000
            }
        }
    }

    /// Where the chosen key is kept.
    let defaultsKey: String
    private let onTap: () -> Void
    private var tap: KeyTap?
    /// The key the tap is for.
    private var watching = Key.off

    var key: Key {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Key.init) ?? .off
    }

    init(defaultsKey: String, onTap: @escaping () -> Void) {
        self.defaultsKey = defaultsKey
        self.onTap = onTap
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Accessibility was granted or revoked: the tap may work now.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new trust state lands a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    self?.tap = nil // a tap made before the change may be dead
                    self?.update()
                }
            }
        }
        update()
    }

    /// A tap for the chosen key, if there is one.
    private func update() {
        let key = key
        guard key != watching || (key != .off && tap == nil) else { return }
        watching = key
        tap = nil
        guard key != .off else { return }
        let detector = Detector(key: key)
        // No Accessibility yet: retried when it's granted.
        tap = KeyTap(events: [.flagsChanged]) { _, event in
            detector.completesTap(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue) ? true : nil
        } handle: { [weak self] _ in
            self?.onTap()
        }
    }
}

/// Picks lone taps of one key out of modifier changes, on the tap's thread
/// (the only one that touches it).
private final class Detector: @unchecked Sendable {
    /// Every left and right modifier bit, to tell pressed alone from a chord.
    private static let sideBits: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000
    /// Held longer, it wasn't a tap.
    private static let longest = 1.0

    private let key: ModifierTapMonitor.Key
    /// When the key went down, alone.
    private var pressed: Date?

    init(key: ModifierTapMonitor.Key) {
        self.key = key
    }

    /// This change lets go of the key, ending a tap.
    func completesTap(keyCode: Int, flags: UInt64) -> Bool {
        guard keyCode == key.keyCode else {
            pressed = nil // another modifier joined in: a chord, not a tap
            return false
        }
        let sides = flags & Self.sideBits
        if sides & key.deviceBit != 0 {
            // Down: counts only if it's the only modifier down.
            pressed = sides == key.deviceBit ? Date() : nil
            return false
        }
        defer { pressed = nil }
        guard let pressed else { return false }
        let held = Date().timeIntervalSince(pressed)
        return held < Self.longest && !Self.otherInput(within: held)
    }

    /// A key, click or scroll in the last `seconds`.
    private static func otherInput(within seconds: Double) -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds }
    }
}
