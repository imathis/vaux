import AppKit
import Carbon.HIToolbox

/// Follows macOS Dictation for solo by its 🎤 Dictation key, when that's what
/// you dictate with: macOS Dictation's own mic use can't be seen, but the key
/// starts and stops it. The key isn't claimed as a hotkey, so macOS still gets
/// it and the two stay in step. While a solo the key started is on, this also
/// watches Escape, which ends dictation, so solo ends with it.
///
/// A `KeyTap`, so needs Accessibility (solo already has it). Key presses are
/// watched only while the 🎤 key or Escape matters, and only those two keys
/// are looked at.
@MainActor
final class SoloKeyMonitor {
    /// The 🎤 key on Apple keyboards (top row, F5). Not in Carbon's key list.
    nonisolated private static let dictationKeyCode = 176

    /// Watch Escape: on while a solo started by the key is on.
    var watchesEscape = false {
        didSet { if watchesEscape != oldValue { update() } }
    }

    private let onKey: () -> Void
    private let onEscape: () -> Void
    private var tap: KeyTap?

    /// You dictate with macOS Dictation, so its key starts solo.
    private static var followsDictationKey: Bool {
        UserDefaults.standard.string(forKey: AppStorageKey.dictateWith) == AppStorageKey.macOSDictation
    }

    init(onKey: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.onKey = onKey
        self.onEscape = onEscape
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

    /// A tap only while one of the two keys matters.
    private func update() {
        let needed = Self.followsDictationKey || watchesEscape
        guard needed != (tap != nil) else { return }
        tap = nil
        guard needed else { return }
        // No Accessibility yet: retried when it's granted.
        tap = KeyTap(events: [.keyDown]) { _, event -> (keyCode: Int, isRepeat: Bool)? in
            // Of key presses only two matter; the rest never leave the tap's
            // thread.
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == Self.dictationKeyCode || keyCode == kVK_Escape else { return nil }
            return (keyCode: keyCode, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        } handle: { [weak self] key in
            self?.handle(keyCode: key.keyCode, isRepeat: key.isRepeat)
        }
    }

    private func handle(keyCode: Int, isRepeat: Bool) {
        // Only the key code is read, and only two values mean anything.
        if keyCode == Self.dictationKeyCode, !isRepeat, Self.followsDictationKey {
            onKey()
        } else if keyCode == kVK_Escape, watchesEscape {
            onEscape()
        }
    }
}
