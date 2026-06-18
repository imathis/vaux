# Build Brief: Minimal Mic-Mute Menu Bar App (macOS)

A handoff spec for Claude Code. Build this **on the Mac** (it has to compile and run there). The goal is a tiny, single-purpose menu bar app that toggles mute on the **current default input device** via a global keyboard shortcut, with a configurable unmute volume. It is a clean rewrite — `satrik/toggleMute` (MIT) is fine to consult for the Core Audio calls, but do not copy its AppKit/Touch Bar structure; this is a modern SwiftUI app.

---

## 1. Why this exists (the constraints that matter most)

Every off-the-shelf mic app the user tried caused Bluetooth latency or garbled audio because they insert themselves into the audio path. **This app must not do that.**

**Hard rules — non-negotiable:**

- **Never open an audio stream.** No `AVAudioEngine`, `AVCaptureSession`, `AudioUnit`, no I/O procs, no virtual/aggregate devices, no monitoring.
- The app interacts with audio **only** through Core Audio HAL property reads/writes/listeners (`AudioObjectGetPropertyData`, `AudioObjectSetPropertyData`, `AudioObjectAddPropertyListenerBlock`). That's it.
- **No microphone permission.** Because we never capture audio, setting HAL properties does **not** trigger TCC. Do **not** add `NSMicrophoneUsageDescription` and do not request mic access — adding it would cause a needless permission prompt.
- Operate on the **default input device**, resolved live. Do not hardcode a device. When the user changes the system input, the app follows it automatically.
- Stay tiny. No analytics, no networking, no auto-update framework.

---

## 2. Tech stack & targets

- **SwiftUI**, `MenuBarExtra` scene (requires **macOS 13 Ventura** minimum — set the deployment target there or higher).
- Menu-bar-only app: set `LSUIElement` = `YES` in Info.plist (no Dock icon, no main window).
- One dependency via Swift Package Manager: **KeyboardShortcuts** by Sindre Sorhus — `https://github.com/sindresorhus/KeyboardShortcuts` (pin to 2.x). It registers user-customizable global hotkeys, works while a menu bar menu is open, and — per its docs — does **not** trigger any permission dialog (it uses the still-supported Carbon hotkey API under the hood). No Accessibility permission required.
- Create as an **Xcode app project** (macOS App template, SwiftUI lifecycle). Easiest path for Info.plist + signing.

---

## 3. Suggested file layout

```
MicMute/
  MicMuteApp.swift      // @main App: MenuBarExtra + Settings scene, owns AppState
  AppState.swift        // @Observable: muted, deviceName, unmuteVolume; toggle(); hotkey wiring
  AudioController.swift // Core Audio: resolve default input, read name, get/set mute, set volume, device-change listener
  SettingsView.swift    // KeyboardShortcuts.Recorder + unmute-volume slider + launch-at-login toggle
  Info.plist            // LSUIElement = YES
```

---

## 4. Core Audio implementation (the failure-prone part — get these exact)

The two things that are easy to get wrong: the **property scope** (mute/volume live on `kAudioObjectPropertyScopeInput`, not Global) and **mute vs. volume** (prefer the real mute property; fall back to volume 0 only if the device doesn't expose mute). Reference implementation:

```swift
import CoreAudio

enum AudioController {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard err == noErr, let cf = name?.takeRetainedValue() else { return "Unknown input" }
        return cf as String
    }

    private static var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    static func supportsMute(_ id: AudioDeviceID) -> Bool {
        var a = muteAddr; return AudioObjectHasProperty(id, &a)
    }
    static func isMuted(_ id: AudioDeviceID) -> Bool {
        var a = muteAddr; var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v == 1
    }
    static func setMuted(_ muted: Bool, on id: AudioDeviceID) {
        var a = muteAddr; var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // Input volume as a scalar 0.0...1.0 (used for the unmute level, and as the
    // mute fallback on devices that don't expose kAudioDevicePropertyMute).
    private static var volAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    static func setVolume(_ scalar: Float32, on id: AudioDeviceID) {
        var a = volAddr
        guard AudioObjectHasProperty(id, &a) else { return }
        var v = max(0, min(1, scalar))
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
```

**Follow the default input live** — register a property listener so the menu always shows the right device with no polling:

```swift
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
    // re-resolve device, refresh deviceName, resync muted state for the icon
}
```

**Toggle logic** (in AppState): prefer mute, apply unmute volume on the way back, fall back to volume-0 if no mute property:

```swift
func toggle() {
    guard let dev = AudioController.defaultInputDevice() else { return }
    if AudioController.supportsMute(dev) {
        let next = !AudioController.isMuted(dev)
        AudioController.setMuted(next, on: dev)
        if !next { AudioController.setVolume(Float32(unmuteVolume), on: dev) } // reassert level
        muted = next
    } else {
        muted.toggle()
        AudioController.setVolume(muted ? 0 : Float32(unmuteVolume), on: dev)
    }
}
```

> Note: `unmuteVolume` here is a scalar `0.0...1.0`. macOS's "input volume 0–100" maps to this divided by 100.

---

## 5. Hotkey

```swift
import KeyboardShortcuts
extension KeyboardShortcuts.Name { static let toggleMicMute = Self("toggleMicMute") }
```

- In `AppState.init`: `KeyboardShortcuts.onKeyDown(for: .toggleMicMute) { [weak self] in self?.toggle() }` (key-down feels snappier than key-up).
- In `SettingsView`: `KeyboardShortcuts.Recorder("Toggle mic mute:", name: .toggleMicMute)` — it persists the chosen shortcut in UserDefaults automatically and warns on conflicts.

---

## 6. UI

- **Menu bar icon** reflects state: SF Symbols `mic.fill` when live, `mic.slash.fill` when muted; tint the muted state red. Update whenever `muted` changes (including from the device-change listener).
- **MenuBarExtra menu** (`.menuBarExtraStyle(.menu)`) contains, top to bottom:
  - A non-interactive line showing the active device, e.g. `Input: Wave:3` (this is the "what will it toggle" readout the user wanted).
  - `Mute` / `Unmute` toggle item (mirrors the hotkey).
  - `Settings…` (opens the Settings scene).
  - `Quit`.
- **Settings scene** (`Settings { SettingsView() }`, opens with ⌘,): the `KeyboardShortcuts.Recorder`, an unmute-volume slider (0–100% shown, stored as scalar), and the launch-at-login toggle.

---

## 7. Persistence & launch at login

- Store `unmuteVolume` with `@AppStorage("unmuteVolume")` (default `0.75`). KeyboardShortcuts handles its own persistence.
- Launch at login: use `ServiceManagement`'s `SMAppService.mainApp.register()` / `.unregister()` behind a toggle. No helper target or login-item entitlement needed on macOS 13+.

---

## 8. Build & run (kills the "damaged" problem)

The prebuilt binary threw a "damaged" Gatekeeper error because it was an unsigned, quarantined download. A locally compiled app never gets the quarantine flag, so this avoids that entirely.

1. Open the project in **Xcode** (full Xcode, not just command-line tools).
2. Signing & Capabilities → **Automatically manage signing** → select the personal team, or set signing to **"Sign to Run Locally."** No paid Apple Developer account required for local use.
3. Confirm deployment target ≥ macOS 13 and `LSUIElement = YES`.
4. Build & run (⌘R). It should appear in the menu bar with no Dock icon and no permission prompts.

---

## 9. Test checklist

- [ ] Wave:3 set as default input. Open System Settings → Sound → Input; trigger the hotkey and confirm the input level drops to 0 on mute and returns to the configured unmute level. Confirm the menu and icon reflect state.
- [ ] Toggle from both the hotkey and the menu item; they stay in sync.
- [ ] Change the default input to another device (e.g. built-in mic); confirm the menu's `Input:` line updates automatically and the toggle now acts on the new device.
- [ ] **AirPods caveat:** with AirPods as input, test the toggle but expect possible imperfection — AirPods force the Bluetooth hands-free profile and their software volume/mute over BT is historically flaky. The mute property has better odds than volume-0; note in the menu if mute is unsupported on the current device.
- [ ] With Bluetooth headphones as **output**, run the app and toggle repeatedly: confirm zero effect on playback audio quality or latency (the app must never touch output or open a stream).
- [ ] Quit from the menu; relaunch; confirm shortcut and unmute volume persisted.

---

## 10. Explicitly out of scope (do not build)

- Decaying toast / HUD notifications — the menu bar icon is the state indicator. Skip.
- Touch Bar support.
- Push-to-talk.
- Per-app or system-wide muting, multiple-device handling, audio routing.
