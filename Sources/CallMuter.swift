import AppKit
import ApplicationServices
import os

/// A call app whose own mic toggle Vaux can press in solo mode.
struct CallApp: Sendable, Hashable {
    /// Where the app's mic toggle is.
    enum Surface: Sendable, Hashable {
        /// In the app's windows. Electron builds that tree only on request.
        case window
        /// A menu item: there whatever the call window is doing (toolbar
        /// hidden, minimized), so it's preferred.
        case menuBar
        /// A web page, in whatever browser `bundleID` names.
        case webPage
    }

    let name: String
    let bundleID: String
    /// What uses the mic during a call, which is how a call is told apart:
    /// the app or its helpers, unless the system does it for the app.
    var micBundleID: String { micProcess ?? bundleID }
    private var micProcess: String?
    /// Lowercased accessibility labels of the app's mic toggle. A "mute" label
    /// may be a toggle reporting state in AXValue; an "unmute" label means the
    /// mic is currently muted.
    let muteLabels: Set<String>
    let unmuteLabels: Set<String>
    /// Roles the toggle can have. Narrower is safer: a plain "Mute" button
    /// could be a video's.
    var roles: Set<String>
    var surface: Surface

    init(name: String, bundleID: String, micProcess: String? = nil,
         muteLabels: Set<String>, unmuteLabels: Set<String>,
         roles: Set<String> = [kAXButtonRole, kAXCheckBoxRole], surface: Surface = .window) {
        self.name = name
        self.bundleID = bundleID
        self.micProcess = micProcess
        self.muteLabels = muteLabels
        self.unmuteLabels = unmuteLabels
        self.roles = roles
        self.surface = surface
    }

    /// For logs: which browser a web call is in.
    var logName: String { surface == .webPage ? "\(name) (\(bundleID))" : name }

    /// Google Meet in a browser. Any browser: the page and its labels are the
    /// same in all of them, and both engines (Chromium, WebKit) pass the
    /// labels through. Meet keeps the mic while muted.
    static func meet(in browser: String) -> CallApp {
        CallApp(
            name: "Google Meet", bundleID: browser,
            muteLabels: ["turn off microphone"], unmuteLabels: ["turn on microphone"],
            roles: [kAXButtonRole], surface: .webPage)
    }

    /// Whether an app is a web browser: one that opens web links.
    static func isBrowser(_ bundleID: String) -> Bool {
        guard let web = URL(string: "https://example.com") else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: web).contains { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    /// Every call app and the processes their calls use.
    static var bundleIDs: Set<String> { Set(all.flatMap { [$0.bundleID, $0.micBundleID] }) }

    static let all: [CallApp] = [
        CallApp(
            name: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            muteLabels: ["mute", "mute mic", "mute microphone", "turn off microphone"],
            unmuteLabels: ["unmute", "unmute mic", "unmute microphone", "turn on microphone"]),
        // Discord's user-panel mic button: an AXSwitch described "Mute", AXValue 1 = muted.
        CallApp(
            name: "Discord", bundleID: "com.hnc.Discord",
            muteLabels: ["mute"], unmuteLabels: ["unmute"], roles: [kAXCheckBoxRole]),
        // Meeting menu. Its title follows a press about a second later.
        CallApp(
            name: "Zoom", bundleID: "us.zoom.xos",
            muteLabels: ["mute audio"], unmuteLabels: ["unmute audio"],
            roles: [kAXMenuItemRole], surface: .menuBar),
        // Video menu: "Mute" gets a checkmark when muted. The call's audio
        // runs in a system daemon, which keeps the mic while muted.
        CallApp(
            name: "FaceTime", bundleID: "com.apple.FaceTime", micProcess: "com.apple.avconferenced",
            muteLabels: ["mute"], unmuteLabels: [],
            roles: [kAXMenuItemRole], surface: .menuBar),
    ]
}

/// Mutes call apps through their own UI (Accessibility) — never the audio path.
///
/// Core Audio can't mute another process's input: every per-process mute
/// (`kAudioHardwarePropertyProcessInputMute`, `kAudioDevicePropertyProcessMute`,
/// hog mode) applies only to the caller. So solo mode presses the app's own
/// mic toggle instead, which also shows you as muted to the call.
///
/// Every call here is synchronous AX IPC (plus short waits) — run on `queue`,
/// never the main thread.
enum CallMuter {
    static let queue = DispatchQueue(label: "dev.imathis.vaux.calls", qos: .userInitiated)
    private static let log = Logger(subsystem: "dev.imathis.vaux", category: "solo")

    enum Outcome: Sendable, Equatable {
        /// Not running, not in a call, or (unmuting) the call has ended.
        case notInCall
        case alreadyMuted
        case alreadyLive
        case muted
        case unmuted
        /// In a call, but the toggle couldn't be found or didn't respond.
        case failed
        /// On the mic, but no call was found there: a web page that isn't one.
        case notFound
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (once per app; afterwards it's a no-op).
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Mute or unmute each app, all at once: each waits only on its own app.
    static func set(_ apps: [CallApp], muted: Bool) -> [(app: CallApp, outcome: Outcome)] {
        let outcomes = OSAllocatedUnfairLock(initialState: [Outcome](repeating: .notInCall, count: apps.count))
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let outcome = set(apps[i], muted: muted)
            outcomes.withLock { $0[i] = outcome }
        }
        return zip(apps, outcomes.withLock { $0 }).map { (app: $0, outcome: $1) }
    }

    /// Our last press per app, until the app shows it. A press acts at once,
    /// but an Electron app in the background can hold its accessibility
    /// updates (Slack: until it's next brought forward), so its toggle reads
    /// the old state. Until it catches up, the press is the truth.
    private static let pending = OSAllocatedUnfairLock(initialState: [String: (muted: Bool, press: Int)]())
    private static let presses = OSAllocatedUnfairLock(initialState: 0)
    private static let watchQueue = DispatchQueue(label: "dev.imathis.vaux.calls.watch", attributes: .concurrent)

    /// The call ended: whatever we pressed no longer says anything about the next one.
    static func forget(_ app: CallApp) {
        pending.withLock { $0[app.bundleID] = nil }
    }

    private static func set(_ app: CallApp, muted target: Bool) -> Outcome {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
        else { return .notInCall }
        let capturing = CaptureWatcher.isCapturing(app.micBundleID)
        // Only touch apps that are capturing: Discord's mic toggle exists (and
        // plays a sound) even outside a call.
        if target, !capturing { return .notInCall }
        let action = target ? "mute" : "unmute"
        let pid = running.processIdentifier
        let ax = axApp(pid)

        // Electron only builds its AX tree on request. Keep it while the app is
        // in a call (see `setTreeEnabled`) or muted by us; otherwise switch it
        // off so the app doesn't pay for it.
        let electron = app.surface == .window
        if electron { setFlag(ax, manualAccessibility, true) }
        var keepTree = false
        defer {
            if electron, !keepTree, !CaptureWatcher.isCapturing(app.micBundleID) {
                setFlag(ax, manualAccessibility, false)
            }
        }

        let expected = pending.withLock { $0[app.bundleID]?.muted }
        guard let current = poll(app, ax, pid: pid, assume: expected) else {
            log.notice("\(app.logName, privacy: .public) \(action, privacy: .public): toggle not found (active \(running.isActive))")
            // A browser on the mic may not be in a call at all.
            if app.surface == .webPage, target { return .notFound }
            // Still capturing means still in the call: say so rather than skip.
            return target || capturing ? .failed : .notInCall
        }
        if current.muted == target { return target ? .alreadyMuted : .alreadyLive }

        let focus = app.surface == .menuBar ? nil : Focus(of: ax)
        let pressed = AXUIElementPerformAction(current.element, kAXPressAction as CFString)
        focus?.restore()
        log.notice("\(app.logName, privacy: .public) \(action, privacy: .public): press \(pressed.rawValue) (active \(running.isActive), assumed \(expected != nil))")
        guard pressed == .success else { return .failed }

        let press = presses.withLock { $0 += 1; return $0 }
        pending.withLock { $0[app.bundleID] = (target, press) }
        watchQueue.async { watch(app, pid: pid, muted: target, press: press) }
        keepTree = target
        return target ? .muted : .unmuted
    }

    /// Clears a pending press once the app shows it — or a newer press or the
    /// call's end makes it moot. Quick checks at first (in front, apps show it
    /// at once), then a slow one while the app sits in the background, reading
    /// just the toggle and only re-searching if it's replaced.
    private static func watch(_ app: CallApp, pid: pid_t, muted target: Bool, press: Int) {
        let ax = axApp(pid)
        let start = Date()
        var toggle: AXUIElement?
        var checks = 0
        while pending.withLock({ $0[app.bundleID]?.press == press }) {
            guard CaptureWatcher.isCapturing(app.micBundleID) else { forget(app); return }
            checks += 1
            if toggle == nil || checks % 10 == 0 { toggle = findToggle(app, in: ax)?.element }
            if let element = toggle {
                let elapsed = Date().timeIntervalSince(start)
                switch micState(element, role: string(element, kAXRoleAttribute), app) {
                case .some(.some(let muted)) where muted == target || (elapsed > 1 && isFrontmost(ax)):
                    // In front the app reports at once, so a differing state is
                    // real: changed by hand. Either way its reading is good again.
                    pending.withLock { if $0[app.bundleID]?.press == press { $0[app.bundleID] = nil } }
                    log.notice("\(app.logName, privacy: .public) shows \(muted ? "muted" : "live", privacy: .public) after \(elapsed, format: .fixed(precision: 1))s")
                    return
                case .none: toggle = nil // replaced or relabeled: search again
                default: break
                }
            }
            Thread.sleep(forTimeInterval: Date().timeIntervalSince(start) < 2 ? 0.2 : 1)
        }
    }

    /// Chromium's AXPress focuses the button before clicking it, pulling the
    /// caret out of e.g. a message box you're about to dictate into. This puts
    /// text focus and selection back (not other focus — refocusing a window
    /// could raise it). Unconditionally: in the background the app may not
    /// report the focus change yet. Actions reach the page in order, so this
    /// lands after the press.
    private struct Focus {
        let element: AXUIElement
        let selection: AnyObject

        init?(of ax: AXUIElement) {
            guard let focused = CallMuter.element(ax, kAXFocusedUIElementAttribute) else { return nil }
            element = focused
            guard let selection = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
            self.selection = selection
        }

        func restore() {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection)
        }
    }

    /// Build (or drop) an Electron app's AX tree ahead of time. A cold tree
    /// takes ~2s before its toggle states read, which would delay solo's mute —
    /// so the tree is kept warm while the app is in a call.
    static func setTreeEnabled(_ enabled: Bool, for app: CallApp) {
        guard app.surface == .window, let pid = pid(of: app) else { return }
        setFlag(axApp(pid), manualAccessibility, enabled)
    }

    private static var manualAccessibility: CFString { "AXManualAccessibility" as CFString }
    private static var enhancedUserInterface: CFString { "AXEnhancedUserInterface" as CFString }

    /// Web-call work that waits on a page, kept off `queue` so solo never
    /// waits behind it.
    static let webQueue = DispatchQueue(label: "dev.imathis.vaux.calls.web", qos: .userInitiated)
    /// Browsers whose full tree Vaux switched on, to switch off again.
    private static let enhanced = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// An app Vaux doesn't know started (or stopped) using the mic. If it's
    /// showing a web call, get its tree ready now: Chromium's reduced tree
    /// shows the toggle but can't press it, and the full one, switched on
    /// the way a screen reader does, takes ~2s to build. Off again once the
    /// mic is released.
    static func setWebTreeEnabled(_ enabled: Bool, for app: CallApp) {
        guard let pid = pid(of: app) else { return }
        let ax = axApp(pid)
        guard enabled else {
            if enhanced.withLock({ $0.remove(pid) }) != nil { setFlag(ax, enhancedUserInterface, false) }
            return
        }
        // The page may still be loading.
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if let found = findToggle(app, in: ax) {
                if !found.pressable { buildFullTree(app, ax, pid: pid) }
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Switch on a browser's full tree, for a toggle it shows but can't press.
    private static func buildFullTree(_ app: CallApp, _ ax: AXUIElement, pid: pid_t) {
        // Already on: a screen reader's, so it's left to it.
        guard bool(ax, enhancedUserInterface as String) != true else { return }
        log.notice("\(app.logName, privacy: .public): building full tree")
        setFlag(ax, enhancedUserInterface, true)
        enhanced.withLock { _ = $0.insert(pid) }
    }

    /// Quitting: switch off every full tree Vaux switched on.
    static func releaseWebTrees() {
        for pid in enhanced.withLock({ all in defer { all = [] }; return all }) {
            setFlag(axApp(pid, timeout: 0.5), enhancedUserInterface, false)
        }
    }

    /// Re-searches until the toggle can be pressed and has a readable state.
    /// A fresh search each time because the web view may replace the
    /// button's node when it flips. The tree builds within a fraction of a
    /// second of enabling, but a switch's AXValue reads "" for ~2s after that.
    /// With `assume`, the state is known already: just find the toggle.
    private static func poll(_ app: CallApp, _ ax: AXUIElement, pid: pid_t, assume: Bool?) -> (element: AXUIElement, muted: Bool)? {
        let start = Date()
        while true {
            let found = findToggle(app, in: ax)
            if let found, found.pressable, let muted = assume ?? found.muted {
                return (found.element, muted)
            }
            // A browser not ready yet (the call started before Vaux did).
            if let found, !found.pressable, app.surface == .webPage { buildFullTree(app, ax, pid: pid) }
            let elapsed = Date().timeIntervalSince(start)
            if (found == nil && elapsed > 1) || elapsed > 4 { return nil }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// First control carrying one of the app's mic-toggle labels, with
    /// its state if readable yet, and whether it can be pressed yet: a
    /// reduced tree (Chromium's) reports presses as done and drops them.
    private static func findToggle(_ app: CallApp, in ax: AXUIElement) -> (element: AXUIElement, muted: Bool?, pressable: Bool)? {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> (element: AXUIElement, muted: Bool?, pressable: Bool)? {
            visited += 1
            guard visited < 20_000, depth < 80 else { return nil }
            let role = string(element, kAXRoleAttribute)
            if app.roles.contains(role), let state = micState(element, role: role, app) {
                return (element, state, canPress(element))
            }
            for child in children(element) {
                if let hit = walk(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        if app.surface == .menuBar {
            return element(ax, kAXMenuBarAttribute).flatMap { walk($0, depth: 0) }
        }
        for window in children(ax, attribute: kAXWindowsAttribute) {
            if let hit = walk(window, depth: 0) { return hit }
        }
        return nil
    }

    /// nil = not the app's mic toggle; .some(nil) = it is, but its state isn't
    /// readable yet; .some(true) = muted; .some(false) = live.
    private static func micState(_ element: AXUIElement, role: String, _ app: CallApp) -> Bool?? {
        let description = string(element, kAXDescriptionAttribute)
        let label = (description.isEmpty ? string(element, kAXTitleAttribute) : description)
            .trimmingCharacters(in: .whitespaces).lowercased()
        if app.unmuteLabels.contains(label) { return .some(true) }
        guard app.muteLabels.contains(label) else { return nil }
        switch role {
        case kAXCheckBoxRole:
            // A toggle keeps its "Mute" label and reports on/off in AXValue —
            // a number once Chromium has filled it in.
            guard let value = attribute(element, kAXValueAttribute) as? NSNumber else { return .some(nil) }
            return .some(value.intValue == 1)
        case kAXMenuItemRole:
            // A "Mute" item may stay put and get checked instead.
            return .some(!string(element, kAXMenuItemMarkCharAttribute).isEmpty)
        default:
            // A plain "Mute" button means live.
            return .some(false)
        }
    }

    // MARK: AX helpers

    private static func pid(of app: CallApp) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.processIdentifier
    }

    private static func axApp(_ pid: pid_t, timeout: Float = 1) -> AXUIElement {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, timeout)
        return ax
    }

    private static func setFlag(_ element: AXUIElement, _ name: CFString, _ on: Bool) {
        AXUIElementSetAttributeValue(element, name, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func canPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        return (actions as? [String])?.contains(kAXPressAction) ?? false
    }

    private static func isFrontmost(_ ax: AXUIElement) -> Bool {
        bool(ax, kAXFrontmostAttribute) ?? false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private static func children(_ element: AXUIElement, attribute name: String = kAXChildrenAttribute) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }
}
