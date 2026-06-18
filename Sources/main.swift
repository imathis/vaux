import AppKit

// AppKit entry point. We don't use the SwiftUI `App`/`Settings` scene because a
// Settings-scene window can't take key focus in an LSUIElement (accessory) app,
// which breaks the keyboard-shortcut recorder. The menu bar item and a
// self-managed settings window live in AppDelegate instead. LSUIElement = YES in
// Info.plist makes this a menu-bar-only app (no Dock icon).
//
// Top-level code in main.swift is isolated to the main actor, so creating the
// main-actor AppDelegate here is fine. NSApplication.delegate is a weak
// reference, so `delegate` is held for the process lifetime as a global.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
