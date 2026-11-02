import AppKit
import Combine
import InboxCore
import NexusCore
import SwiftUI

/// Runs automation rules: listens for messages, app launches/quits, the clock, battery/CPU and the focus
/// timer, then performs the rule's actions and writes a run log (automation.json).
@MainActor
final class AutomationManager: ObservableObject {
    @Published private(set) var config: AutomationConfig
    @Published var paused = false

    private weak var model: AppModel?
    private let store = JSONFileStore<AutomationConfig>(url: JSONFileStore<AutomationConfig>.defaultURL("automation"))
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var clock: Timer?
    private var lastFocusPhase: PomodoroPhase = .idle
    /// Events raised while actions run are ignored, so rules can't trigger each other in a loop.
    private var executing = false

    init() {
        config = JSONFileStore<AutomationConfig>(url: JSONFileStore<AutomationConfig>.defaultURL("automation")).load() ?? AutomationConfig()
    }

    func attach(model: AppModel) {
        self.model = model
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? "", name = app?.localizedName ?? ""
            Task { @MainActor in self?.handle(.appLaunched(bundleId: id, name: name)) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? "", name = app?.localizedName ?? ""
            Task { @MainActor in self?.handle(.appQuit(bundleId: id, name: name)) }
        })
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handle(.tick) }
        }
        model.monitor.$snapshot
            .sink { [weak self] s in
                guard let self else { return }
                if case .reading(let b)? = s.battery { self.handle(.battery(level: b.level, onAC: b.onACPower)) }
                if let c = s.cpu { self.handle(.cpu(c.total)) }
            }
            .store(in: &cancellables)
        lastFocusPhase = model.focus.timer.phase
        model.focus.$timer
            .map(\.phase)
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                let before = self.lastFocusPhase
                self.lastFocusPhase = phase
                if phase == .focus, before != .focus { self.handle(.focusStarted) }
                if before == .focus, phase != .focus { self.handle(.focusEnded) }
            }
            .store(in: &cancellables)
    }

    /// Called from `AppModel.handleNew` for every batch of captured messages.
    func newMessages(_ items: [InboxItem]) {
        for item in items.prefix(20) {
            handle(.message(platform: item.platform.displayName, sender: item.title, text: item.body, isPriority: item.isPriority))
        }
    }

    // MARK: Rules

    private func save() { try? store.save(config) }

    func upsert(_ rule: AutomationRule) {
        if let i = config.rules.firstIndex(where: { $0.id == rule.id }) { config.rules[i] = rule } else { config.rules.append(rule) }
        save()
    }

    func delete(_ rule: AutomationRule) {
        config.rules.removeAll { $0.id == rule.id }
        config.lastRun[rule.id] = nil
        save()
    }

    func setEnabled(_ rule: AutomationRule, _ on: Bool) {
        guard let i = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        config.rules[i].enabled = on
        save()
    }

    func addExamples() {
        for var r in AutomationEngine.examples where !config.rules.contains(where: { $0.name == r.name }) {
            r.id = UUID()
            config.rules.append(r)
        }
        save()
    }

    func clearLog() {
        config.log = []
        save()
    }

    // MARK: Running

    func handle(_ event: AutomationEvent) {
        guard !paused, !executing, !config.rules.isEmpty else { return }
        let now = Date()
        for rule in AutomationEngine.due(config, for: event, now: now) {
            run(rule, values: event.values(now: now), reason: rule.trigger.summary, now: now)
        }
    }

    /// "Run now" from the editor: ignores trigger and cooldown.
    func test(_ rule: AutomationRule) {
        let now = Date()
        run(rule, values: AutomationEvent.tick.values(now: now).merging(
            ["sender": "Test sender", "text": "Test message", "platform": "Test", "app": "Test app", "battery": "50%", "cpu": "50%"]
        ) { a, _ in a }, reason: "Run manually", now: now)
    }

    private func run(_ rule: AutomationRule, values: [String: String], reason: String, now: Date) {
        executing = true
        defer { executing = false }
        var results: [String] = []
        var ok = true
        for action in rule.actions {
            let (success, text) = perform(action.filled(values))
            results.append((success ? "✓ " : "✗ ") + text)
            ok = ok && success
        }
        config.record(AutomationLogEntry(date: now, ruleId: rule.id, ruleName: rule.name, trigger: reason, results: results, success: ok))
        save()
    }

    private func runningApp(_ idOrName: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.lowercased() == idOrName.lowercased() || $0.localizedName?.lowercased() == idOrName.lowercased()
        }
    }

    /// Performs one action. Returns (success, description).
    private func perform(_ action: AutomationAction) -> (Bool, String) {
        guard let model else { return (false, "App not ready") }
        switch action {
        case .notify(let title, let body):
            UNUserNotificationCenterSafe.post(id: "automation-\(UUID().uuidString)", title: title, body: body)
            return (true, action.summary)
        case .openApp(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    ?? NSWorkspace.shared.fullPath(forApplication: id).map({ URL(fileURLWithPath: $0) }) else {
                return (false, "App not found: \(id)")
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return (true, action.summary)
        case .quitApp(let id):
            let apps = runningApp(id)
            apps.forEach { $0.terminate() }
            return (true, apps.isEmpty ? "\(id) wasn't running" : action.summary)
        case .hideApp(let id):
            let apps = runningApp(id)
            apps.forEach { $0.hide() }
            return (true, apps.isEmpty ? "\(id) wasn't running" : action.summary)
        case .openURL(let s):
            guard let url = URL(string: s) else { return (false, "Invalid URL: \(s)") }
            NSWorkspace.shared.open(url)
            return (true, action.summary)
        case .switchWorkspace(let name):
            guard let ws = model.windows.config.workspaces.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                return (false, "No workspace named \(name)")
            }
            model.windows.restore(ws)
            return (true, action.summary)
        case .startFocus:
            if model.focus.timer.phase == .idle { model.focus.start() }
            return (true, action.summary)
        case .stopFocus:
            if model.focus.timer.phase != .idle { model.focus.stop() }
            return (true, action.summary)
        case .runShortcut(let name):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            do { try p.run() } catch { return (false, "Couldn't run shortcut: \(error.localizedDescription)") }
            return (true, action.summary)
        case .playSound(let name):
            guard let sound = NSSound(named: NSSound.Name(name)) else { return (false, "No sound named \(name)") }
            sound.play()
            return (true, action.summary)
        case .copyText(let t):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
            return (true, action.summary)
        case .addTask(let title):
            model.focus.add(TodoItem.parse(title))
            return (true, action.summary)
        case .appendToDailyNote(let text):
            model.notes.appendToToday(text)
            return (true, action.summary)
        case .setPrivacyMode(let on):
            model.privacyMode = on
            return (true, action.summary)
        case .paletteCommand(let id):
            guard let cmd = model.paletteCommands().first(where: { $0.id == id }) else { return (false, "Unknown command \(id)") }
            cmd.run()
            return (true, action.summary)
        }
    }
}

// MARK: - Views

struct AutomationView: View {
    @EnvironmentObject private var automation: AutomationManager
    @State private var tab = 0
    @State private var editing: AutomationRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Rules").tag(0)
                    Text("Run Log").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Toggle("Pause all", isOn: $automation.paused).toggleStyle(.switch).controlSize(.small)
                Button { editing = AutomationRule(name: "New rule", trigger: .focusStarted, actions: []) } label: {
                    Label("New Rule", systemImage: "plus")
                }
            }
            if tab == 0 { rules } else { log }
        }
        .padding(28)
        .navigationTitle("Automation")
        .sheet(item: $editing) { r in AutomationEditor(rule: r) }
    }

    @ViewBuilder private var rules: some View {
        if automation.config.rules.isEmpty {
            VStack(spacing: 10) {
                Text("No rules yet. A rule does something when something happens, for example \"when a priority message arrives, add a task\".")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Add Examples (turned off)") { automation.addExamples() }
            }
            .frame(maxWidth: .infinity, minHeight: 140).glassCard()
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(automation.config.rules) { r in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { automation.setEnabled(r, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                                Text("When \(r.trigger.summary.lowercased()) → " + r.actions.map(\.summary).joined(separator: ", "))
                                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(2)
                            }
                            Spacer()
                            if let last = automation.config.lastRun[r.id] {
                                Text(last.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                            Button("Edit") { editing = r }
                        }
                        .padding(12)
                        .glassCard(cornerRadius: Theme.smallRadius)
                    }
                }
            }
        }
    }

    @ViewBuilder private var log: some View {
        HStack {
            Text("Last \(automation.config.log.count) runs").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer()
            Button("Clear") { automation.clearLog() }.disabled(automation.config.log.isEmpty)
        }
        List(automation.config.log) { e in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: e.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(e.success ? Color.green.opacity(0.8) : Theme.warning)
                    Text(e.ruleName).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Text(e.trigger).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(Array(e.results.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .glassCard()
    }
}

/// Rule editor: name, trigger, actions, cooldown.
struct AutomationEditor: View {
    @EnvironmentObject private var automation: AutomationManager
    @EnvironmentObject private var windows: WindowManager
    @Environment(\.dismiss) private var dismiss
    @State var rule: AutomationRule

    enum TriggerKind: String, CaseIterable, Identifiable {
        case message = "New message", launched = "App opens", quit = "App quits", time = "Time of day",
             battery = "Battery low", cpu = "CPU high", focusStart = "Focus starts", focusEnd = "Focus ends"
        var id: String { rawValue }
    }

    @State private var kind: TriggerKind = .message
    @State private var platform = ""
    @State private var sender = ""
    @State private var text = ""
    @State private var priorityOnly = false
    @State private var app = ""
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = []
    @State private var level = 0.2

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            Section("When") {
                Picker("Trigger", selection: $kind) { ForEach(TriggerKind.allCases) { Text($0.rawValue).tag($0) } }
                switch kind {
                case .message:
                    Picker("App", selection: $platform) {
                        Text("Any").tag("")
                        ForEach(Platform.allCases) { Text($0.displayName).tag($0.displayName) }
                    }
                    TextField("Sender contains", text: $sender)
                    TextField("Text contains", text: $text)
                    Toggle("Only priority messages (VIP / keywords)", isOn: $priorityOnly)
                case .launched, .quit:
                    TextField("Bundle id or app name (empty = any app)", text: $app)
                case .time:
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                    HStack {
                        Text("On")
                        ForEach(1...7, id: \.self) { d in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[d - 1], isOn: Binding(
                                get: { weekdays.contains(d) }, set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                                .toggleStyle(.button)
                        }
                        Text(weekdays.isEmpty ? "(every day)" : "").font(.caption).foregroundStyle(.secondary)
                    }
                case .battery, .cpu:
                    Slider(value: $level, in: 0.05...0.95, step: 0.05) { Text("\(kind == .battery ? "At or below" : "At or above") \(Int(level * 100))%") }
                case .focusStart, .focusEnd:
                    EmptyView()
                }
            }
            Section {
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { i, _ in
                    HStack(alignment: .top) {
                        ActionFields(action: Binding(get: { i < rule.actions.count ? rule.actions[i] : .startFocus },
                                                     set: { if i < rule.actions.count { rule.actions[i] = $0 } }),
                                     workspaces: windows.config.workspaces.map(\.name))
                        Button { rule.actions.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Menu("Add Action") {
                    Button("Show a notification") { rule.actions.append(.notify(title: "{sender}", body: "{text}")) }
                    Button("Open an app") { rule.actions.append(.openApp(bundleId: "")) }
                    Button("Quit an app") { rule.actions.append(.quitApp(bundleId: "")) }
                    Button("Hide an app") { rule.actions.append(.hideApp(bundleId: "")) }
                    Button("Open a URL") { rule.actions.append(.openURL("https://")) }
                    Button("Switch workspace") { rule.actions.append(.switchWorkspace(name: windows.config.workspaces.first?.name ?? "")) }
                    Button("Start focus session") { rule.actions.append(.startFocus) }
                    Button("Stop focus session") { rule.actions.append(.stopFocus) }
                    Button("Run a Shortcut") { rule.actions.append(.runShortcut(name: "")) }
                    Button("Play a sound") { rule.actions.append(.playSound(name: "Glass")) }
                    Button("Copy text") { rule.actions.append(.copyText("")) }
                    Button("Add a task") { rule.actions.append(.addTask(title: "Reply to {sender}")) }
                    Button("Add to today's note") { rule.actions.append(.appendToDailyNote(text: "- {time} {sender}: {text}")) }
                    Button("Privacy mode on") { rule.actions.append(.setPrivacyMode(true)) }
                    Button("Privacy mode off") { rule.actions.append(.setPrivacyMode(false)) }
                }
            } header: {
                Text("Do")
            } footer: {
                Text("Placeholders: {sender} {text} {platform} {app} {battery} {cpu} {time} {date}")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Wait at least \(Int(rule.cooldownMinutes)) min between runs", value: $rule.cooldownMinutes, in: 0...1440, step: 1)
            HStack {
                Button("Delete", role: .destructive) { automation.delete(rule); dismiss() }
                Spacer()
                Button("Run Now") { commitTrigger(); automation.test(rule) }
                    .help("Runs the actions once with test values, ignoring the trigger")
                Button("Cancel") { dismiss() }
                Button("Save") { commitTrigger(); automation.upsert(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear(perform: loadTrigger)
    }

    private func loadTrigger() {
        switch rule.trigger {
        case .newMessage(let p, let s, let t, let prio): kind = .message; platform = p; sender = s; text = t; priorityOnly = prio
        case .appLaunched(let b): kind = .launched; app = b
        case .appQuit(let b): kind = .quit; app = b
        case .timeOfDay(let t, let days):
            kind = .time; weekdays = days
            let p = t.split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { time = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date()) ?? time }
        case .batteryBelow(let l): kind = .battery; level = l
        case .cpuAbove(let l): kind = .cpu; level = l
        case .focusStarted: kind = .focusStart
        case .focusEnded: kind = .focusEnd
        }
    }

    private func commitTrigger() {
        switch kind {
        case .message: rule.trigger = .newMessage(platform: platform, senderContains: sender, textContains: text, priorityOnly: priorityOnly)
        case .launched: rule.trigger = .appLaunched(bundleId: app.trimmingCharacters(in: .whitespaces))
        case .quit: rule.trigger = .appQuit(bundleId: app.trimmingCharacters(in: .whitespaces))
        case .time:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            rule.trigger = .timeOfDay(time: String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0), weekdays: weekdays)
        case .battery: rule.trigger = .batteryBelow(level: level)
        case .cpu: rule.trigger = .cpuAbove(level: level)
        case .focusStart: rule.trigger = .focusStarted
        case .focusEnd: rule.trigger = .focusEnded
        }
    }
}

/// Editable fields for one action.
struct ActionFields: View {
    @Binding var action: AutomationAction
    let workspaces: [String]

    private func text(_ get: @escaping () -> String, _ make: @escaping (String) -> AutomationAction) -> Binding<String> {
        Binding(get: get, set: { action = make($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch action {
            case .notify(let t, let b):
                Text("Notification").font(.caption).foregroundStyle(.secondary)
                TextField("Title", text: text({ t }, { .notify(title: $0, body: b) }))
                TextField("Body", text: text({ b }, { .notify(title: t, body: $0) }))
            case .openApp(let id):
                TextField("Open app (bundle id or name)", text: text({ id }, { .openApp(bundleId: $0) }))
            case .quitApp(let id):
                TextField("Quit app (bundle id or name)", text: text({ id }, { .quitApp(bundleId: $0) }))
            case .hideApp(let id):
                TextField("Hide app (bundle id or name)", text: text({ id }, { .hideApp(bundleId: $0) }))
            case .openURL(let u):
                TextField("Open URL", text: text({ u }, { .openURL($0) }))
            case .switchWorkspace(let n):
                Picker("Workspace", selection: text({ n }, { .switchWorkspace(name: $0) })) {
                    if !workspaces.contains(n) { Text(n.isEmpty ? "Choose…" : n).tag(n) }
                    ForEach(workspaces, id: \.self) { Text($0).tag($0) }
                }
            case .runShortcut(let n):
                TextField("Shortcut name (Shortcuts app)", text: text({ n }, { .runShortcut(name: $0) }))
            case .playSound(let n):
                Picker("Sound", selection: text({ n }, { .playSound(name: $0) })) {
                    ForEach(["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
            case .copyText(let t):
                TextField("Copy text", text: text({ t }, { .copyText($0) }))
            case .addTask(let t):
                TextField("Task (supports today, !high, #tag)", text: text({ t }, { .addTask(title: $0) }))
            case .appendToDailyNote(let t):
                TextField("Line for today's note", text: text({ t }, { .appendToDailyNote(text: $0) }))
            case .startFocus, .stopFocus, .setPrivacyMode, .paletteCommand:
                Text(action.summary)
            }
        }
    }
}

extension AppModel {
    func automationPaletteCommands() -> [PaletteCommand] {
        automation.config.rules.map { r in
            PaletteCommand(id: "automation.\(r.id)", title: "Run Automation: \(r.name)", subtitle: r.trigger.summary,
                           symbol: "bolt", keywords: ["automation", "rule", "run"]) { [weak self] in self?.automation.test(r) }
        }
    }
}
