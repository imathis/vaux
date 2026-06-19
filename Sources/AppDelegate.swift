import AppKit
import CoreAudio
import KeyboardShortcuts
import SwiftUI

/// Owns the menu bar status item and the settings window.
///
/// Plain click on the icon opens the menu; Shift-click toggles mute. The
/// settings window is a self-managed NSWindow (a SwiftUI `Settings` scene
/// can't take key focus in an LSUIElement app, which breaks the shortcut
/// recorder), hosting the SwiftUI `SettingsView` via NSHostingController.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        appState.onStateChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    // MARK: Icon

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let muted = appState.muted
        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        let description = muted ? "Microphone muted" : "Microphone live"

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if muted {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let red = image?.withSymbolConfiguration(config)
            red?.isTemplate = false
            button.image = red
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = appState.deviceName.map { "Hush — Input: \($0)" } ?? "Hush — no input device"
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Plain click toggles mute (the frequent action). A modifier-click opens
        // the menu: Shift, Option, or Control. These are left-clicks with a
        // modifier, so the action fires on the reliable leftMouseUp path. True
        // right-click is also wired up, but AppKit doesn't deliver right-mouse
        // events to status items reliably (confirmed broken on macOS 27), so the
        // modifier-clicks are the dependable route.
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isRightMouse = NSApp.currentEvent?.type == .rightMouseUp
        let wantsMenu = isRightMouse
            || flags.contains(.shift)
            || flags.contains(.option)
            || flags.contains(.control)
        if wantsMenu {
            showMenu()
        } else {
            appState.toggle()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = makeMenu()
        button.highlight(true)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 5),
                   in: button)
        button.highlight(false)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let current = AudioController.defaultInputDevice() else {
            menu.addItem(headerItem("Input", font: .systemFont(ofSize: 13, weight: .semibold),
                                color: .secondaryLabelColor))
            let none = NSMenuItem(title: "No input device", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            menu.addItem(.separator())
            addAppItems(to: menu)
            return menu
        }

        // Volume — title (like the system "Sound") then a slider.
        let canSetVolume = AudioController.canSetInputVolume(current)
        menu.addItem(headerItem("Volume", font: .systemFont(ofSize: 13, weight: .semibold),
                                color: .labelColor, trailing: canSetVolume ? nil : "managed by device"))
        let volumeItem = NSMenuItem()
        let volumeView = InputVolumeView(supported: canSetVolume, value: AudioController.volume(on: current) ?? 0)
        volumeView.onChange = { newValue in AudioController.setVolume(newValue, on: current) }
        volumeItem.view = volumeView
        menu.addItem(volumeItem)

        menu.addItem(.separator())

        // Input devices — selection shown the system way: the current device's
        // type icon is tinted blue (accent), others grey. No checkmark.
        menu.addItem(headerItem("Input", font: .systemFont(ofSize: 13, weight: .semibold),
                                color: .secondaryLabelColor))
        let inputs = AudioController.inputDevices()
        let preferredID = preferredDeviceID(in: inputs)
        for device in inputs {
            let item = NSMenuItem(title: device.name, action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: device.id)
            item.image = deviceIcon(for: device.id, name: device.name, selected: device.id == current)
            if device.id == preferredID {
                item.badge = NSMenuItemBadge(string: "Preferred")
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Mute — setShortcut shows the global hotkey natively (right-aligned)
        // and coordinates with the global handler so it doesn't double-fire.
        let toggle = NSMenuItem(title: appState.muted ? "Unmute" : "Mute",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        toggle.setShortcut(for: .toggleMicMute)
        menu.addItem(toggle)
        if !appState.supportsMute {
            let note = NSMenuItem(title: "Using volume (no mute control on this device)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        addAppItems(to: menu)
        return menu
    }

    private func addAppItems(to menu: NSMenu) {
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Hush", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Device-type icon, tinted accent-blue when it's the selected input
    /// (mirrors how the system Sound menu shows the active device).
    /// A header rendered as a custom view (not a disabled item, which macOS
    /// dims to near-transparent, and not the tiny `.sectionHeader`).
    private func headerItem(_ text: String, font: NSFont, color: NSColor, trailing: String? = nil) -> NSMenuItem {
        let title = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        if let trailing {
            title.append(NSAttributedString(
                string: "   \(trailing)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithAttributedString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        let item = NSMenuItem()
        item.view = container
        return item
    }

    /// Device-type glyph inside a filled circle — grey when idle, accent-blue
    /// with a white glyph when it's the active input (ripped from the system
    /// Sound menu's selection style).
    private func deviceIcon(for id: AudioDeviceID, name: String, selected: Bool) -> NSImage {
        let circle: CGFloat = 26
        let pad: CGFloat = 4 // transparent margin → spacing from the menu edge and text
        let canvas = circle + pad * 2
        let circleColor: NSColor = selected ? .controlAccentColor : .tertiaryLabelColor
        let glyphColor: NSColor = selected ? .white : .secondaryLabelColor
        // Hierarchical rendering gives the system's multi-tone/translucent look
        // (e.g. the laptop's screen), not a flat one-color glyph.
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: glyphColor))
        let symbol = symbolName(forTransport: AudioController.transportType(id), name: name)
        let glyph = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                     ?? NSImage(systemSymbolName: "mic", accessibilityDescription: nil))?
            .withSymbolConfiguration(config)
        glyph?.isTemplate = false

        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            circleColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: pad, y: pad, width: circle, height: circle)).fill()
            if let glyph {
                // Scale to fit inside the circle, preserving aspect ratio, so
                // wide glyphs (e.g. laptopcomputer) don't overflow.
                let maxDim = circle * 0.62
                let size = glyph.size
                let scale = (size.width > 0 && size.height > 0)
                    ? min(maxDim / size.width, maxDim / size.height) : 1
                let w = size.width * scale, h = size.height * scale
                glyph.draw(in: NSRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func symbolName(forTransport transport: UInt32, name: String) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return bluetoothSymbol(name: name)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "rectangle.3.group"
        default: return "mic"
        }
    }

    /// AirPods models get their specific SF Symbol; other Bluetooth audio falls
    /// back to generic headphones.
    private func bluetoothSymbol(name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        return "headphones"
    }

    // MARK: Menu actions

    @objc private func toggleFromMenu() {
        appState.toggle()
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSNumber else { return }
        AudioController.setDefaultInputDevice(AudioDeviceID(id.uint32Value))
    }

    /// The highest-priority preferred input that's currently connected, if any.
    private func preferredDeviceID(in inputs: [(id: AudioDeviceID, uid: String, name: String)]) -> AudioDeviceID? {
        for entry in PreferredInput.order where !entry.uid.isEmpty {
            if let match = inputs.first(where: { $0.uid == entry.uid }) {
                return match.id
            }
        }
        return nil
    }


    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            // Size the window to the SwiftUI content (fixed width, intrinsic
            // height) instead of a fixed/resizable frame.
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Hush Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
