import Foundation

// MARK: - Habits (feature spec §11.3) and weekly review (§11.4)

public enum HabitSchedule: Codable, Equatable, Sendable {
    /// Every day.
    case daily
    /// Specific weekdays, `Calendar` numbering (1 = Sunday … 7 = Saturday).
    case weekdays(Set<Int>)
    /// Any N days per week (weeks follow the calendar's first weekday).
    case timesPerWeek(Int)

    public var summary: String {
        switch self {
        case .daily: return "Every day"
        case .weekdays(let days):
            let symbols = Calendar.current.shortWeekdaySymbols
            return days.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }.joined(separator: ", ")
        case .timesPerWeek(let n): return "\(n)× a week"
        }
    }
}

public struct Habit: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var schedule: HabitSchedule
    public var createdAt: Date
    public var archived: Bool
    /// Optional daily reminder ("HH:mm").
    public var reminderTime: String?

    public init(id: UUID = UUID(), name: String, symbol: String = "checkmark.circle", schedule: HabitSchedule = .daily,
                createdAt: Date = Date(), archived: Bool = false, reminderTime: String? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.schedule = schedule
        self.createdAt = createdAt; self.archived = archived; self.reminderTime = reminderTime
    }
}

public struct HabitConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var habits: [Habit] = []
    /// Habit id → day keys ("yyyy-MM-dd") on which it was done.
    public var done: [UUID: Set<String>] = [:]
    /// Saved weekly reflections: week key ("yyyy-MM-dd" of the week's first day) → text.
    public var reflections: [String: String] = [:]
    public init() {}

    public var active: [Habit] { habits.filter { !$0.archived } }

    public func isDone(_ id: UUID, on date: Date, calendar: Calendar = .current) -> Bool {
        done[id]?.contains(UsageLog.dayKey(date, calendar: calendar)) ?? false
    }

    public mutating func toggle(_ id: UUID, on date: Date, calendar: Calendar = .current) {
        let key = UsageLog.dayKey(date, calendar: calendar)
        if done[id, default: []].contains(key) { done[id]?.remove(key) } else { done[id, default: []].insert(key) }
    }

    public mutating func remove(_ id: UUID) {
        habits.removeAll { $0.id == id }
        done[id] = nil
    }
}

public enum HabitMath {
    public static func isScheduled(_ h: Habit, on date: Date, calendar: Calendar = .current) -> Bool {
        switch h.schedule {
        case .daily, .timesPerWeek: return true
        case .weekdays(let days): return days.contains(calendar.component(.weekday, from: date))
        }
    }

    public static func weekStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Times done in the calendar week containing `date`.
    public static func doneInWeek(_ h: Habit, _ cfg: HabitConfig, containing date: Date, calendar: Calendar = .current) -> Int {
        let start = weekStart(date, calendar: calendar)
        return (0..<7).filter { i in
            calendar.date(byAdding: .day, value: i, to: start).map { cfg.isDone(h.id, on: $0, calendar: calendar) } ?? false
        }.count
    }

    /// Current streak. Daily / weekday habits: consecutive scheduled days done (today counts once done; an
    /// unfinished today doesn't break it). Times-per-week habits: consecutive weeks meeting the target
    /// (the current week counts once met).
    public static func streak(_ h: Habit, _ cfg: HabitConfig, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let created = calendar.startOfDay(for: h.createdAt)
        if case .timesPerWeek(let n) = h.schedule {
            var streak = 0
            var week = weekStart(now, calendar: calendar)
            if doneInWeek(h, cfg, containing: week, calendar: calendar) < n {
                week = calendar.date(byAdding: .day, value: -7, to: week)!
            }
            while doneInWeek(h, cfg, containing: week, calendar: calendar) >= max(n, 1) {
                streak += 1
                week = calendar.date(byAdding: .day, value: -7, to: week)!
            }
            return streak
        }
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if !cfg.isDone(h.id, on: day, calendar: calendar) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var guardDays = 0
        while guardDays < 3_650 {
            guardDays += 1
            if isScheduled(h, on: day, calendar: calendar) {
                if cfg.isDone(h.id, on: day, calendar: calendar) { streak += 1 } else { break }
            } else if day < created {
                break
            }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Done / expected over the `days` days ending `now` (not counting days before the habit existed). 0…1.
    public static func completionRate(_ h: Habit, _ cfg: HabitConfig, days: Int = 30, now: Date = Date(),
                                      calendar: Calendar = .current) -> Double {
        let created = calendar.startOfDay(for: h.createdAt)
        let today = calendar.startOfDay(for: now)
        var expected = 0.0, done = 0.0
        for i in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today), d >= created else { continue }
            if isScheduled(h, on: d, calendar: calendar) {
                if case .timesPerWeek = h.schedule {} else { expected += 1 }
                if cfg.isDone(h.id, on: d, calendar: calendar) { done += 1 }
            }
        }
        if case .timesPerWeek(let n) = h.schedule {
            let span = Double(min(days, (calendar.dateComponents([.day], from: created, to: today).day ?? 0) + 1))
            expected = Double(n) * span / 7
        }
        return expected > 0 ? min(1, done / expected) : 0
    }
}

// MARK: - Weekly review

public struct WeeklyReview: Equatable, Sendable {
    public struct HabitLine: Equatable, Sendable {
        public var name: String
        public var done: Int
        public var expected: Int
    }

    public var weekStart: Date
    public var tasksCompleted: [String]
    public var tasksCreated: Int
    public var openTasks: Int
    public var overdueTasks: Int
    public var focusMinutesByDay: [Double]   // 7 values, week order
    public var habits: [HabitLine]
    public var screenTimeSeconds: Double
    public var topApps: [(name: String, seconds: Double)]
    public var messagesReceived: Int?

    public var focusMinutes: Double { focusMinutesByDay.reduce(0, +) }
    public var habitRate: Double {
        let e = habits.reduce(0) { $0 + $1.expected }
        return e > 0 ? Double(habits.reduce(0) { $0 + min($1.done, $1.expected) }) / Double(e) : 0
    }

    public static func == (a: WeeklyReview, b: WeeklyReview) -> Bool {
        a.weekStart == b.weekStart && a.tasksCompleted == b.tasksCompleted && a.tasksCreated == b.tasksCreated
            && a.openTasks == b.openTasks && a.overdueTasks == b.overdueTasks && a.focusMinutesByDay == b.focusMinutesByDay
            && a.habits == b.habits && a.screenTimeSeconds == b.screenTimeSeconds
            && a.topApps.map(\.name) == b.topApps.map(\.name) && a.messagesReceived == b.messagesReceived
    }

    /// Builds the review for the calendar week containing `date`.
    public static func make(weekContaining date: Date, todos: TodoConfig, habits: HabitConfig, usage: UsageLog,
                            messagesReceived: Int? = nil, now: Date = Date(), calendar: Calendar = .current) -> WeeklyReview {
        let start = HabitMath.weekStart(date, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let inWeek: (Date?) -> Bool = { d in d.map { $0 >= start && $0 < end } ?? false }

        let completed = todos.items.filter { $0.isDone && inWeek($0.completedAt) }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }.map(\.title)
        let focus = days.map { todos.focusLog[UsageLog.dayKey($0, calendar: calendar)] ?? 0 }

        let habitLines: [HabitLine] = habits.active.map { h in
            let doneCount = days.filter { habits.isDone(h.id, on: $0, calendar: calendar) }.count
            let expected: Int
            switch h.schedule {
            case .daily: expected = days.filter { $0 >= calendar.startOfDay(for: h.createdAt) }.count
            case .weekdays: expected = days.filter { HabitMath.isScheduled(h, on: $0, calendar: calendar) && $0 >= calendar.startOfDay(for: h.createdAt) }.count
            case .timesPerWeek(let n): expected = n
            }
            return HabitLine(name: h.name, done: doneCount, expected: expected)
        }

        var perApp: [String: Double] = [:]
        for d in days { for (app, secs) in usage.days[UsageLog.dayKey(d, calendar: calendar)] ?? [:] { perApp[app, default: 0] += secs } }
        let top = perApp.sorted { $0.value > $1.value }.prefix(5).map { (name: usage.names[$0.key] ?? $0.key, seconds: $0.value) }

        return WeeklyReview(
            weekStart: start,
            tasksCompleted: completed,
            tasksCreated: todos.items.filter { inWeek($0.createdAt) }.count,
            openTasks: todos.items.filter { !$0.isDone }.count,
            overdueTasks: todos.items.filter { $0.isOverdue(now: now) }.count,
            focusMinutesByDay: focus,
            habits: habitLines,
            screenTimeSeconds: perApp.values.reduce(0, +),
            topApps: top,
            messagesReceived: messagesReceived
        )
    }

    /// Plain Markdown, e.g. to save as a note.
    public func markdown(reflection: String = "", calendar: Calendar = .current) -> String {
        var s = "# Weekly review: week of \(UsageLog.dayKey(weekStart, calendar: calendar))\n\n"
        s += "## Summary\n"
        s += "- Tasks completed: \(tasksCompleted.count) (created \(tasksCreated), open \(openTasks), overdue \(overdueTasks))\n"
        s += "- Focus: \(Int(focusMinutes)) min\n"
        if !habits.isEmpty { s += "- Habits: \(Int((habitRate * 100).rounded()))% of planned check-ins\n" }
        if screenTimeSeconds > 0 { s += "- Screen time: \(MetricFormat.duration(screenTimeSeconds))\n" }
        if let m = messagesReceived { s += "- Messages received: \(m)\n" }
        if !tasksCompleted.isEmpty { s += "\n## Done\n" + tasksCompleted.map { "- [x] \($0)" }.joined(separator: "\n") + "\n" }
        if !habits.isEmpty { s += "\n## Habits\n" + habits.map { "- \($0.name): \($0.done)/\($0.expected)" }.joined(separator: "\n") + "\n" }
        if !topApps.isEmpty { s += "\n## Top apps\n" + topApps.map { "- \($0.name): \(MetricFormat.duration($0.seconds))" }.joined(separator: "\n") + "\n" }
        s += "\n## Reflection\n" + (reflection.isEmpty ? "What went well? What will I change next week?\n" : reflection + "\n")
        return s
    }
}
