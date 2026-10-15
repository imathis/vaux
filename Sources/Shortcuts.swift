import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// User-customizable global hotkey for toggling mic mute.
    /// KeyboardShortcuts persists the chosen shortcut in UserDefaults and
    /// registers it via the Carbon hotkey API — no Accessibility permission,
    /// no permission dialog.
    static let toggleMicMute = Self("toggleMicMute")

    /// Global hotkey for solo mode: mute call apps in-app, keep the mic live.
    static let toggleSolo = Self("toggleSolo")
}
