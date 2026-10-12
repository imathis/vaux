import AppKit
import ApplicationServices

/// A call app whose own mic toggle Hush can press in solo mode.
struct CallApp: Sendable, Hashable {
    let name: String
    let bundleID: String
    /// Lowercased accessibility labels of the app's mic toggle. A "mute" label
    /// may be a toggle reporting state in AXValue; an "unmute" label means the
    /// mic is currently muted.
    let muteLabels: Set<String>
    let unmuteLabels: Set<String>

    static let all: [CallApp] = [
        CallApp(
            name: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            muteLabels: ["mute", "mute mic", "mute microphone", "turn off microphone"],
            unmuteLabels: ["unmute", "unmute mic", "unmute microphone", "turn on microphone"]),
        // Discord's user-panel mic button: an AXSwitch described "Mute", AXValue 1 = muted.
        CallApp(
            name: "Discord", bundleID: "com.hnc.Discord",
            muteLabels: ["mute"], unmuteLabels: ["unmute"]),
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
    static let queue = DispatchQueue(label: "dev.imathis.hush.calls", qos: .userInitiated)

    enum Outcome: Sendable, Equatable {
        /// Not running, not in a call, or (unmuting) the call has ended.
        case notInCall
        case alreadyMuted
        case alreadyLive
        case muted
        case unmuted
        /// In a call, but the toggle couldn't be found or didn't respond.
        case failed
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (once per app; afterwards it's a no-op).
    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func mute(_ app: CallApp) -> Outcome { set(app, muted: true) }
    static func unmute(_ app: CallApp) -> Outcome { set(app, muted: false) }

    private static func set(_ app: CallApp, muted target: Bool) -> Outcome {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first?.processIdentifier else { return .notInCall }
        // Only touch apps that are capturing: Discord's mic toggle exists (and
        // plays a sound) even outside a call.
        if target, !AudioController.isCapturingInput(bundlePrefix: app.bundleID) { return .notInCall }

        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 1)
        // Electron only builds its AX tree on request. Keep it while the app is
        // in a call (see `setTreeEnabled`) or muted by us; otherwise switch it
        // off so the app doesn't pay for it.
        AXUIElementSetAttributeValue(ax, manualAccessibility, kCFBooleanTrue)
        var keepTree = false
        defer {
            if !keepTree, !AudioController.isCapturingInput(bundlePrefix: app.bundleID) {
                AXUIElementSetAttributeValue(ax, manualAccessibility, kCFBooleanFalse)
            }
        }

        guard let current = poll(app, ax, timeout: 4) else { return target ? .failed : .notInCall }
        if current.muted == target { return target ? .alreadyMuted : .alreadyLive }

        guard AXUIElementPerformAction(current.element, kAXPressAction as CFString) == .success,
              poll(app, ax, timeout: 2, want: target) != nil else { return .failed }
        keepTree = target
        return target ? .muted : .unmuted
    }

    /// Build (or drop) an Electron app's AX tree ahead of time. A cold tree
    /// takes ~2s before its toggle states read, which would delay solo's mute —
    /// so the tree is kept warm while the app is in a call.
    static func setTreeEnabled(_ enabled: Bool, for app: CallApp) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first?.processIdentifier else { return }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 1)
        AXUIElementSetAttributeValue(ax, manualAccessibility, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static var manualAccessibility: CFString { "AXManualAccessibility" as CFString }

    /// Re-searches until the toggle has a readable state (matching `want`, if
    /// given). A fresh search each time because the web view may replace the
    /// button's node when it flips. The tree builds within a fraction of a
    /// second of enabling, but a switch's AXValue reads "" for ~2s after that.
    private static func poll(_ app: CallApp, _ ax: AXUIElement, timeout: TimeInterval, want: Bool? = nil)
        -> (element: AXUIElement, muted: Bool)? {
        let start = Date()
        while true {
            let found = findToggle(app, in: ax)
            if let found, let muted = found.muted, want == nil || muted == want {
                return (found.element, muted)
            }
            let elapsed = Date().timeIntervalSince(start)
            if (found == nil && elapsed > 1) || elapsed > timeout { return nil }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// First button/checkbox carrying one of the app's mic-toggle labels, with
    /// its state if readable yet.
    private static func findToggle(_ app: CallApp, in ax: AXUIElement) -> (element: AXUIElement, muted: Bool?)? {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> (element: AXUIElement, muted: Bool?)? {
            visited += 1
            guard visited < 20_000, depth < 80 else { return nil }
            let role = string(element, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXCheckBoxRole,
               let state = micState(element, role: role, app) {
                return (element, state)
            }
            for child in children(element) {
                if let hit = walk(child, depth: depth + 1) { return hit }
            }
            return nil
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
        // A plain "Mute" button means live. A toggle keeps its "Mute" label and
        // reports on/off in AXValue — a number once Chromium has filled it in.
        guard role == kAXCheckBoxRole else { return .some(false) }
        guard let value = attribute(element, kAXValueAttribute) as? NSNumber else { return .some(nil) }
        return .some(value.intValue == 1)
    }

    // MARK: AX helpers

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
