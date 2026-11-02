import AppKit
import Combine
import InboxCore
import LocalAuthentication
import NexusCore
import SwiftUI

// MARK: - App lock (Touch ID or the Mac's login password, via LocalAuthentication)

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var isLocked = false
    @Published var policy: LockPolicy {
        didSet { if let d = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(d, forKey: Self.key) } }
    }
    @Published private(set) var lastError: String?

    nonisolated static let key = "appLockPolicy"
    private var lastActive: Date? = Date()
    private var observers: [NSObjectProtocol] = []
    private var authenticating = false

    var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(LockPolicy.self, from: $0) }
        policy = saved ?? LockPolicy()
        isLocked = policy.shouldLock(on: .launch)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastActive = Date() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isLocked, self.policy.shouldLock(on: .appActivated(lastActive: self.lastActive)) { self.isLocked = true }
                if self.isLocked { self.unlock() }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockIf(.systemSleep) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockIf(.screenLocked) }
        })
    }

    private func lockIf(_ event: LockPolicy.Event) {
        if policy.shouldLock(on: event) { lock() }
    }

    func lock() {
        guard policy.enabled else { return }
        isLocked = true
        // Hide floating panels that could show content.
        NotificationCenter.default.post(name: .appDidLock, object: nil)
    }

    /// Asks for Touch ID (or the login password). `then` runs only after success.
    func unlock(then: (() -> Void)? = nil) {
        guard isLocked else { then?(); return }
        authenticate(reason: "unlock Unified Inbox") { [weak self] ok in
            if ok { self?.isLocked = false; then?() }
        }
    }

    /// Runs `action` immediately when unlocked, otherwise after authentication.
    func whenUnlocked(_ action: @escaping () -> Void) {
        if isLocked { unlock(then: action) } else { action() }
    }

    func setEnabled(_ on: Bool) {
        guard on != policy.enabled else { return }
        // Confirm the user can authenticate before turning the lock on (and before turning it off).
        authenticate(reason: on ? "turn on the app lock" : "turn off the app lock") { [weak self] ok in
            guard let self, ok else { return }
            self.policy.enabled = on
            if !on { self.isLocked = false }
        }
    }

    private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        guard !authenticating else { return }
        authenticating = true
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticating = false
            lastError = error?.localizedDescription ?? "This Mac can't authenticate (no password or Touch ID set up)."
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, err in
            DispatchQueue.main.async { [weak self] in
                self?.authenticating = false
                self?.lastError = ok ? nil : err?.localizedDescription
                completion(ok)
            }
        }
    }
}

extension Notification.Name {
    static let appDidLock = Notification.Name("UnifiedInbox.appDidLock")
}

/// Covers a window's content while the app is locked.
struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            GlassBackground(material: .fullScreenUI).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: lock.biometricsAvailable ? "touchid" : "lock.fill")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                Text("Unified Inbox is locked").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primary)
                Button(lock.biometricsAvailable ? "Unlock with Touch ID" : "Unlock") { lock.unlock() }
                    .keyboardShortcut(.defaultAction)
                if let e = lock.lastError {
                    Text(e).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

extension View {
    /// Overlays the lock screen while locked.
    func lockable() -> some View { modifier(LockableModifier()) }
}

private struct LockableModifier: ViewModifier {
    @EnvironmentObject private var lock: AppLock

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: lock.isLocked ? 18 : 0)
                .allowsHitTesting(!lock.isLocked)
                .accessibilityHidden(lock.isLocked)
            if lock.isLocked { LockScreen() }
        }
    }
}

// MARK: - Encrypted backup / restore

@MainActor
enum BackupService {
    static var dataFolder: URL { URL(fileURLWithPath: InboxStore.defaultPath()).deletingLastPathComponent() }

    /// Files left out of the folder copy: the live database (backed up separately via SQLite's
    /// online backup API) and its journals.
    static let excluded: Set<String> = ["inbox.sqlite", "inbox.sqlite-wal", "inbox.sqlite-shm", "inbox.sqlite-journal"]

    static let lastBackupKey = "lastBackupDate"

    static func backUp(store: InboxStore?) {
        guard BackupCrypto.isAvailable else { return }
        guard let password = PasswordPrompt.ask(title: "Encrypt backup",
                                                message: "Choose a password. You'll need it to restore; it can't be recovered.",
                                                confirm: true) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Unified Inbox \(Date().formatted(.iso8601.year().month().day())).uibackup"
        panel.message = "Everything in the app, encrypted with AES-256-GCM"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var files = BackupArchive.collect(from: dataFolder, excluding: excluded)
            if let store {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-backup-\(UUID().uuidString).sqlite")
                defer { try? FileManager.default.removeItem(at: temp) }
                try store.backup(toPath: temp.path)
                files["inbox.sqlite"] = try Data(contentsOf: temp)
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let plain = try BackupArchive.pack(files, appVersion: version)
            let sealed = try BackupCrypto.encrypt(plain, password: password)
            try sealed.write(to: url, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: lastBackupKey)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError("Backup failed", error)
        }
    }

    static func restore() {
        guard BackupCrypto.isAvailable else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a .uibackup file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let password = PasswordPrompt.ask(title: "Backup password", message: url.lastPathComponent, confirm: false) else { return }
        do {
            let plain = try BackupCrypto.decrypt(try Data(contentsOf: url), password: password)
            let (manifest, files) = try BackupArchive.unpack(plain)
            let confirm = NSAlert()
            confirm.messageText = "Replace everything with this backup?"
            confirm.informativeText = "Backup from \(manifest.created.formatted()) with \(files.count) files. Your current data is kept in “UnifiedInbox.before-restore” next to the data folder. The app restarts to finish."
            confirm.addButton(withTitle: "Restore and Restart")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            try StagedRestore.stage(files, for: dataFolder)
            relaunch()
        } catch {
            showError("Restore failed", error)
        }
    }

    /// Call before anything opens the data files (start of AppModel.init).
    nonisolated static func applyPendingRestore() {
        let base = URL(fileURLWithPath: InboxStore.defaultPath()).deletingLastPathComponent()
        do { try StagedRestore.applyPending(for: base) } catch { NSLog("Restore failed: \(error)") }
    }

    private static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        if url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            let a = NSAlert()
            a.messageText = "Restore is ready"
            a.informativeText = "Quit and start the app again to finish."
            a.runModal()
        }
    }

    private static func showError(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }
}

enum PasswordPrompt {
    @MainActor
    static func ask(title: String, message: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 56 : 24))
        stack.orientation = .vertical
        stack.spacing = 8
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        first.placeholderString = "Password"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        second.placeholderString = "Repeat password"
        stack.addArrangedSubview(first)
        if confirm { stack.addArrangedSubview(second) }
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = first
        while alert.runModal() == .alertFirstButtonReturn {
            let pw = first.stringValue
            if pw.count < 8 {
                alert.informativeText = "Use at least 8 characters."
            } else if confirm && pw != second.stringValue {
                alert.informativeText = "The passwords don't match."
            } else {
                return pw
            }
        }
        return nil
    }
}

// MARK: - Settings tab

struct SecuritySettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @State private var lastBackup = UserDefaults.standard.object(forKey: BackupService.lastBackupKey) as? Date

    var body: some View {
        Form {
            Section {
                Toggle(lock.biometricsAvailable ? "Require Touch ID to open the app" : "Require your Mac password to open the app",
                       isOn: Binding(get: { lock.policy.enabled }, set: { lock.setEnabled($0) }))
                if lock.policy.enabled {
                    Picker("Lock after", selection: $lock.policy.lockAfterMinutes) {
                        Text("Leaving the app").tag(0.0)
                        Text("1 minute away").tag(1.0)
                        Text("5 minutes away").tag(5.0)
                        Text("15 minutes away").tag(15.0)
                        Text("1 hour away").tag(60.0)
                    }
                    Toggle("Lock when the Mac sleeps", isOn: $lock.policy.lockOnSleep)
                    Toggle("Lock when the screen locks", isOn: $lock.policy.lockOnScreenLock)
                    Button("Lock Now") { lock.lock() }
                }
                if let e = lock.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("App lock")
            } footer: {
                Text("Covers the window, menu-bar panel, quick look and clipboard history until you unlock. Capture keeps running while locked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Back Up Now…") {
                        BackupService.backUp(store: model.store)
                        lastBackup = UserDefaults.standard.object(forKey: BackupService.lastBackupKey) as? Date
                    }
                    Button("Restore…") { BackupService.restore() }
                    Spacer()
                    Text(lastBackup.map { "Last backup \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No backup yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Encrypted backup")
            } footer: {
                Text("One .uibackup file with messages, notes, tasks, habits, rules and settings files, encrypted with AES-256-GCM using a key derived from your password (PBKDF2-SHA256, 210,000 rounds). Without the password it can't be opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
