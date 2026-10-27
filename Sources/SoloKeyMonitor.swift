import AppKit
import Carbon.HIToolbox

/// Follows macOS Dictation for solo by its 🎤 Dictation key, when that's what
/// you dictate with: macOS Dictation's own mic use can't be seen, but the key
/// starts and stops it. The key isn't claimed as a hotkey, so macOS still gets
/// it and the two stay in step. While a solo the key started is on, this also
/// watches Escape, which ends dictation, so solo ends with it.
///
/// Carbon hotkeys (KeyboardShortcuts) can't do this: they swallow the key. So
/// this is a listen-only event tap at the HID level. It has to sit that low:
/// other apps' session-level taps can swallow keys, so NSEvent monitors miss
/// them. Needs Accessibility (solo already has it). Key presses are watched
/// only while the 🎤 key or Escape matters, and only those two keys are looked
/// at.
@MainActor
final class SoloKeyMonitor {
    /// The 🎤 key on Apple keyboards (top row, F5). Not in Carbon's key list.
    nonisolated fileprivate static let dictationKeyCode = 176

    /// Watch Escape: on while a solo started by the key is on.
    var watchesEscape = false {
        didSet { if watchesEscape != oldValue { update() } }
    }

    private let onKey: () -> Void
    private let onEscape: () -> Void
    private var eventTap: CFMachPort?
    private var relay: TapRelay?

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
                    self?.stopTap() // a tap made before the change may be dead
                    self?.update()
                }
            }
        }
        update()
    }

    /// A tap only while one of the two keys matters.
    private func update() {
        let needed = Self.followsDictationKey || watchesEscape
        guard needed != (eventTap != nil) else { return }
        stopTap()
        if needed { startTap() }
    }

    private func stopTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let relay { TapRelay.release(relay) }
        eventTap = nil
        relay = nil
    }

    private func startTap() {
        let relay = TapRelay { [weak self] keyCode, isRepeat in
            self?.handle(keyCode: keyCode, isRepeat: isRepeat)
        }
        // Listen-only is preferred; it can need Input Monitoring, so fall back
        // to a pass-through tap, which Accessibility alone allows.
        var tap: CFMachPort?
        for options in [CGEventTapOptions.listenOnly, .defaultTap] where tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                callback: TapRelay.callback,
                userInfo: Unmanaged.passUnretained(relay).toOpaque()
            )
        }
        guard let tap else { return } // no Accessibility yet; retried when it's granted
        relay.tap = tap
        CFRunLoopAddSource(TapRelay.runLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        eventTap = tap
        self.relay = relay
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

/// Runs the event tap on a thread of its own and hands the keys it cares
/// about to the main thread. The fallback tap is active: every keystroke in
/// the system waits for its callback, so that must never wait on main-thread
/// work.
private final class TapRelay: @unchecked Sendable {
    typealias Handler = @MainActor (_ keyCode: Int, _ isRepeat: Bool) -> Void

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
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Of key presses only two matter; the rest never leave this thread.
            guard keyCode == SoloKeyMonitor.dictationKeyCode || keyCode == kVK_Escape else { break }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.handler(keyCode, isRepeat) }
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Let go of a relay on the tap thread, after any callback in progress.
    /// Not from main-actor code: the block runs on the tap thread.
    static func release(_ relay: TapRelay) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { withExtendedLifetime(relay) {} }
        CFRunLoopWakeUp(runLoop)
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
