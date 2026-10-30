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

Vaux lives in the menu bar. While its Settings or Preview window is open,
it's in the Dock and ⌘-Tab like any app. To update: `brew upgrade --cask vaux`.
`brew uninstall --cask vaux` removes Vaux Camera too, if it was turned on.
(Removing Vaux by hand, turn the camera off in Settings first.)

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

A camera for your calls: your real camera, passed through Vaux, with effects
on your keys. Video apps see one camera, **Vaux Camera**, that never switches,
while Vaux decides what goes into it. It's off until you turn it on in
Settings → Camera.

**The dictation sign.** While solo mode is on, Vaux Camera shows an effect
("Dictating", or lines of your own, picked at random), so the call can see why
you're talking but muted. It goes when solo ends.

#### Effects

An effect is anything you name and turn on, made of any of these:

- **Text and graphics:** text in a pill, a lower-third bar or plain, each line
  with its own icon (or just an icon: a coffee cup for a break), or graphics
  (PNG, PDF, SVG, even full frame), or videos (MOV, MP4, animated GIF),
  playing from the start each time and looping, transparency kept. Seven
  spots, kept inside the middle that apps keep when they crop. They fade in
  and out.
- **Push in:** zoom on top of each camera's own zoom, up to 2×. It moves
  in as the effect comes on and back out as it goes, its way: snap, ease
  in, ease out, or ease in and out, over a time you set.
- **A look:** a color grade over the whole picture:
  - white balance (temperature, tint) and saturation
  - tone: brightness, contrast, highlights and shadows
  - a three-way color grade: hue, saturation and luminance for the shadows,
    midtones and highlights apart
  - texture: blur (a touch for soft focus, up to a frosted shower door for
    stepping away, with text staying sharp over it), fade (lifted blacks and
    a soft glow, for smoke and haze), vignette and film grain

  Presets: Noir, Black & White, Warm, Vivid, Teal & Orange and
  Frosted (behind a frosted shower door, for a "back in 5" over it).
- **Shake:** the picture moves within the camera's frame, gentle to wild,
  slow to fast, with motion blur if you like, pushing in just far enough to
  have room (not at all if it's pushed in that far already). Three motions:
  Vibrate (jumps, 5 to 30 times a second), Rumble (unbroken jitter) and
  Wobble (a smooth sway). It moves on the frames call apps take, 30 a
  second, so no move falls between two and gets lost. One that turns itself off (a new shake does, after 2
  seconds) can build up, from a quarter to full three quarters of the way
  through its time. Text and graphics hold still over it, or shake
  along.
- **Other effects to build on:** "Dictating, ferociously" can be Dictating
  plus a shake; edit Dictating and it follows.

An effect can also turn itself off after a few seconds, and mute your mic
while it's on (unmuting as it goes, unless you were muted already).

**Ready-made.** Vaux starts with a few, a taste of what effects can do:
Privacy (frosted, mic muted), Hand Raised, Suspicious (pushed in,
captioned), Intensify (a wild shake, captioned), Noir, Teal & Orange,
Dictating, and the AWAY group: BRB (frosted, with a sign) and full-frame
cards for Lunch, Coffee, Intermission, Paused, Poopin and On a call, each
muting the mic but Paused and On a call. Add Effect → Ready-Made adds any
of them again.

**Groups.** Effects can go in groups, each with a name and, if you like,
an icon and color: drag an effect under a group's name in the list. Groups
show as sections in the Quick Menu and the menu, and as keys on Stream Deck.

**Backup.** Export puts your effects, groups, Live, the graphics and videos
they show, and their keys (shortcuts, the Quick Menu's) in one
`.vauxeffects` file. Import adds its effects to yours, as copies, or
replaces yours with it (yours are saved in Vaux's Backups folder first).
Your mics and cameras aren't in it: they belong to the Mac.

**One at a time, over the default.** The **default effect** is always on, and
one of yours goes over it: turning another on replaces it. To layer effects,
build one on others in its editor. A held key's effect, the dictation effect
while you dictate, and Live go on top while they last. Layered, text and
graphics share the screen, one per spot; the latest push-in and the latest
shake win; looks mix, each setting from the latest look that changes it, so
black and white from one and grain from another both show.

**Live** is a small panel for the moment: type a line, pick its style and
spot, a push-in and an effect to go with it, and Show puts it all up at once;
Hide takes it all down.

Editors show their changes on your camera as you make them; Cancel puts it
all back. Deletes can be undone.

**Preview.** Preview (under the effects list, or in an editor) opens a window
with your camera in it. While it's open, effects you turn on, and edits,
show there, not on your call: try things out without your coworkers
watching. Your call stays as it was until you close it.

#### Triggering them

- **Shortcuts:** each effect can have a global shortcut.
- **Stream Deck:** Vaux comes with a plugin (Settings → Shortcuts →
  Install): keys for Mute and, while the camera is on, an effect (any but
  the dictation one, which follows your dictation app), Live and Clear All,
  lit while they're on. An effect's key taps and holds like any other. A
  **Vaux Group** key opens one of your groups: its effects, always as they
  are in Vaux. It comes with a Vaux page for each Stream Deck: Mute, Live
  and Clear All, then your effects and groups in Vaux's order (More turns
  the page when they don't all fit). The Vaux Page key opens it from
  anywhere, and its first key comes back.
- **The Quick Menu:** one key (⌥. by default), or a right-side modifier
  tapped on its own (right ⇧, say, the way FluidVoice takes right ⌥), opens a
  small menu over everything, and a second key picks: numbers, then letters,
  for effects, L for Live, M for Mute. Your call app keeps focus.
- **Tap or hold:** tap a key to turn its effect on or off; hold it to show the
  effect only while it's held, then whatever it covered shows again.
- **The menu bar:** while the camera is on, the menu has an **Effects** tab
  with everything to click.

#### Cameras

- Ranked like mics: Vaux sends the highest-ranked camera that's connected and
  switches as cameras come and go. Click one in the menu's **Devices** tab to
  put it first.
- Each camera has its own zoom (a center crop), shown with how far it stays
  sharp.
- An iPhone set up as a camera (propped up in landscape and locked) can go
  ahead of the list, and back when you pick it up.
- Up to 60 fps, in 720p or 1080p, as the video app asks, from the camera's
  uncompressed modes where it has them.
- Frames that arrive broken are hidden: through a dock or hub, some cameras
  lose part of a frame now and then, which shows as a gray striped band with
  the picture shifted. Vaux skips those (calls see the frame before a moment
  longer) rather than drop to a lighter, lower-quality mode.
- While Vaux isn't sending a camera, Vaux Camera shows a vintage test card:
  PLEASE STAND BY.

#### How it works, and what that means

Vaux Camera is a camera extension inside Vaux. Turning the camera on installs
it, which macOS asks you to approve in System Settings, and then Vaux asks for
camera access; turning it off removes it again. Your real camera runs only
while a video app is using Vaux Camera, and frames go through in hardware, so
an idle Vaux Camera costs nothing. Effects are drawn only while they show.

- macOS's own video effects (Portrait, Studio Light, backgrounds) are best
  set for Vaux in Control Center rather than for the call app: then they apply
  under Vaux's overlays, which stay sharp, instead of over them.
- Updating Vaux Camera restarts it, and video apps that are open lose it
  until they're reopened, so updates wait for you to click Update.

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
  Turning it off removes the extension. Opening the Quick Menu by tapping a
  modifier on its own needs Accessibility, and only modifier keys are watched.
- **Stream Deck plugin:** none. It talks to Vaux over a socket in Vaux's own
  Application Support folder that only your user can open.

## Usage

- The menu bar icon shows the state: voice bars when live, flat dots when
  muted, and three bars between two dots in solo (orange if something couldn't
  be muted or can still hear you).
- **Click** the icon to open the menu. **Shift-, Option- or Control-click** it
  to toggle mute.
- **Settings** (⌘, from the menu): **Microphone** has dictation (solo mode),
  mute and preferred inputs; **Camera** turns Vaux Camera on and ranks your
  cameras; **Effects** has your effects; **Shortcuts** has
  every Vaux key. Launch at Login is a switch in the menu.
- While the camera is on, the menu has two tabs: **Devices** (mics and
  cameras; clicking a camera puts it first) and **Effects** (Live, and your
  effects). Deleting an effect in Settings can be undone (⌘Z).

## Build and run

Requires macOS 26+, Xcode 26+ and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Stream Deck plugin also needs Node.js and npm: `make streamdeck` builds it
into `build/`, where Vaux's build picks it up (releases build it first).

The Xcode project is generated from [`project.yml`](project.yml) and isn't
checked in. Generate it first:

```sh
make open      # generate the project and open it in Xcode, then ⌘R
make run       # build Vaux Dev, install it to /Applications and launch it
make check     # compile without signing
make snapshot  # draw Settings and the menu to build/snapshot.*.png
make snapshot-live  # the running Vaux Dev draws its pages as they are (camera live)
make streamdeck     # build the Stream Deck plugin, for Vaux to bundle
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
  ControlServer.swift        # the socket the Stream Deck plugin drives Vaux through
  KeyImages.swift            # Stream Deck key images, in each effect's icon and color
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
  ModifierTapMonitor.swift   # a right-side modifier tapped alone (opens the Quick Menu)
  KeyTap.swift               # the HID-level key tap both of those use
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
    CameraFeed.swift         #   capture into the sink, zoom, shake, fades
    Compositor.swift         #   crop and scale in hardware; draw shake, looks, overlays
    BrokenFrame.swift        #   spotting frames that arrive from the camera broken
    Effect.swift             #   effects: their parts, and looks merged
    EffectLibrary.swift      #   your effects, the stack of those on, what shows
    EffectListRow.swift      #   the Effects list's rows, and dragging in and out of groups
    EffectsBackup.swift      #   a .vauxeffects file: export, import (add or replace)
    EffectMigration.swift    #   effects from overlays, push-ins, looks and combos kept apart
    StarterEffects.swift     #   the effects Vaux starts with, and offers ready-made
    EffectIcon.swift         #   an effect's icon and color, picked or automatic
    ShakeMotion.swift        #   how a shake moves, frame by frame
    Overlay*.swift           #   text, graphics and videos: model, drawing, playing
    Look.swift               #   looks: model, presets, grading and rendering
    LookSections.swift       #   a look's settings, in an effect's editor
    IconChoices.swift        #   picking an icon: offered, or an emoji
    LivePanel.swift          #   the Live panel
    Triggers.swift           #   every effect's keys, tap and hold
    QuickMenu.swift          #   the Quick Menu panel
    CameraSettings.swift     #   Settings → Camera
    EffectsSettings.swift    #   Settings → Effects
    ShortcutsSettings.swift  #   Settings → Shortcuts
CameraExtension/             # the camera extension (CMIO): device, streams, placeholder
StreamDeck/                  # the Stream Deck plugin (TypeScript): keys, their settings, images, Vaux's page
Sources/StarterGraphics/      # the AWAY group's cards, shipped in the app
Shared/CameraSpec.swift      # Vaux Camera's name, IDs and formats, for both
IconSource/                  # app icon layer art
docs/                        # README images
```

## Non-goals

No virtual audio devices or HAL plugins, no audio capture or level meters, no
push-to-talk, no HUD, no analytics, no networking, no auto-update.
