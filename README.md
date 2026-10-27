<img src="docs/icon.png" width="128" alt="Vaux app icon">

# Vaux

**Microphone control for the dictation age.**

If you dictate instead of typing, a call shouldn't take that away. But it does.
Start to speak a prompt to your agent, or a quick note, and the meeting hears
it. So you stop and find what to mute, pause what you were listening to, and
hope the call doesn't bleed into your mic. By then the thought is gone.

Vaux solos your voice to your dictation app, the way you'd solo one track on a
mixer, and the rest of the Mac makes room: your calls mute, your media pauses,
and if you like, your speakers come down. When you stop, it all goes back.
Dictation works on a call the way it does anywhere else.

Around that, Vaux manages your mic: one key mutes it everywhere, your mics
switch in the order you rank them, and each comes back at the volume you set.

It never touches your audio stream. There are no virtual or aggregate devices,
no HAL plugins, and no capture — only Core Audio property changes. That means no
Bluetooth quality drop, no added latency, and no microphone permission.

## Install

```sh
brew install --cask imathis/tap/vaux
```

Or download the zip from the latest
[release](https://github.com/imathis/vaux/releases/latest), unzip it, and move
Vaux to Applications. Requires macOS 26 or later.

Vaux lives in the menu bar. While its Settings window is open, it's in the
Dock and ⌘-Tab like any app. To update: `brew upgrade --cask vaux`.

## Features

### Solo mode

Solo is for dictating while you're on a call, on the same mic: your dictation
app hears you, and nothing else does.

Works with **Zoom**, **Google Meet** (in any browser), **FaceTime**, **Slack**
and **Discord**. Solo mode:

- Mutes you in every call you're in by pressing the call's own mute button, so
  everyone sees you as muted and nobody hears you dictate.
- Warns you if another app on the mic can still hear you: the menu bar icon
  turns orange and the menu names the app.
- Keeps your mic live for everything else, unmuting it if Vaux had it muted.
- Pauses music or video that's playing, and plays it again when solo ends.
  (macOS Dictation does this itself, so Vaux leaves media alone when the 🎤
  key starts solo.)
- Optionally lowers your speakers while it's on, so less of the call bleeds into
  the mic.
- Puts everything back when it ends: it unmutes only the apps it muted and
  leaves your speakers alone if you changed the volume yourself.

Tell Vaux what you dictate with, and solo follows it:

- **macOS Dictation** (the default): the 🎤 Dictation key starts and ends solo
  along with dictation, and Escape, which ends dictation, ends solo too. (macOS
  doesn't say when Dictation is listening, so Vaux follows the key.)
- **An app** such as FluidVoice: solo is on while the app is listening.

You can also turn solo on and off from the menu.

#### How it works, and what that means

macOS can't mute your mic for one app but not another without a virtual audio
device, which costs quality and adds latency. So solo works the other way
around: it mutes you inside the call app, through Accessibility. Each app's
mute control is different, so apps are supported one by one. Microsoft Teams
and Webex aren't yet; if one is using the mic, solo warns you.

Google Meet works in browsers built on Chromium (Chrome, Arc, Edge, Brave,
Helium and most others) or WebKit (Safari), but not Firefox yet. The call has
to be the visible tab in its window, since browsers only expose that one.

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

### Vaux Camera (opt-in)

A camera for your video calls: your real camera, passed through in hardware,
with effects on your keys. Off until you turn it on in Settings → Camera.

- **While dictating:** an overlay ("Dictating", or lines of your own) shows
  while solo mode is on, so the call knows why you're talking but muted.
- **Overlays:** text (or just an icon) or graphics (PNG, PDF, SVG), one per
  spot, fading in and out. **Push in:** zoom levels on top of each camera's
  own zoom. **Combos:** overlays, a push-in and a look on one key.
- **Looks:** color over the whole picture, one at a time: white balance,
  saturation, tone (brightness, contrast, highlights, shadows), a three-way
  color grade (hue, saturation and luminance for shadows, midtones and
  highlights), and texture (fade, vignette, film grain). Starts with Noir,
  Black & White, Warm, Vivid, Faded and Teal & Orange; any can be reset.
- **Live:** a small panel for effects on the spot: type a line, pick its
  look and spot, a zoom and a look, and Show puts it all up at once.
- **Keys:** a shortcut per effect, and the **Quick Menu** (⌥. by default): a
  small menu over everything, one more key picks. Tap a key to toggle; hold it
  to show the effect only while held. Mute is in the Quick Menu too (M), and
  Live (L).
- **Cameras:** ranked like mics; Vaux sends the highest-ranked one that's
  connected, or an iPhone set up as a camera ahead of them. Each camera has
  its own zoom.
- Your camera runs only while an app is using Vaux Camera. Video apps see it
  as one camera that never switches, and a vintage test card (PLEASE STAND
  BY) while Vaux isn't sending a camera.
- macOS's own video effects (Portrait, Studio Light…) are best set for Vaux,
  not the call app: they then apply under Vaux's overlays, which stay sharp.

## Permissions

- **Mute and inputs:** none. Changing Core Audio properties doesn't trigger
  the microphone permission prompt.
- **Solo mode:** Accessibility, to press mute in your call apps, and to notice
  the 🎤 Dictation key. Vaux reacts only to that key and Escape, and ignores
  every other key. While a Chromium browser is using the mic, Vaux turns on
  its full accessibility support (as a screen reader does) so Meet's mute
  button can be pressed, and turns it off again after.
- **Call and dictation detection:** none. Vaux reads which apps are using the
  mic from Core Audio's process list, without opening the mic itself.
- **Vaux Camera:** none unless you turn it on. Then macOS asks you to approve
  the camera extension in System Settings, and Vaux asks for camera access.
  Turning it off removes the extension.

## Usage

- The menu bar icon shows the state: voice bars when live, flat dots when
  muted, and three bars between two dots in solo (orange if something couldn't
  be muted or can still hear you).
- **Click** the icon to open the menu. **Shift-, Option- or Control-click** it
  to toggle mute.
- **Settings** (⌘, from the menu): **Microphone** has dictation (solo mode),
  mute and preferred inputs; **Camera** turns Vaux Camera on and ranks your
  cameras; **Effects** has overlays, push-ins and combos; **Shortcuts** has
  every Vaux key. Launch at Login is a switch in the menu.
- While the camera is on, the menu has two tabs: **Devices** (mics and
  cameras; clicking a camera puts it first) and **Effects** (Live, overlays,
  push-in, looks, combos). Deleting an effect in Settings can be undone (⌘Z).

## Build and run

Requires macOS 26+, Xcode 26+ and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The Xcode project is generated from [`project.yml`](project.yml) and isn't
checked in. Generate it first:

```sh
make open      # generate the project and open it in Xcode, then ⌘R
make run       # build Vaux Dev, install it to /Applications and launch it
make check     # compile without signing
make snapshot  # draw Settings and the menu to build/snapshot.*.png
make snapshot-live  # the running Vaux Dev draws its pages as they are (camera live)
make status    # installed system extensions (Vaux Camera)
make logs      # stream Vaux's logs
```

`make run` installs to `/Applications/Vaux Dev.app` because macOS installs
camera extensions only from there. Installing one also needs a provisioning
profile, so builds sign automatically: the first time, build once in Xcode
(`make open`, ⌘B) to sign in and let it make the profiles.

Development builds are "Vaux Dev" (`dev.imathis.vaux.debug`), a separate app
to macOS with its own permissions and settings, so they never knock out the
installed Vaux's Accessibility grant.

On first build, Xcode resolves the one dependency,
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), via SPM.

To sign with your own team, set `DEVELOPMENT_TEAM` in `project.yml` and `TEAM`
in the `Makefile`. A free personal team is enough for local use.

If `xcode-select` points at the Command Line Tools, the `Makefile` uses
`/Applications/Xcode.app` (or `Xcode-beta.app`). Set `DEVELOPER_DIR` to use
another Xcode.

### Releases

```sh
make install    # Release build signed with Developer ID, into /Applications
make notarize   # notarize and staple it, zipped in dist/ with its SHA-256
make publish    # tag, GitHub release with the zip, and update the Homebrew cask
```

`RELEASE` in the `Makefile` names the release (tag, zip, cask); the app's own
version is `MARKETING_VERSION` in `project.yml`. Notarizing needs the developer
account's `notarytool` login stored in the Keychain, `notarytool-profile` by
default (`NOTARY_PROFILE`).

### App Store builds

The App Sandbox entitlements are in `Sources/Vaux.entitlements` and are off by
default; see the comment in `project.yml`. Mute and inputs work sandboxed.
Pausing media uses a private framework, which the App Store doesn't allow, so
an App Store build would have to leave it out. Solo mode hasn't been tested
sandboxed yet.

## Layout

```
project.yml                  # XcodeGen spec: deployment target, signing, SPM
Makefile                     # gen / open / check / build / run / snapshot / clean
Sources/
  main.swift                 # entry point
  AppDelegate.swift          # status item, clicks, Settings window, app menu
  StatusIcon.swift           # menu bar glyph: live, muted, solo
  StatusIconAnimator.swift   # springs the glyph between states
  MenuPanelController.swift  # the custom glass menu panel
  MenuContentView.swift      # menu: volume, inputs, mute, solo, settings
  SettingsWindow.swift       # Settings window: a toolbar tab per page
  SettingsView.swift         # Settings pages: Microphone, Camera, Effects, Shortcuts
  AppState.swift             # mute intent, device tracking, solo mode
  AudioController.swift      # Core Audio HAL: devices, mute, volume, processes
  CallMuter.swift            # presses call apps' mute via Accessibility
  CaptureWatcher.swift       # which apps are using the mic
  MediaPauser.swift          # pauses playing media during solo
  SoloKeyMonitor.swift       # the 🎤 Dictation key and Escape, for solo
  InputVolumeView.swift      # volume slider
  InputPriorityModel.swift   # preferred-input list (Settings)
  PreferredInput.swift       # preferred-input order storage
  LaunchAtLogin.swift        # SMAppService wrapper
  Shortcuts.swift            # KeyboardShortcuts names
  AppStorageKey.swift        # shared settings keys, and migrating old ones
  Snapshot.swift             # make snapshot: draws Settings and the menu to PNGs
  Info.plist                 # LSUIElement: no Dock icon until Settings opens
  VauxCamera.entitlements    # installing Vaux Camera, camera access
  Vaux.entitlements          # App Sandbox (off by default)
  Vaux.icon                  # app icon (Icon Composer)
  Camera/                    # Vaux Camera, from the app's side:
    VauxCamera.swift         #   on and off, setup, relaunch; Effects; CameraSide
    ExtensionInstaller.swift #   install, update, uninstall, approval
    CameraAccess.swift       #   camera permission
    CameraDevice.swift       #   Vaux Camera's device: watched, format, sink
    CameraPriorityModel.swift #  ranked cameras, docking
    PreferredCamera.swift    #   camera order and zoom storage
    Feeder.swift             #   which camera runs, when
    CameraFeed.swift         #   capture into the sink, zoom, overlay fades
    Compositor.swift         #   crop and scale in hardware, draw overlays
    Overlay*.swift           #   overlays: model, drawing, library
    Combo.swift              #   several effects on one key
    Look.swift               #   looks: model, presets, grading and rendering
    LookEditor.swift         #   a look's editor
    LivePanel.swift          #   the Live panel
    ZoomShortcuts.swift      #   push-in levels
    Triggers.swift           #   every effect's keys, tap and hold
    QuickMenu.swift          #   the Quick Menu panel
    CameraSettings.swift     #   Settings → Camera
    EffectsSettings.swift    #   Settings → Effects
    ShortcutsSettings.swift  #   Settings → Shortcuts
CameraExtension/             # the camera extension (CMIO): device, streams, placeholder
Shared/CameraSpec.swift      # Vaux Camera's name, IDs and formats, for both
IconSource/                  # app icon layer art
docs/                        # README images
```

## Non-goals

No virtual audio devices or HAL plugins, no audio capture or level meters, no
push-to-talk, no HUD, no analytics, no networking, no auto-update.
