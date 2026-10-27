# Plan: camera and effects in Vaux

Vaux becomes **Visual and Auditory UX**: microphone control as today, plus an
opt-in virtual camera ("Vaux Camera") with effects (overlays, push-ins,
combos) that react to dictation. Everything here was proven in the Frames
spike first.

**Read with:** `~/repos/imathis/frames/PLAN.md` (the spike: findings,
measurements, every macOS gotcha hit and how it was handled) and
`~/repos/imathis/frames/docs/overlays-and-quick-menu.md` (the effects
design). Frames' source is the code to port.

## Decisions already made

- **Name:** Vaux Camera (Vaux Dev Camera for development builds).
- **Order:** groundwork first (settings and dictation rework, no camera),
  then the camera, then shipping. Each phase is usable and reviewable on
  its own.
- **Branch:** work on a branch, master stays releasable. (The solo
  announcement Frames uses is already on master, `85be669`, so Vaux and
  Frames keep working together until the camera lands.)
- **Settings:** one window, four toolbar tabs: **Microphone, Camera,
  Effects, Shortcuts.** No General tab: launch at login is a checkmark in the
  menu bar menu; About stays in the menu (and the app menu while Settings is
  open).
- **Settings behaves like an app while open:** Dock icon, ⌘-Tab, focus;
  back to menu bar only when closed.
- **Dictation:** "Dictate with [macOS Dictation / an app]" is the only solo
  trigger. macOS Dictation follows the 🎤 Dictation key (its mic use can't be
  detected; tried before), with Escape ending it as now. An app is followed
  while it's listening. Removed: the solo shortcut, the right-modifier taps,
  solo in the Quick Menu. The menu's Solo row stays for doing it by hand.
- **Media always pauses** while dictating with an app (no setting); with
  macOS Dictation Vaux leaves it to macOS, as now.
- **Camera is opt-in:** no camera permission, extension, or camera code
  running until the user turns it on. Vaux's "no permissions" promise
  becomes "none unless you turn on the camera".

## Phase 1: groundwork (no camera)

1. **Settings as an app while open** (`AppDelegate.openSettings`): switch to
   `NSApp.setActivationPolicy(.regular)` before showing the window; back to
   `.accessory` when it closes (window delegate `windowWillClose`). While
   regular, Vaux needs a main menu: app menu (About, Settings ⌘,, Hide,
   Quit), Edit (so text fields copy and paste), Window. Check: Dock icon
   and ⌘-Tab while open, gone when closed, menu bar icon throughout,
   Accessibility grant unaffected.
2. **Tabbed window:** replace the single form with an
   `NSTabViewController` using `.toolbar` style, one `NSHostingController`
   per tab, the window resizing to each tab's content. Camera and Effects
   show an empty state with **Turn On Camera** (disabled until phase 2).
   Shortcuts holds Mute for now.
3. **Microphone tab** (today's page, reorganized):
   - Dictation: Dictate with [macOS Dictation ▾ / followable apps], Lower
     speakers to (slider).
   - Mute: Unmute volume.
   - Preferred Inputs: auto switch, ranked list, per-input level (as now).
   - The Mute and Solo shortcut rows leave (Mute moves to Shortcuts).
4. **Dictation rework** (`AppState`, `SoloKeyMonitor`, `AppStorageKey`,
   `SettingsView`):
   - One stored choice: `dictateWith` = `macOSDictation` or an app's bundle
     ID (replaces `soloFollowApp` + `soloTapKey`).
   - macOS Dictation: `SoloKeyMonitor` watches only the Dictation key and
     Escape (drop the modifier-tap keys). An app: `CaptureWatcher` follow, as
     now.
   - Remove `KeyboardShortcuts.Name.toggleSolo` and its registration; the
     menu's Solo row stays (and loses its shortcut hint, or shows the 🎤
     symbol for macOS Dictation).
   - Remove `soloPauseMedia`: pause whenever solo starts from an app.
   - **Migration** on first launch: `soloFollowApp` set → that app;
     otherwise macOS Dictation. Then delete `soloTapKey`, `soloPauseMedia`
     and the `toggleSolo` shortcut.
5. **Menu bar menu** (`MenuContentView`): add a Launch at Login row with a
   checkmark, matching the panel's row style; remove it from Settings.
6. **README:** solo mode section and settings description updated.

Done when: dictation with FluidVoice and with macOS Dictation each start and
end solo; old settings migrate; Settings acts as an app while open.

## Phase 2: Vaux Camera

1. **Extension target** in `project.yml` (`type: system-extension`), embedded
   in the app. IDs: `dev.imathis.vaux.camera` / `dev.imathis.vaux.debug.camera`;
   app group and Mach service `Q2573QH43F.dev.imathis.vaux[.debug]`;
   device names Vaux Camera / Vaux Dev Camera, each with its own fixed device
   UUID (new ones, so Frames Camera and Vaux Camera never collide). Sandboxed,
   no profile needed for the extension.
2. **App entitlements:** `com.apple.developer.system-extension.install` and
   `com.apple.security.device.camera`, `NSCameraUsageDescription`. Debug
   signing moves to automatic (`-allowProvisioningUpdates`), as in Frames,
   because the install entitlement needs a profile.
3. **Port from Frames** (rename Frames → Vaux in names and copy; keep the
   comments' reasoning):
   - Extension: `FramesCamera/*` (provider, device, source and sink streams,
     placeholder), `Shared/CameraSpec.swift`.
   - Camera: `ExtensionInstaller`, `CameraAccess`, `FramesCameraDevice`
     (→ `CameraDevice`), `CameraFeed`, `Compositor`, `CameraPriorityModel`,
     `PreferredCamera` (camera order + `CameraZoom`), `Feeder`.
   - Effects: `Overlay`, `OverlayRendering`, `OverlayLibrary`, `Combo`,
     `ZoomShortcuts`, `Triggers`, `QuickMenu`.
   - Not ported: `VauxSolo` (solo is in-process now: `AppState.soloActive`
     drives `OverlayLibrary.setDictating` directly) and, once nothing uses
     it, `SoloBroadcast`.
   - Dev tooling: `Snapshot` (`-snapshot`) and the compositor harness, for
     checking UI and frames without screen recording.
4. **Turn On Camera** (Camera tab): the setup flow from Frames (install,
   approval with System Settings opened to Camera Extensions, camera access)
   and the rules it learned: touch no camera API until the extension is
   installed and current; relaunch after installing or updating it; offer
   Relaunch if the device goes missing; extension build number = checksum
   of its source; extension updates are opt-in with a warning. **Turn Off
   Camera** uninstalls the extension and stops the camera side.
5. **Camera tab** (when on): status, Now (sending stats), ranked cameras with
   per-camera zoom, docking toggle.
6. **Effects tab:** Overlays, Push In, Combos, While dictating [overlay].
7. **Shortcuts tab:** Mute, Quick Menu leader, overlays, push-ins, combos,
   Clear All; tap toggles, hold shows while held; one key does one thing.
   The Quick Menu becomes Vaux-wide with Mute in it (M by default); solo is
   not in it.
8. **Menu bar:** a Camera section in `MenuContentView` while the camera is
   on (camera status, effects as toggles), the icon unchanged otherwise.
9. **Bring over Frames' setup** (once, on Turn On Camera, if Frames' data
   exists): overlays (`~/Library/Application Support/dev.imathis.frames/`
   overlays.json + Graphics) and Frames' UserDefaults (camera order, camera
   zoom, docking, push-in levels, combos, Quick Menu keys, shortcuts).
10. **Retire Frames:** uninstall Frames Camera from Frames (its Uninstall
    button), delete Frames.app, pick Vaux Camera once in each video app.

Done when: everything Frames does works from Vaux, Frames is gone, and a
user who never turns on the camera sees no prompt and no extension.

**Status (2026-10-27): done, but for the live checks below.** As built:

- `VauxCamera` owns on/off. Turn On imports Frames' setup (once), installs
  the extension, relaunches after approval with `-continueCameraSetup`
  (Settings reopens on Camera, camera access is asked). Turn Off uninstalls
  and relaunches clean (simplest way to drop the effect hotkeys).
- `Effects` (overlays, push-ins, looks, combos, Triggers, Quick Menu, Live)
  touches no camera API, so it runs as soon as the camera is on;
  `CameraSide` (access, ranking, device, feed) starts once the extension is
  ready and current. Verified: with the camera off, none of it starts.
- Mute is a Triggers item (M), tap only; its global shortcut stays AppState's.
- `SoloBroadcast` is gone: `Effects` observes `AppState.soloActive`.
- Grown past Frames: looks with color grading (one LUT per setting),
  Live, icon-only overlays, undo for deletes, the menu's Devices and
  Effects tabs, a test card placeholder, a status-line Camera tab.
- Dev builds sign automatically and `make run` installs Vaux Dev to
  /Applications. **xcodebuild sees no Apple ID account on this Mac:**
  profiles are made by building once in Xcode (`make open`, ⌘B).
- **`make release`/`make install` are broken on this branch** until phase 3:
  Developer ID signing has no profile for the install entitlement, so the
  app wouldn't launch. Don't install a release from here yet.
- Snapshots only read (no solo, keys or auto switch), so they can run beside
  Vaux Dev; `make snapshot-live` has the running Vaux Dev draw itself.

Verified live: install and approval, relaunch, camera access, the feed,
solo's overlay, the Frames import, Live, looks, the menu.

Frames is retired (2026-10-27): Frames Camera uninstalled (its builds go
at the next restart), Frames.app, its overlays and its settings moved to
the Trash. Left (the user's hands): the Quick Menu, holding a key, Turn Off
then Turn On again.

## Phase 3: shipping

1. **Release signing:** the app needs a Developer ID provisioning profile
   with the System Extension capability (create in the developer account;
   or let automatic signing manage Developer ID profiles). `make release`
   moves from manual, profile-less signing to that. Notarization covers the
   nested extension. Verify a clean install on another account or Mac.
2. **README:** pitch ("Visual and Auditory UX"?), the camera, effects and
   Quick Menu; Permissions (camera and extension only if turned on);
   Non-goals ("no virtual audio devices" stays; the camera is opt-in);
   Layout.
3. **Cask:** note that removing Vaux should turn off the camera first (or an
   `uninstall` step that deactivates the extension).
4. **The user's own switch to the release Vaux:** their camera setup lives
   only in Vaux Dev now (`dev.imathis.vaux.debug` defaults: looks, combos,
   push-ins, Quick Menu keys, shortcuts, camera order; and
   `~/Library/Application Support/dev.imathis.vaux.debug`). Frames' data,
   which the release's first Turn On would import, is gone, so copy Vaux
   Dev's over once, before turning the camera on in the release.

## Open decisions

- ⌘Q in Settings: quit Vaux (standard) or just close Settings? (Built:
  standard quit.)
- Quick Menu leader default: ⌥. (user's suggestion) or none until set.
  (Built: ⌥., and the Quick Menu exists only while the camera is on.)
- Effects and Shortcuts tabs before the camera is on: visible with an empty
  state (proposed) or hidden. (Built: Effects shows an empty state with Set
  Up Camera…; Shortcuts shows Mute only.)

## Known macOS behavior to design around (from the spike)

- Restarting the extension (install, update, uninstall) drops the camera
  from every running app until it's reopened, Vaux included.
- System extensions activate only from /Applications; dev builds too.
- Camera preferences are per app: nothing can set other apps' camera, so
  Vaux Camera plus the ranking is the enforcement point.
- Continuity Camera's Disconnect button puts the iPhone in "User Disconnect
  Mode" everywhere until reconnected.
