import AppKit
import InboxCore
import ServiceManagement

enum AppLauncher {
    /// Brings the source app forward. Tries the exact bundle id that posted the notification first.
    static func open(platform: Platform, preferredBundleId: String?) {
        let candidates = [preferredBundleId].compactMap { $0 } + platform.bundleIdentifiers
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
                return
            }
        }
        // Fallback to the web client when the desktop app isn't installed.
        if let url = platform.webURL { NSWorkspace.shared.open(url) }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
        }
    }
}
