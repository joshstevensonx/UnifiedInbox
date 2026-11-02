import AppKit
import EventKit
import Combine
import GRDB
import InboxCore
import NexusCore
import SwiftUI

/// Top-level areas of the app (NEXUS pages + the unified inbox).
enum AppSection: String, Hashable, CaseIterable {
    case overview, monitor, launcher, widgets, apps, clipboard, focus, inbox

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .monitor: return "System Monitor"
        case .launcher: return "Launcher"
        case .widgets: return "Widgets"
        case .apps: return "Apps"
        case .clipboard: return "Clipboard"
        case .focus: return "Focus"
        case .inbox: return "Inbox"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .monitor: return "waveform.path.ecg"
        case .launcher: return "square.grid.3x3"
        case .widgets: return "rectangle.on.rectangle"
        case .apps: return "app.badge"
        case .clipboard: return "doc.on.clipboard"
        case .focus: return "timer"
        case .inbox: return "tray"
        }
    }
}

/// Main-actor view model shared by the window, the menu-bar extra and Settings.
@MainActor
final class AppModel: ObservableObject {
    // UI state
    @Published var section: AppSection = .inbox {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Keys.lastSection) }
    }
    @Published var filter: InboxFilter = .all { didSet { observe() } }
    @Published var searchText: String = "" { didSet { observe() } }
    @Published var selection: Set<InboxItem.ID> = []

    // Data
    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var unreadCounts: [Platform: Int] = [:]
    @Published private(set) var priorityUnread = 0
    @Published private(set) var snoozedCount = 0
    @Published private(set) var recentUnread: [InboxItem] = []
    @Published private(set) var captureStatus: CaptureStatus = .idle
    @Published private(set) var storeError: String?

    // Settings (persisted in UserDefaults)
    @Published var enabledPlatforms: Set<Platform> {
        didSet {
            UserDefaults.standard.set(Platform.encodeSet(enabledPlatforms), forKey: Keys.enabledPlatforms)
            presence.watched = enabledPlatforms
            let set = enabledPlatforms
            if let coordinator { Task { await coordinator.setEnabledPlatforms(set); await coordinator.refreshAll() } }
        }
    }
    @Published var vipText: String { didSet { UserDefaults.standard.set(vipText, forKey: Keys.vip) } }
    @Published var keywordText: String { didSet { UserDefaults.standard.set(keywordText, forKey: Keys.keywords) } }
    @Published var priorityAlerts: Bool { didSet { UserDefaults.standard.set(priorityAlerts, forKey: Keys.priorityAlerts) } }
    /// Show one row per conversation instead of one per message.
    @Published var groupThreads: Bool { didSet { UserDefaults.standard.set(groupThreads, forKey: Keys.groupThreads) } }
    /// Hide message text in the menu bar, quick look and banners.
    @Published var privacyMode: Bool { didSet { UserDefaults.standard.set(privacyMode, forKey: Keys.privacyMode) } }
    /// Global ⌃⌥Space quick-look panel.
    @Published var quickLookHotKey: Bool {
        didSet {
            UserDefaults.standard.set(quickLookHotKey, forKey: Keys.quickLookHotKey)
            quickLook?.setHotKeyEnabled(quickLookHotKey)
        }
    }

    /// Global ⌥Space launcher panel.
    @Published var launcherHotKey: Bool {
        didSet {
            UserDefaults.standard.set(launcherHotKey, forKey: Keys.launcherHotKey)
            launcherPanel.setHotKeyEnabled(launcherHotKey)
        }
    }

    /// Rules, labels, quiet hours, saved searches (rules.json).
    @Published var ruleSet: RuleSet
    private let ruleStore = JSONFileStore<RuleSet>(url: JSONFileStore<RuleSet>.defaultURL("rules"))
    private var housekeepingTimer: Timer?

    /// Source-app running state + keep-alive.
    let presence = AppPresenceMonitor()

    // NEXUS services (one shared instance each).
    let monitor: SystemMonitor
    let launcher: LauncherModel
    let widgets: WidgetManager
    let launcherPanel: LauncherPanelController
    let clipboard: ClipboardManager
    let apps: AppsManager
    let media: MediaController
    let capture: CaptureService
    let focus: FocusModel
    private var quickLook: QuickLookController?

    let store: InboxStore?
    private let ncSource: NotificationCenterSource
    private var coordinator: CaptureCoordinator?
    private var listCancellable: AnyDatabaseCancellable?
    private var countsCancellable: AnyDatabaseCancellable?
    private var snoozeTimer: Timer?
    private var keyboard: KeyboardTriage?

    enum Keys {
        static let enabledPlatforms = "enabledPlatforms"
        static let vip = "vipSenders"
        static let keywords = "alertKeywords"
        static let priorityAlerts = "priorityAlerts"
        static let retentionDays = "retentionDays"
        static let pollSeconds = "pollSeconds"
        static let groupThreads = "groupThreads"
        static let privacyMode = "privacyMode"
        static let quickLookHotKey = "quickLookHotKey"
        static let launcherHotKey = "launcherHotKey"
        static let lastSection = "lastSection"
    }

    var totalUnread: Int { unreadCounts.values.reduce(0, +) }
    var rules: AlertRules { AlertRules(vipText: vipText, keywordText: keywordText) }
    var visiblePlatforms: [Platform] { Platform.allCases.filter(enabledPlatforms.contains) }

    init() {
        let d = UserDefaults.standard
        ruleSet = JSONFileStore<RuleSet>(url: JSONFileStore<RuleSet>.defaultURL("rules")).load() ?? RuleSet()
        // Locals first: `self` can't be read until every stored property is set.
        let monitor = SystemMonitor()
        let launcher = LauncherModel()
        self.monitor = monitor
        self.launcher = launcher
        widgets = WidgetManager(monitor: monitor)
        launcherPanel = LauncherPanelController(launcher: launcher)
        clipboard = ClipboardManager()
        apps = AppsManager()
        media = MediaController()
        capture = CaptureService()
        focus = FocusModel()
        launcherHotKey = d.object(forKey: Keys.launcherHotKey) as? Bool ?? true
        section = d.string(forKey: Keys.lastSection).flatMap(AppSection.init(rawValue:)) ?? .overview
        let platforms = Platform.decodeSet(d.string(forKey: Keys.enabledPlatforms))
        enabledPlatforms = platforms
        vipText = d.string(forKey: Keys.vip) ?? ""
        keywordText = d.string(forKey: Keys.keywords) ?? ""
        priorityAlerts = d.object(forKey: Keys.priorityAlerts) as? Bool ?? true
        groupThreads = d.object(forKey: Keys.groupThreads) as? Bool ?? false
        privacyMode = d.object(forKey: Keys.privacyMode) as? Bool ?? false
        quickLookHotKey = d.object(forKey: Keys.quickLookHotKey) as? Bool ?? true
        let poll = d.double(forKey: Keys.pollSeconds)
        // Use the local copy: `self` can't be read until every stored property is set.
        ncSource = NotificationCenterSource(platforms: platforms, pollInterval: poll > 0 ? poll : 2)
        do {
            store = try InboxStore(path: InboxStore.defaultPath())
        } catch {
            store = nil
            storeError = "Could not open local database: \(error.localizedDescription)"
            return
        }
        presence.watched = enabledPlatforms
        observe()
        observeCounts()
        startCapture()
        purgeOldItems()
        startSnoozeTimer()
        runHousekeeping()
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runHousekeeping() }
        }
        keyboard = KeyboardTriage(model: self)
        quickLook = QuickLookController(model: self)
        quickLook?.setHotKeyEnabled(quickLookHotKey)
        PriorityNotifier.requestAuthorizationIfPossible()
        launcherPanel.model = self
        launcherPanel.setHotKeyEnabled(launcherHotKey)
        widgets.attach(model: self)
    }

    // MARK: Capture

    func startCapture() {
        guard let store else { return }
        captureStatus = ncSource.checkAccess()
        let coordinator = CaptureCoordinator(
            store: store,
            enabledPlatforms: enabledPlatforms,
            rules: rules,
            onNewItems: { items in
                Task { @MainActor [weak self] in self?.handleNew(items) }
            }
        )
        self.coordinator = coordinator
        let source = ncSource
        let ruleSet = self.ruleSet
        Task {
            await coordinator.setRuleSet(ruleSet)
            await coordinator.add(source)
            await coordinator.start()
        }
    }

    /// Re-check permissions (e.g. after the user grants Full Disk Access) and poll now.
    func refresh() {
        captureStatus = ncSource.checkAccess()
        guard let coordinator else { return }
        Task { await coordinator.refreshAll() }
    }

    /// Saves VIP/keyword rules and re-flags existing items.
    func applyRules() {
        let rules = self.rules
        try? store?.reclassify(with: rules)
        if let coordinator { Task { await coordinator.setRules(rules) } }
    }

    private func handleNew(_ items: [InboxItem]) {
        guard priorityAlerts else { return }
        let rules = self.rules
        for item in items where item.isPriority {
            // Rules can mute a message; quiet hours silence alerts (messages are still captured).
            guard ruleSet.shouldAlert(ruleSet.apply(to: item)) else { continue }
            PriorityNotifier.alert(item: item, reason: rules.match(item), hideBody: privacyMode)
        }
    }

    // MARK: Rules, labels, saved searches

    /// Saves rules and pushes them to capture. `applyToExisting` re-labels stored messages.
    func saveRuleSet(applyToExisting: Bool = false) {
        try? ruleStore.save(ruleSet)
        let set = ruleSet
        if let coordinator { Task { await coordinator.setRuleSet(set) } }
        if applyToExisting { _ = try? store?.apply(set) }
        runHousekeeping()
    }

    func setLabel(_ ids: Set<String>, _ label: String, on: Bool) {
        try? store?.setLabel(Array(expand(ids)), label, on: on)
        if on, ruleSet.labelColors[label] == nil {
            ruleSet.labelColors[label] = Self.labelPalette[ruleSet.labelColors.count % Self.labelPalette.count]
            try? ruleStore.save(ruleSet)
        }
    }

    func setNote(_ id: String, _ note: String) { try? store?.setNote(id, note) }

    /// Short confirmation shown in the list header.
    @Published var toast: String?

    func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    func promptNewLabel(for ids: Set<String>) {
        let alert = NSAlert()
        alert.messageText = "New label"
        alert.informativeText = "For example a client or project name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        setLabel(ids, name, on: true)
    }

    /// Creates a task in Focus that links back to the message.
    func sendToTasks(_ item: InboxItem) {
        let title = "Reply to \(item.title)" + (item.subtitle.map { ": \($0)" } ?? "")
        focus.add(TodoItem(title: title, notes: item.body, tags: [item.platform.rawValue] + item.labels))
        flash("Added to Tasks")
    }

    private let eventStore = EKEventStore()

    /// Adds an Apple Reminder (local Reminders app, no account needed).
    func sendToReminders(_ item: InboxItem) {
        let store = eventStore
        let save: () -> Void = { [weak self] in
            let r = EKReminder(eventStore: store)
            r.title = "Reply to \(item.title)" + (item.subtitle.map { ": \($0)" } ?? "")
            r.notes = "\(item.platform.displayName) · \(item.receivedAt.formatted())\n\n\(item.body)"
            r.calendar = store.defaultCalendarForNewReminders()
            do {
                try store.save(r, commit: true)
                self?.flash("Added to Reminders")
            } catch {
                self?.flash("Couldn't add to Reminders: \(error.localizedDescription)")
            }
        }
        let handler: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { [weak self] in
                if granted { save() } else { self?.flash("Allow Reminders access in System Settings → Privacy & Security → Reminders") }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: handler)
        } else {
            store.requestAccess(to: .reminder, completion: handler)
        }
    }

    static let labelPalette = ["#8CB3FF", "#7BD88F", "#FFB86B", "#FF7A90", "#C792EA", "#5FD7D7", "#FFD866"]

    func applySavedSearch(_ s: SavedSearch) {
        section = .inbox
        if let p = s.platform { filter = .platform(p) }
        else if let l = s.label { filter = .label(l) }
        else { filter = s.unreadOnly ? .unread : .all }
        searchText = s.query
    }

    func saveCurrentSearch(named name: String) {
        var s = SavedSearch(name: name, query: searchText, unreadOnly: filter == .unread)
        if case .platform(let p) = filter { s.platform = p }
        if case .label(let l) = filter { s.label = l }
        ruleSet.savedSearches.append(s)
        try? ruleStore.save(ruleSet)
    }

    func deleteSavedSearch(_ s: SavedSearch) {
        ruleSet.savedSearches.removeAll { $0.id == s.id }
        try? ruleStore.save(ruleSet)
    }

    /// Hourly: auto-archive old read messages if enabled.
    func runHousekeeping() {
        guard let hours = ruleSet.autoArchiveReadAfterHours, hours > 0 else { return }
        _ = try? store?.autoArchiveRead(before: Date().addingTimeInterval(-Double(hours) * 3600))
    }

    private func purgeOldItems() {
        let days = UserDefaults.standard.object(forKey: Keys.retentionDays) as? Int ?? 30
        guard let store, days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        _ = try? store.purge(olderThan: cutoff)
    }

    private func startSnoozeTimer() {
        wakeSnoozed()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.wakeSnoozed() }
        }
    }

    /// Snoozed messages come back unread, with a "Reminder" notification.
    private func wakeSnoozed() {
        guard let woken = try? store?.wakeSnoozed(), !woken.isEmpty else { return }
        for item in woken.prefix(5) {
            UNUserNotificationCenterSafe.post(id: "reminder-\(item.id)", title: "Reminder: \(item.title)",
                                              body: privacyMode ? item.platform.displayName : item.body)
        }
    }

    // MARK: Observation (live updates from SQLite)

    private func observe() {
        guard let store else { return }
        let filter = self.filter
        let search = searchText
        let observation = ValueObservation.tracking { db in
            try InboxStore.fetch(db, filter: filter, search: search, limit: 1000)
        }
        listCancellable = observation.start(
            in: store.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in self?.storeError = error.localizedDescription },
            onChange: { [weak self] items in
                self?.items = items
                self?.selection.formIntersection(Set(items.map(\.id)))
            }
        )
    }

    private struct Counts {
        var perPlatform: [Platform: Int]
        var priority: Int
        var snoozed: Int
        var recent: [InboxItem]
    }

    private func observeCounts() {
        guard let store else { return }
        let observation = ValueObservation.tracking { db in
            Counts(
                perPlatform: try InboxStore.unreadCounts(db),
                priority: try InboxStore.count(db, filter: .priority, unreadOnly: true),
                snoozed: try InboxStore.count(db, filter: .snoozed, unreadOnly: false),
                recent: try InboxStore.fetch(db, filter: .unread, search: nil, limit: 8)
            )
        }
        countsCancellable = observation.start(
            in: store.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { _ in },
            onChange: { [weak self] c in
                guard let self else { return }
                self.unreadCounts = c.perPlatform
                self.priorityUnread = c.priority
                self.snoozedCount = c.snoozed
                self.recentUnread = c.recent
                let total = c.perPlatform.values.reduce(0, +)
                NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
            }
        )
    }

    // MARK: Actions

    func setRead(_ ids: Set<String>, _ value: Bool) { try? store?.setRead(Array(expand(ids)), value) }
    func setPinned(_ ids: Set<String>, _ value: Bool) { try? store?.setPinned(Array(expand(ids)), value) }
    func setArchived(_ ids: Set<String>, _ value: Bool) {
        let all = expand(ids)
        let next = neighbour(after: all)
        try? store?.setArchived(Array(all), value)
        selection = next.map { [$0] } ?? []
    }
    func snooze(_ ids: Set<String>, _ option: SnoozeOption) {
        let all = expand(ids)
        let next = neighbour(after: all)
        try? store?.snooze(Array(all), until: option.wakeDate(from: Date()))
        selection = next.map { [$0] } ?? []
    }
    func unsnooze(_ ids: Set<String>) { try? store?.unsnooze(Array(expand(ids))) }

    // MARK: Conversations

    var groups: [InboxGroup] { InboxGrouping.group(items) }

    /// In grouped mode a row stands for its whole conversation, so actions apply to every message in it.
    func expand(_ ids: Set<String>) -> Set<String> {
        guard groupThreads else { return ids }
        var result = ids
        for g in groups where !g.ids.isDisjoint(with: ids) { result.formUnion(g.ids) }
        return result
    }

    /// The conversation containing `item` (oldest first) — used by the detail pane.
    func conversation(for item: InboxItem) -> [InboxItem] {
        let key = InboxGrouping.key(for: item)
        return items.filter { InboxGrouping.key(for: $0) == key }.reversed()
    }

    // MARK: Export

    func export(_ format: InboxExporter.Format) {
        let selected = selectedItems
        let toExport = selected.count > 1 ? selected : items
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Unified Inbox \(filter.title) \(Date().formatted(.iso8601.year().month().day())).\(format.fileExtension)"
        panel.message = "Export \(toExport.count) messages as \(format.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try InboxExporter.export(toExport, as: format).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            storeError = "Export failed: \(error.localizedDescription)"
        }
    }

    @Published var showExportRange = false

    /// Exports everything received between two dates (optionally one app) — handy for client billing.
    func exportRange(from start: Date, to end: Date, platform: Platform?, format: InboxExporter.Format) {
        guard let store else { return }
        let dayEnd = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        let items = (try? store.fetch(from: Calendar.current.startOfDay(for: start), to: dayEnd,
                                      platforms: platform.map { [$0] })) ?? []
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Messages \(start.formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")) to \(end.formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).\(format.fileExtension)"
        panel.message = "Export \(items.count) messages"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try InboxExporter.export(items, as: format).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    func showQuickLook() { quickLook?.toggle() }

    func showLauncher() { launcherPanel.toggle() }

    /// Jump to an inbox view from anywhere (overview cards, widgets, menu bar).
    func selectInbox(_ filter: InboxFilter) {
        section = .inbox
        self.filter = filter
        openInbox()
    }

    /// Set by the always-rendered menu-bar label, which has access to SwiftUI's `openWindow`.
    var openInboxAction: (() -> Void)?

    func openInbox() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("inbox") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openInboxAction?()
        }
    }
    func markAllRead() { try? store?.markAllRead(in: filter) }

    func open(_ item: InboxItem) {
        setRead([item.id], true)
        AppLauncher.open(platform: item.platform, preferredBundleId: item.sourceBundleId)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Selection helpers (keyboard triage)

    /// Effective target of a keyboard action: the selection, or nothing.
    var selectedItems: [InboxItem] { items.filter { selection.contains($0.id) } }

    /// Row ids in display order (the newest message of each conversation when grouped).
    var rowIDs: [String] { groupThreads ? groups.map(\.latest.id) : items.map(\.id) }

    func moveSelection(by delta: Int) {
        let rows = rowIDs
        guard !rows.isEmpty else { return }
        let indices = rows.indices.filter { selection.contains(rows[$0]) }
        let current = delta > 0 ? (indices.max() ?? -1) : (indices.min() ?? rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        selection = [rows[next]]
    }

    /// The item to select after removing `ids` from the list (keeps the cursor in place).
    private func neighbour(after ids: Set<String>) -> String? {
        let rows = rowIDs
        guard let last = rows.lastIndex(where: { ids.contains($0) }) else { return nil }
        if let after = rows[(last + 1)...].first(where: { !ids.contains($0) }) { return after }
        return rows[..<last].last(where: { !ids.contains($0) })
    }
}
