# Vaux

**Talk to your Mac. Not the meeting.**

Vaux is a mic manager for meetings and dictation. One shortcut mutes the call
while your mic stays live for dictation. Plus mute from anywhere, your mics in
priority order, and nothing ever recorded.

It never touches your audio stream. There are no virtual or aggregate devices,
no HAL plugins, and no capture — only Core Audio property changes. That means no
Bluetooth quality drop, no added latency, and no microphone permission.

## Features

### Solo mode

For dictating during a call, on the same mic. Solo mode:

- Mutes **Slack** and **Discord** by pressing their own mute buttons, so the
  call sees you as muted and doesn't hear you dictate.
- Keeps your mic live for everything else, unmuting it if Vaux had it muted.
- Pauses music or video that's playing, and plays it again when solo ends.
  (macOS Dictation does this itself, so Vaux leaves media alone when the 🎤
  key starts solo.)
- Optionally lowers your speakers while it's on, so less of the call bleeds into
  the mic.
- Puts everything back when it ends: it unmutes only the apps it muted and
  leaves your speakers alone if you changed the volume yourself.

Start solo from the menu, a shortcut, or automatically while your dictation app
is listening. Or share a key with dictation, so one press starts both: the 🎤
Dictation key (the default, which starts macOS Dictation) or a tap of a
right-side modifier on its own (e.g. Right ⌥, for apps like FluidVoice). When
the shared key starts solo, Escape, which ends dictation, ends solo too.

macOS can't mute one app's microphone for another app without a virtual audio
device, so solo works the other way around: it mutes the call apps in their own
UI. That's why it supports specific apps rather than "everything but X".

### Mute

- One click or one shortcut mutes the current input. Unmuting restores a set
  volume, per input if you like.
- Devices without a hardware mute are muted by setting their volume to zero.
- Vaux follows the system default input live, and keeps it muted if you switch
  inputs while muted.
- The menu bar icon always shows the real state, even when mute is changed in
  System Settings or another app.

### Preferred inputs

- Turn on auto switch and rank your mics in Settings. Vaux switches to the
  highest-ranked one that's connected as devices come and go.
- The menu lists every input, marks the preferred one, and has an input volume
  slider and an auto switch toggle.

## Permissions

- **Mute and inputs:** none. Changing Core Audio properties doesn't trigger
  the microphone permission prompt.
- **Solo mode:** Accessibility, to press mute in Slack and Discord, and to
  notice the key you share with dictation. Vaux reacts only to that key and
  Escape, and ignores every other key.
- **Call and dictation detection:** none. Vaux reads which apps are using the
  mic from Core Audio's process list, without opening the mic itself.

## Usage

- The menu bar icon shows the state: voice bars when live, flat dots when
  muted, and three bars between two dots in solo (orange if something couldn't
  be muted).
- **Click** the icon to open the menu. **Shift-, Option- or Control-click** it
  to toggle mute.
- **Settings:** solo mode, mute, preferred inputs, and launch at login.

## Requirements

- macOS 26+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and run

The Xcode project is generated from [`project.yml`](project.yml) and isn't
checked in. Generate it first:

```sh
make open      # generate the project and open it in Xcode, then ⌘R
make run       # build and launch from the command line
```

On first build, Xcode resolves the one dependency,
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), via SPM.

To sign with your own team, set `DEVELOPMENT_TEAM` in `project.yml` and `TEAM`
in the `Makefile`. A free personal team is enough for local use.

If `xcode-select` points at the Command Line Tools, select Xcode first, or
prefix the command:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make run`.

### App Store builds

The App Sandbox entitlements are in `Sources/Vaux.entitlements` and are off by
default; see the comment in `project.yml`. Mute and inputs work sandboxed, but
solo mode doesn't, because the sandbox blocks Accessibility control of other
apps.

## Layout

```
project.yml                  # XcodeGen spec: deployment target, signing, SPM
Makefile                     # gen / open / build / run / clean
Sources/
  main.swift                 # entry point
  AppDelegate.swift          # status item, clicks, Settings window
  StatusIcon.swift           # menu bar glyph: live, muted, solo
  StatusIconAnimator.swift   # springs the glyph between states
  MenuPanelController.swift  # the custom glass menu panel
  MenuContentView.swift      # menu: volume, inputs, mute, solo, settings
  SettingsView.swift         # Settings
  AppState.swift             # mute intent, device tracking, solo mode
  AudioController.swift      # Core Audio HAL: devices, mute, volume, processes
  CallMuter.swift            # presses Slack/Discord mute via Accessibility
  CaptureWatcher.swift       # which apps are using the mic
  MediaPauser.swift          # pauses playing media during solo
  SoloKeyMonitor.swift       # solo key shared with dictation, and Escape
  SoloShortcutRecorder.swift # solo shortcut field (combos and modifier taps)
  InputVolumeView.swift      # volume slider
  InputPriorityModel.swift   # preferred-input list (Settings)
  PreferredInput.swift       # preferred-input order storage
  LaunchAtLogin.swift        # SMAppService wrapper
  Shortcuts.swift            # KeyboardShortcuts names
  AppStorageKey.swift        # shared settings keys
  Info.plist                 # LSUIElement: menu bar only, no Dock icon
  Vaux.entitlements          # App Sandbox (off by default)
IconSource/                  # app icon layer art for Icon Composer
```

## Non-goals

No virtual audio devices or HAL plugins, no audio capture or level meters, no
push-to-talk, no HUD, no analytics, no networking, no auto-update.
