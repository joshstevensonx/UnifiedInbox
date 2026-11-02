import AppKit
import Combine
import NexusCore
import SwiftUI
import UserNotifications

/// Tasks + Pomodoro (spec §11.1–11.3). Local JSON storage; reminders and phase changes use local notifications.
@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var config: TodoConfig
    @Published private(set) var timer: PomodoroTimer
    @Published private(set) var now = Date()
    @Published var requestQuickAdd = false
    @Published var filter: Filter = .open

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open", today = "Today", overdue = "Overdue", done = "Done"
        var id: String { rawValue }
    }

    private let store = JSONFileStore<TodoConfig>(url: JSONFileStore<TodoConfig>.defaultURL("tasks"))
    private var ticker: Timer?

    init() {
        let loaded = store.load() ?? TodoConfig()
        config = loaded
        timer = PomodoroTimer(settings: loaded.pomodoro)
    }

    // MARK: Tasks

    var visibleTasks: [TodoItem] {
        let cal = Calendar.current
        return config.sorted(now: now).filter { t in
            switch filter {
            case .open: return !t.isDone
            case .today: return !t.isDone && (t.due.map { cal.isDateInToday($0) } ?? false || t.isOverdue(now: now))
            case .overdue: return t.isOverdue(now: now)
            case .done: return t.isDone
            }
        }
    }

    var openCount: Int { config.items.filter { !$0.isDone }.count }
    var overdueCount: Int { config.items.filter { $0.isOverdue(now: now) }.count }

    func quickAdd(_ text: String) {
        let item = TodoItem.parse(text)
        guard !item.title.isEmpty else { return }
        config.items.append(item)
        scheduleReminder(item)
        save()
    }

    func add(_ item: TodoItem) {
        config.items.append(item)
        scheduleReminder(item)
        save()
    }

    func toggleDone(_ item: TodoItem) {
        update(item.id) {
            $0.isDone.toggle()
            $0.completedAt = $0.isDone ? Date() : nil
        }
    }

    func setPriority(_ item: TodoItem, _ p: TodoPriority) { update(item.id) { $0.priority = p } }

    func setDue(_ item: TodoItem, _ date: Date?) {
        update(item.id) { $0.due = date }
        if let updated = config.items.first(where: { $0.id == item.id }) { scheduleReminder(updated) }
    }

    func delete(_ item: TodoItem) {
        config.items.removeAll { $0.id == item.id }
        UNUserNotificationCenterSafe.remove(id: "task-\(item.id)")
        save()
    }

    func clearDone() {
        config.items.removeAll(where: \.isDone)
        save()
    }

    private func update(_ id: UUID, _ change: (inout TodoItem) -> Void) {
        guard let i = config.items.firstIndex(where: { $0.id == id }) else { return }
        change(&config.items[i])
        save()
    }

    private func scheduleReminder(_ item: TodoItem) {
        UNUserNotificationCenterSafe.remove(id: "task-\(item.id)")
        guard let due = item.due, due > Date(), !item.isDone else { return }
        UNUserNotificationCenterSafe.schedule(id: "task-\(item.id)", title: "Due: \(item.title)",
                                              body: item.priority <= .high ? "\(item.priority.title) priority" : "Task reminder", at: due)
    }

    // MARK: Pomodoro

    var focusMinutesToday: Double { config.focusLog[UsageLog.dayKey(Date())] ?? 0 }
    var streak: Int { config.focusStreak() }

    /// Menu-bar text while a session runs, e.g. "● 18:42".
    var menuBarText: String? {
        guard timer.phase != .idle else { return nil }
        return (timer.phase == .focus ? "● " : "☕ ") + PomodoroTimer.format(timer.remaining(now: now))
    }

    func start(task: TodoItem? = nil) {
        timer.settings = config.pomodoro
        timer.taskId = task?.id
        timer.startFocus()
        startTicking()
    }

    func togglePause() {
        if timer.isPaused { timer.resume() } else { timer.pause() }
        now = Date()
    }

    func skip() {
        if let ended = timer.skip() { phaseEnded(ended, finished: false) }
        if timer.phase == .idle { stopTicking() }
    }

    func stop() {
        // Log partial focus time so deep-work tracking stays honest.
        if timer.phase == .focus {
            let done = (timer.settings.duration(.focus) - timer.remaining()) / 60
            if done >= 1 { config.logFocus(minutes: done.rounded(), taskId: timer.taskId); save() }
        }
        timer.stop()
        stopTicking()
    }

    func updateSettings(_ change: (inout PomodoroSettings) -> Void) {
        change(&config.pomodoro)
        if timer.phase == .idle { timer.settings = config.pomodoro }
        save()
    }

    private func startTicking() {
        now = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        now = Date()
    }

    private func tick() {
        now = Date()
        if let ended = timer.tick(now: now) { phaseEnded(ended, finished: true) }
        if timer.phase == .idle { stopTicking() }
    }

    private func phaseEnded(_ phase: PomodoroPhase, finished: Bool) {
        if phase == .focus && finished {
            config.logFocus(minutes: config.pomodoro.focusMinutes, taskId: timer.taskId)
            save()
        }
        NSSound(named: phase == .focus ? "Glass" : "Hero")?.play()
        let next = timer.phase
        UNUserNotificationCenterSafe.post(
            id: "pomodoro",
            title: phase == .focus ? "Focus session complete" : "Break's over",
            body: next == .idle ? "Start another session when you're ready." : "\(next.title): \(PomodoroTimer.format(timer.remaining()))"
        )
    }

    private func save() { try? store.save(config) }
}

/// UserNotifications only work inside a real .app bundle; no-ops otherwise (e.g. `swift run`).
enum UNUserNotificationCenterSafe {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func post(id: String, title: String, body: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    static func schedule(id: String, title: String, body: String, at date: Date) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    static func remove(id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

// MARK: - Views

struct FocusView: View {
    @EnvironmentObject private var focus: FocusModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            PomodoroPanel().frame(width: 300)
            TaskListPanel()
        }
        .padding(28)
        .navigationTitle("Focus")
    }
}

struct PomodoroPanel: View {
    @EnvironmentObject private var focus: FocusModel
    @State private var showSettings = false

    var body: some View {
        let t = focus.timer
        VStack(spacing: 18) {
            ZStack {
                RingGauge(value: t.phase == .idle ? 0 : t.progress(now: focus.now),
                          color: t.phase.isBreak ? .green.opacity(0.8) : Theme.accent, lineWidth: 8)
                VStack(spacing: 4) {
                    Text(PomodoroTimer.format(t.phase == .idle ? focus.config.pomodoro.duration(.focus) : t.remaining(now: focus.now)))
                        .font(.system(size: 44, weight: .thin, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                    Text(t.isPaused ? "Paused" : t.phase.title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if let id = t.taskId, let task = focus.config.items.first(where: { $0.id == id }) {
                        Text(task.title).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).frame(maxWidth: 160)
                    }
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                if t.phase == .idle {
                    Button { focus.start() } label: { Label("Start Focus", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { focus.togglePause() } label: { Label(t.isPaused ? "Resume" : "Pause", systemImage: t.isPaused ? "play.fill" : "pause.fill") }
                    Button { focus.skip() } label: { Image(systemName: "forward.end.fill") }.help("Skip to the next phase")
                    Button { focus.stop() } label: { Image(systemName: "stop.fill") }.help("Stop (logs time focused so far)")
                }
            }

            HStack(spacing: 22) {
                MetricValue(title: "Today", value: "\(Int(focus.focusMinutesToday)) min", detail: "focused", size: 20)
                MetricValue(title: "Streak", value: "\(focus.streak) d", detail: "days in a row", size: 20)
                MetricValue(title: "Sessions", value: "\(t.completedFocusSessions)", detail: "this run", size: 20)
            }

            DisclosureGroup("Timer settings", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Focus \(Int(focus.config.pomodoro.focusMinutes)) min",
                            value: Binding(get: { focus.config.pomodoro.focusMinutes }, set: { v in focus.updateSettings { $0.focusMinutes = v } }),
                            in: 5...120, step: 5)
                    Stepper("Short break \(Int(focus.config.pomodoro.shortBreakMinutes)) min",
                            value: Binding(get: { focus.config.pomodoro.shortBreakMinutes }, set: { v in focus.updateSettings { $0.shortBreakMinutes = v } }),
                            in: 1...30)
                    Stepper("Long break \(Int(focus.config.pomodoro.longBreakMinutes)) min",
                            value: Binding(get: { focus.config.pomodoro.longBreakMinutes }, set: { v in focus.updateSettings { $0.longBreakMinutes = v } }),
                            in: 5...60, step: 5)
                    Toggle("Start breaks automatically",
                           isOn: Binding(get: { focus.config.pomodoro.autoStartBreaks }, set: { v in focus.updateSettings { $0.autoStartBreaks = v } }))
                }
                .font(.system(size: 12))
                .padding(.top, 6)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        .padding(20)
        .glassCard()
    }
}

struct TaskListPanel: View {
    @EnvironmentObject private var focus: FocusModel
    @State private var newTask = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(Theme.secondary)
                TextField("Add a task: “Send invoice tomorrow !high #nexora”", text: $newTask)
                    .textFieldStyle(.plain)
                    .focused($addFocused)
                    .onSubmit { focus.quickAdd(newTask); newTask = "" }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassCard(cornerRadius: 10)
            .help("Words: today / tomorrow set a due date · !urgent !high !low set priority · #tag adds tags")

            HStack(spacing: 6) {
                ForEach(FocusModel.Filter.allCases) { f in
                    Chip(title: f == .overdue && focus.overdueCount > 0 ? "\(f.rawValue) \(focus.overdueCount)" : f.rawValue,
                         systemImage: f == .done ? "checkmark" : (f == .overdue ? "exclamationmark" : "circle"),
                         isOn: focus.filter == f) { focus.filter = f }
                }
                Spacer()
                if focus.filter == .done {
                    Button("Clear Done") { focus.clearDone() }.controlSize(.small)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    if focus.visibleTasks.isEmpty {
                        Text(focus.filter == .done ? "Nothing completed yet." : "No tasks here. Add one above.")
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(20)
                    }
                    ForEach(focus.visibleTasks) { task in
                        TaskRow(task: task)
                        if task.id != focus.visibleTasks.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
            }
            .glassCard()
        }
        .onChange(of: focus.requestQuickAdd) { requested in
            if requested { addFocused = true; focus.requestQuickAdd = false }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var focus: FocusModel
    let task: TodoItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { focus.toggleDone(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isDone ? Color.green.opacity(0.8) : priorityColor)
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "Mark as not done" : "Complete")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Theme.tertiary : Theme.primary)
                HStack(spacing: 8) {
                    if task.priority != .normal {
                        Text(task.priority.title).foregroundStyle(priorityColor)
                    }
                    if let due = task.due {
                        Label(due.formatted(.relative(presentation: .named)), systemImage: "calendar")
                            .foregroundStyle(task.isOverdue(now: focus.now) ? .red : Theme.tertiary)
                    }
                    if task.focusMinutes > 0 { Label("\(Int(task.focusMinutes)) min", systemImage: "timer") }
                    ForEach(task.tags, id: \.self) { Text("#\($0)") }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if hovering && !task.isDone {
                GlassIconButton(systemImage: "timer", help: "Focus on this task") { focus.start(task: task) }
                Menu {
                    Button("Today, 17:00") { focus.setDue(task, Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())) }
                    Button("Tomorrow, 09:00") {
                        focus.setDue(task, Calendar.current.date(byAdding: .day, value: 1, to: Date())
                            .flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) })
                    }
                    Button("Next week") { focus.setDue(task, Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
                    Divider()
                    Button("No due date") { focus.setDue(task, nil) }
                } label: { Image(systemName: "calendar") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
                .help("Due date (a local reminder is scheduled)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(TodoPriority.allCases, id: \.self) { p in
                Button("Priority: \(p.title)") { focus.setPriority(task, p) }
            }
            Divider()
            Button("Focus on This Task") { focus.start(task: task) }
            Button("Delete", role: .destructive) { focus.delete(task) }
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .urgent: return .red
        case .high: return Theme.warning
        case .normal: return Theme.secondary
        case .low: return Theme.tertiary
        }
    }
}
