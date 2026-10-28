import CoreGraphics
import Foundation

/// An event tap at the HID level, for keys Carbon hotkeys (KeyboardShortcuts)
/// can't take: they swallow the key, and can't be a modifier alone. It has
/// to sit that low: other apps' session-level taps can swallow keys, so
/// NSEvent monitors miss them. Listen-only is preferred; it can need Input
/// Monitoring, so it falls back to a pass-through tap, which Accessibility
/// alone allows. Without either there's no tap (nil) until one's granted.
///
/// It runs on a thread of its own: `pick` runs there for each event of the
/// kinds asked for, and hands on only what matters, to `handle` on the main
/// thread. The fallback tap is active: every such event in the system waits
/// for `pick`, so it must be quick and never wait on main-thread work. The
/// tap stops when this goes.
final class KeyTap {
    private let port: CFMachPort
    private let relay: Relay

    init?<Picked: Sendable>(
        events: [CGEventType],
        pick: @escaping @Sendable (CGEventType, CGEvent) -> Picked?,
        handle: @escaping @MainActor (Picked) -> Void
    ) {
        let relay = Relay { type, event in
            guard let picked = pick(type, event) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handle(picked) }
            }
        }
        let mask = events.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        var port: CFMachPort?
        for options in [CGEventTapOptions.listenOnly, .defaultTap] where port == nil {
            port = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: Relay.callback,
                userInfo: Unmanaged.passUnretained(relay).toOpaque()
            )
        }
        guard let port else { return nil }
        relay.port = port
        CFRunLoopAddSource(Relay.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        self.port = port
        self.relay = relay
    }

    deinit {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        Relay.release(relay)
    }
}

/// What the tap calls back into, on the tap's thread.
private final class Relay: @unchecked Sendable {
    let receive: @Sendable (CGEventType, CGEvent) -> Void
    /// Set once, before the tap is added to the run loop.
    var port: CFMachPort?

    init(receive: @escaping @Sendable (CGEventType, CGEvent) -> Void) {
        self.receive = receive
    }

    static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let relay = Unmanaged<Relay>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = relay.port { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            relay.receive(type, event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Lets go of a relay on the tap's thread, after any callback in
    /// progress.
    static func release(_ relay: Relay) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { withExtendedLifetime(relay) {} }
        CFRunLoopWakeUp(runLoop)
    }

    /// The tap's thread's run loop, started on first use. Adding and
    /// removing sources and waking a run loop are safe from any thread.
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
