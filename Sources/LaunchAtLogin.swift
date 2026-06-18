import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` — no helper target or
/// login-item entitlement needed (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Hush: launch-at-login \(newValue ? "register" : "unregister") failed: \(error)")
            }
        }
    }
}
