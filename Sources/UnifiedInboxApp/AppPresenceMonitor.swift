import AppKit
import Combine
import InboxCore
import UserNotifications

/// Whether a source app can currently post notifications.
enum AppPresence: Equatable {
    case running
    case notRunning
    case notInstalled

    var label: String {
        switch self {
        case .running: return "Running"
        case .notRunning: return "Not running"
        case .notInstalled: return "Not installed"
        }
    }
}

/// Watches the source apps. A closed app posts no notifications, so nothing can be captured from it.
///
/// - Publishes running / not running / not installed per platform.
/// - "Keep running": launches the app hidden in the background at startup and relaunches it if it quits
///   (rate-limited, so quitting it repeatedly on purpose doesn't turn into a fight).
/// - Optional banner when a watched app quits.
@MainActor
final class AppPresenceMonitor: ObservableObject {
    @Published private(set) var presence: [Platform: AppPresence] = [:]
    @Published var keepAlive: Set<Platform> {
        didSet {
            UserDefaults.standard.set(Platform.encodeSet(keepAlive), forKey: Self.keepAliveKey)
            launchMissingKeepAliveApps()
        }
    }
    @Published var warnWhenClosed: Bool {
        didSet { UserDefaults.standard.set(warnWhenClosed, forKey: Self.warnKey) }
    }

    /// Platforms the user has enabled; only these are watched.
    var watched: Set<Platform> = [] { didSet { refresh(); launchMissingKeepAliveApps() } }

    static let keepAliveKey = "keepAlivePlatforms"
    static let warnKey = "warnWhenSourceClosed"

    private var observers: [NSObjectProtocol] = []
    private var relaunchHistory: [Platform: [Date]] = [:]
    private let maxRelaunches = 3
    private let relaunchWindow: TimeInterval = 10 * 60

    init() {
        let d = UserDefaults.standard
        let stored = d.string(forKey: Self.keepAliveKey)
        keepAlive = (stored?.isEmpty ?? true) ? [] : Platform.decodeSet(stored)
        warnWhenClosed = d.object(forKey: Self.warnKey) as? Bool ?? true

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            Task { @MainActor in self?.appTerminated(bundleId: bundleId) }
        })
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: Status

    func refresh() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        var result: [Platform: AppPresence] = [:]
        for p in watched {
            if p.bundleIdentifiers.contains(where: { running.contains($0.lowercased()) }) {
                result[p] = .running
            } else if Self.installedURL(for: p) != nil {
                result[p] = .notRunning
            } else {
                result[p] = .notInstalled
            }
        }
        presence = result
    }

    /// Installed apps that are closed, in sidebar order.
    var closedApps: [Platform] {
        Platform.allCases.filter { presence[$0] == .notRunning }
    }

    static func installedURL(for p: Platform) -> URL? {
        for id in p.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    // MARK: Launching

    /// Opens the app without stealing focus (hidden in the background).
    func launchInBackground(_ p: Platform) {
        guard let url = Self.installedURL(for: p) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func launchAllClosed() {
        closedApps.forEach(launchInBackground)
    }

    private func launchMissingKeepAliveApps() {
        refresh()
        for p in keepAlive.intersection(watched) where presence[p] == .notRunning {
            launchInBackground(p)
        }
    }

    private func appTerminated(bundleId: String?) {
        refresh()
        guard let bundleId, let p = Platform.from(bundleIdentifier: bundleId), watched.contains(p) else { return }

        if keepAlive.contains(p), canRelaunch(p) {
            relaunchHistory[p, default: []].append(Date())
            // Short delay so updates / deliberate restarts finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.presence[p] == .notRunning else { return }
                self.launchInBackground(p)
            }
        } else if warnWhenClosed {
            Self.postClosedWarning(p, relaunchLimitHit: keepAlive.contains(p))
        }
    }

    private func canRelaunch(_ p: Platform) -> Bool {
        let cutoff = Date().addingTimeInterval(-relaunchWindow)
        relaunchHistory[p] = (relaunchHistory[p] ?? []).filter { $0 > cutoff }
        return (relaunchHistory[p]?.count ?? 0) < maxRelaunches
    }

    private static func postClosedWarning(_ p: Platform, relaunchLimitHit: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(p.displayName) was closed"
        content.body = relaunchLimitHit
            ? "It quit several times, so Unified Inbox stopped reopening it. New messages won't be captured until it's open."
            : "New \(p.displayName) messages won't reach your inbox until it's open again."
        content.threadIdentifier = "app-presence"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "closed-\(p.rawValue)", content: content, trigger: nil))
    }
}
