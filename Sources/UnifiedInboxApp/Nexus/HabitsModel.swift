import AppKit
import Charts
import Combine
import NexusCore
import SwiftUI

/// Habit tracker + weekly review. Review data comes from Focus (tasks, focus minutes),
/// Apps (screen time) and the inbox (message count); everything stays local.
@MainActor
final class HabitsModel: ObservableObject {
    @Published private(set) var config: HabitConfig
    @Published var reviewWeek = Date()

    private let store = JSONFileStore<HabitConfig>(url: JSONFileStore<HabitConfig>.defaultURL("habits"))

    init() {
        config = JSONFileStore<HabitConfig>(url: JSONFileStore<HabitConfig>.defaultURL("habits")).load() ?? HabitConfig()
    }

    private func save() { try? store.save(config) }

    func add(_ h: Habit) {
        config.habits.append(h)
        save()
        scheduleReminder(h)
    }

    func update(_ h: Habit) {
        guard let i = config.habits.firstIndex(where: { $0.id == h.id }) else { return }
        config.habits[i] = h
        save()
        scheduleReminder(h)
    }

    func delete(_ h: Habit) {
        config.remove(h.id)
        save()
        UNUserNotificationCenterSafe.remove(id: "habit-\(h.id)")
    }

    func toggle(_ h: Habit, on date: Date = Date()) {
        config.toggle(h.id, on: date)
        save()
    }

    func setReflection(_ text: String, week: Date) {
        config.reflections[UsageLog.dayKey(HabitMath.weekStart(week))] = text
        save()
    }

    func reflection(week: Date) -> String { config.reflections[UsageLog.dayKey(HabitMath.weekStart(week))] ?? "" }

    var dueToday: [Habit] { config.active.filter { HabitMath.isScheduled($0, on: Date()) } }
    var doneTodayCount: Int { dueToday.filter { config.isDone($0.id, on: Date()) }.count }

    private func scheduleReminder(_ h: Habit) {
        UNUserNotificationCenterSafe.remove(id: "habit-\(h.id)")
        guard !h.archived, let t = h.reminderTime else { return }
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        UNUserNotificationCenterSafe.scheduleDaily(id: "habit-\(h.id)", title: h.name, body: "Time for “\(h.name)”.",
                                                   hour: parts[0], minute: parts[1])
    }
}

// MARK: - Views

struct HabitsView: View {
    @EnvironmentObject private var habits: HabitsModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                Text("Habits").tag(0)
                Text("Weekly Review").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if tab == 0 { HabitsPanel() } else { WeeklyReviewPanel() }
        }
        .padding(28)
        .navigationTitle("Habits")
    }
}

struct HabitsPanel: View {
    @EnvironmentObject private var habits: HabitsModel
    @State private var editing: Habit?
    @State private var showNew = false

    /// The last 7 days, oldest first.
    private var days: [Date] {
        (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today: \(habits.doneTodayCount) of \(habits.dueToday.count) done")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { showNew = true } label: { Label("New Habit", systemImage: "plus") }
            }
            if habits.config.active.isEmpty {
                Text("No habits yet. Add one, such as Read 20 minutes, Walk, or No phone after 22:00.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120).glassCard()
            } else {
                HStack(spacing: 0) {
                    Spacer().frame(minWidth: 220, maxWidth: .infinity)
                    ForEach(days, id: \.self) { d in
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            .frame(width: 30)
                    }
                    Spacer().frame(width: 120)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(habits.config.active) { h in row(h) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showNew) { HabitEditor(habit: Habit(name: "")) { habits.add($0) } }
        .sheet(item: $editing) { h in HabitEditor(habit: h) { habits.update($0) } }
    }

    private func row(_ h: Habit) -> some View {
        let streak = HabitMath.streak(h, habits.config)
        let rate = HabitMath.completionRate(h, habits.config)
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: h.symbol).foregroundStyle(Theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                    Text(h.schedule.summary + (h.reminderTime.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
            .frame(minWidth: 220, maxWidth: .infinity)
            ForEach(days, id: \.self) { d in
                let scheduled = HabitMath.isScheduled(h, on: d)
                let done = habits.config.isDone(h.id, on: d)
                Button { habits.toggle(h, on: d) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(done ? Theme.accent : (scheduled ? Theme.secondary : Theme.hairline))
                }
                .buttonStyle(.plain)
                .frame(width: 30)
                .help(d.formatted(date: .abbreviated, time: .omitted) + (scheduled ? "" : " (not scheduled)"))
            }
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("🔥 \(streak)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.primary)
                    Text("\(Int((rate * 100).rounded()))% · 30 d").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
                Menu {
                    Button("Edit…") { editing = h }
                    Button("Archive") { var a = h; a.archived = true; habits.update(a) }
                    Divider()
                    Button("Delete", role: .destructive) { habits.delete(h) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24)
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(12)
        .glassCard(cornerRadius: Theme.smallRadius)
    }
}

struct HabitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var habit: Habit
    let onSave: (Habit) -> Void
    @State private var kind = 0
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var perWeek = 3
    @State private var remind = false
    @State private var remindAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    private let symbols = ["checkmark.circle", "book", "figure.walk", "drop", "bed.double", "dumbbell", "leaf", "brain.head.profile", "pencil", "music.note"]

    var body: some View {
        Form {
            TextField("Name", text: $habit.name)
            Picker("Icon", selection: $habit.symbol) {
                ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) }
            }
            Picker("Schedule", selection: $kind) {
                Text("Every day").tag(0)
                Text("Certain days").tag(1)
                Text("Times per week").tag(2)
            }
            if kind == 1 {
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[d - 1], isOn: Binding(
                            get: { weekdays.contains(d) },
                            set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                            .toggleStyle(.button)
                    }
                }
            }
            if kind == 2 { Stepper("\(perWeek) times a week", value: $perWeek, in: 1...7) }
            Toggle("Daily reminder", isOn: $remind)
            if remind { DatePicker("At", selection: $remindAt, displayedComponents: .hourAndMinute) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    switch kind {
                    case 1: habit.schedule = .weekdays(weekdays.isEmpty ? [2] : weekdays)
                    case 2: habit.schedule = .timesPerWeek(perWeek)
                    default: habit.schedule = .daily
                    }
                    if remind {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: remindAt)
                        habit.reminderTime = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
                    } else {
                        habit.reminderTime = nil
                    }
                    onSave(habit)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(habit.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            switch habit.schedule {
            case .daily: kind = 0
            case .weekdays(let d): kind = 1; weekdays = d
            case .timesPerWeek(let n): kind = 2; perWeek = n
            }
            if let t = habit.reminderTime {
                let p = t.split(separator: ":").compactMap { Int($0) }
                if p.count == 2 {
                    remind = true
                    remindAt = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date()) ?? remindAt
                }
            }
        }
    }
}

struct WeeklyReviewPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var habits: HabitsModel
    @EnvironmentObject private var focus: FocusModel
    @EnvironmentObject private var apps: AppsManager
    @EnvironmentObject private var notes: NotesModel
    @State private var reflection = ""

    private var review: WeeklyReview {
        WeeklyReview.make(weekContaining: habits.reviewWeek, todos: focus.config, habits: habits.config, usage: apps.usage,
                          messagesReceived: model.messageCount(inWeekContaining: habits.reviewWeek))
    }

    var body: some View {
        let r = review
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    GlassIconButton(systemImage: "chevron.left", help: "Previous week") { shift(-7) }
                    Text("Week of \(r.weekStart.formatted(date: .long, time: .omitted))")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    GlassIconButton(systemImage: "chevron.right", help: "Next week") { shift(7) }
                    Spacer()
                    Button("Save as Note") {
                        habits.setReflection(reflection, week: habits.reviewWeek)
                        let title = "Weekly review \(UsageLog.dayKey(r.weekStart))"
                        notes.create(title: title, body: r.markdown(reflection: reflection))
                        model.section = .notes
                    }
                    .help("Creates a Markdown note with this review and your reflection")
                }
                HStack(spacing: 12) {
                    tile("Tasks done", "\(r.tasksCompleted.count)", "\(r.openTasks) open · \(r.overdueTasks) overdue")
                    tile("Focus", "\(Int(r.focusMinutes)) min", "\(r.focusMinutesByDay.filter { $0 > 0 }.count) days with focus")
                    tile("Habits", r.habits.isEmpty ? "—" : "\(Int((r.habitRate * 100).rounded()))%", "of planned check-ins")
                    tile("Screen time", r.screenTimeSeconds > 0 ? MetricFormat.duration(r.screenTimeSeconds) : "—", "tracked in Apps")
                    if let m = r.messagesReceived { tile("Messages", "\(m)", "received") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Focus minutes per day")
                    Chart(Array(r.focusMinutesByDay.enumerated()), id: \.offset) { item in
                        BarMark(x: .value("Day", Calendar.current.date(byAdding: .day, value: item.offset, to: r.weekStart) ?? r.weekStart, unit: .day),
                                y: .value("Minutes", item.element))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                    .frame(height: 120)
                }
                .padding(16).glassCard()
                HStack(alignment: .top, spacing: 12) {
                    list("Completed", r.tasksCompleted.isEmpty ? ["Nothing completed this week."] : r.tasksCompleted)
                    list("Habits", r.habits.map { "\($0.name): \($0.done)/\($0.expected)" })
                    list("Top apps", r.topApps.map { "\($0.name): \(MetricFormat.duration($0.seconds))" })
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Reflection")
                    TextEditor(text: $reflection)
                        .font(.system(size: 13)).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(8).softFill()
                    Text("What went well? What will you change next week? Saved with the week.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .onAppear { reflection = habits.reflection(week: habits.reviewWeek) }
        .onDisappear { habits.setReflection(reflection, week: habits.reviewWeek) }
    }

    private func shift(_ days: Int) {
        habits.setReflection(reflection, week: habits.reviewWeek)
        habits.reviewWeek = Calendar.current.date(byAdding: .day, value: days, to: habits.reviewWeek) ?? habits.reviewWeek
        reflection = habits.reflection(week: habits.reviewWeek)
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        MetricValue(title: title, value: value, detail: detail, size: 22)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private func list(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            if lines.isEmpty {
                Text("—").foregroundStyle(Theme.tertiary)
            }
            ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading).glassCard()
    }
}

extension AppModel {
    /// Messages captured during the calendar week containing `date` (nil if the database isn't available).
    func messageCount(inWeekContaining date: Date) -> Int? {
        guard let store else { return nil }
        let start = HabitMath.weekStart(date)
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return nil }
        return (try? store.fetch(from: start, to: end.addingTimeInterval(-1)))?.count
    }

    func habitPaletteCommands() -> [PaletteCommand] {
        var c = habits.dueToday.map { h in
            PaletteCommand(id: "habit.\(h.id)", title: (habits.config.isDone(h.id, on: Date()) ? "Undo Habit: " : "Done: ") + h.name,
                           symbol: h.symbol, keywords: ["habit", "check", "done"]) { [weak self] in self?.habits.toggle(h) }
        }
        c.append(PaletteCommand(id: "habit.review", title: "Weekly Review", symbol: "calendar.badge.clock",
                                keywords: ["week", "review", "summary", "reflection"]) { [weak self] in
            self?.section = .habits; self?.openInbox()
        })
        return c
    }
}
