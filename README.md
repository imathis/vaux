# Hush

A tiny macOS menu bar app that toggles mute on the **current default input
device** via a global keyboard shortcut, with a configurable unmute volume.

It is deliberately single-purpose and stays out of the audio path: it touches
audio **only** through Core Audio HAL property reads/writes/listeners — never
opens a stream, never captures, never inserts a virtual/aggregate device. That
means no Bluetooth latency or garbled audio, and **no microphone permission
prompt** (setting HAL properties doesn't trigger TCC).

## Requirements

- macOS 26+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

The Xcode project is generated from [`project.yml`](project.yml) and is **not**
checked into git — generate it first:

```sh
make open      # xcodegen generate + open in Xcode, then ⌘R
# or
make run       # build and launch from the command line
```

On first build, Xcode resolves the one dependency
([KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)) via SPM.

Signing is automatic with the personal development team (`VFHUHTXW5A`); no paid
Apple Developer account is required for local use. A locally compiled app never
gets the Gatekeeper quarantine flag, so there's no "damaged" error.

## Usage

- Menu bar icon shows state: `mic.fill` live, `mic.slash.fill` (red) muted.
- Click the icon for the menu: active input device, Mute/Unmute, Settings…, Quit.
- **Settings (⌘,):** record the global hotkey, set the unmute volume, toggle
  launch-at-login.
- The app follows the system default input live — change it in System Settings
  and Hush re-targets automatically.

## Layout

```
project.yml              # XcodeGen spec (deployment target, signing, SPM deps)
Sources/
  HushApp.swift          # @main App: MenuBarExtra + Settings scenes
  AppState.swift         # @Observable: muted state, device tracking, toggle()
  AudioController.swift   # Core Audio HAL: device, mute, volume, listeners
  MenuContent.swift      # the menu bar menu
  SettingsView.swift     # hotkey recorder, unmute slider, launch-at-login
  LaunchAtLogin.swift    # SMAppService wrapper
  Shortcuts.swift        # KeyboardShortcuts.Name.toggleMicMute
  AppStorageKey.swift    # shared persistence keys
  Info.plist             # LSUIElement = YES (menu-bar-only, no Dock icon)
```

## Non-goals

No HUD/toast, no Touch Bar, no push-to-talk, no per-app/system-wide muting, no
audio routing, no analytics, no networking, no auto-update.
