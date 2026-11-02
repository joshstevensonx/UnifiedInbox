import Foundation

// MARK: - Pomodoro (spec §11.3)

public enum PomodoroPhase: String, Codable, Sendable {
    case idle, focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    public var isBreak: Bool { self == .shortBreak || self == .longBreak }
}

public struct PomodoroSettings: Codable, Equatable, Sendable {
    public var focusMinutes: Double = 25
    public var shortBreakMinutes: Double = 5
    public var longBreakMinutes: Double = 15
    public var longBreakEvery: Int = 4
    public var autoStartBreaks = true
    public init() {}

    public func duration(_ p: PomodoroPhase) -> TimeInterval {
        switch p {
        case .idle: return 0
        case .focus: return focusMinutes * 60
        case .shortBreak: return shortBreakMinutes * 60
        case .longBreak: return longBreakMinutes * 60
        }
    }
}

/// Pure state machine; the app drives it with `tick(now:)` once a second.
public struct PomodoroTimer: Codable, Equatable, Sendable {
    public var settings = PomodoroSettings()
    public private(set) var phase: PomodoroPhase = .idle
    public private(set) var endsAt: Date?
    /// Set while paused.
    public private(set) var pausedRemaining: TimeInterval?
    public private(set) var completedFocusSessions = 0
    /// Task the focus session is attached to (optional).
    public var taskId: UUID?

    public init(settings: PomodoroSettings = PomodoroSettings()) { self.settings = settings }

    public var isRunning: Bool { phase != .idle && pausedRemaining == nil }
    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(now: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return settings.duration(.focus) }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// 0…1 progress through the current phase.
    public func progress(now: Date = Date()) -> Double {
        let total = settings.duration(phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(now: now) / total))
    }

    public mutating func startFocus(now: Date = Date()) { begin(.focus, now: now) }

    public mutating func pause(now: Date = Date()) {
        guard isRunning else { return }
        pausedRemaining = remaining(now: now)
        endsAt = nil
    }

    public mutating func resume(now: Date = Date()) {
        guard let r = pausedRemaining else { return }
        endsAt = now.addingTimeInterval(r)
        pausedRemaining = nil
    }

    public mutating func stop() {
        phase = .idle; endsAt = nil; pausedRemaining = nil
    }

    /// Ends the current phase early (counts a focus session only if it actually finished).
    public mutating func skip(now: Date = Date()) -> PomodoroPhase? { advance(now: now, finished: false) }

    /// Returns the phase that just *ended*, if any, so the app can notify and log focus time.
    public mutating func tick(now: Date = Date()) -> PomodoroPhase? {
        guard isRunning, let endsAt, now >= endsAt else { return nil }
        return advance(now: now, finished: true)
    }

    private mutating func advance(now: Date, finished: Bool) -> PomodoroPhase? {
        let ended = phase
        switch phase {
        case .idle:
            return nil
        case .focus:
            if finished { completedFocusSessions += 1 }
            let long = completedFocusSessions > 0 && completedFocusSessions % settings.longBreakEvery == 0 && finished
            if settings.autoStartBreaks { begin(long ? .longBreak : .shortBreak, now: now) } else { stop() }
        case .shortBreak, .longBreak:
            stop()
        }
        return ended
    }

    private mutating func begin(_ p: PomodoroPhase, now: Date) {
        phase = p
        pausedRemaining = nil
        endsAt = now.addingTimeInterval(settings.duration(p))
    }

    public static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Tasks (spec §11.1, §11.2)

public enum TodoPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case urgent = 0, high, normal, low
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var priority: TodoPriority
    public var due: Date?
    public var tags: [String]
    public var isDone: Bool
    public var createdAt: Date
    public var completedAt: Date?
    /// Focus minutes logged against this task.
    public var focusMinutes: Double

    public init(id: UUID = UUID(), title: String, notes: String = "", priority: TodoPriority = .normal,
                due: Date? = nil, tags: [String] = [], isDone: Bool = false, createdAt: Date = Date(),
                completedAt: Date? = nil, focusMinutes: Double = 0) {
        self.id = id; self.title = title; self.notes = notes; self.priority = priority; self.due = due
        self.tags = tags; self.isDone = isDone; self.createdAt = createdAt; self.completedAt = completedAt
        self.focusMinutes = focusMinutes
    }

    public func isOverdue(now: Date = Date()) -> Bool { !isDone && (due.map { $0 < now } ?? false) }

    public func isDueSoon(now: Date = Date(), within: TimeInterval = 86_400) -> Bool {
        guard !isDone, let due else { return false }
        return due >= now && due.timeIntervalSince(now) <= within
    }

    /// Quick-add parsing: "Call Martin tomorrow !high #nexora" → title, priority, tags, due.
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> TodoItem {
        var words: [String] = []
        var priority = TodoPriority.normal
        var tags: [String] = []
        var due: Date?
        for raw in input.split(separator: " ") {
            let w = String(raw)
            let lower = w.lowercased()
            switch lower {
            case "!urgent", "!!!": priority = .urgent
            case "!high", "!!": priority = .high
            case "!low": priority = .low
            case "today": due = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now)
            case "tomorrow":
                due = calendar.date(byAdding: .day, value: 1, to: now)
                    .flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
            default:
                if lower.hasPrefix("#"), lower.count > 1 { tags.append(String(lower.dropFirst())) } else { words.append(w) }
            }
        }
        return TodoItem(title: words.joined(separator: " "), priority: priority, due: due, tags: tags, createdAt: now)
    }
}

public struct TodoConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var items: [TodoItem] = []
    /// Day key → focus minutes (deep-work tracking).
    public var focusLog: [String: Double] = [:]
    public var pomodoro = PomodoroSettings()
    public init() {}

    /// Open first; then overdue, priority, due date, creation.
    public func sorted(now: Date = Date()) -> [TodoItem] {
        items.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.isDone { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
            if a.isOverdue(now: now) != b.isOverdue(now: now) { return a.isOverdue(now: now) }
            if a.priority != b.priority { return a.priority < b.priority }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.createdAt < b.createdAt
            }
        }
    }

    public mutating func logFocus(minutes: Double, taskId: UUID?, on date: Date = Date(), calendar: Calendar = .current) {
        focusLog[UsageLog.dayKey(date, calendar: calendar), default: 0] += minutes
        if let taskId, let i = items.firstIndex(where: { $0.id == taskId }) { items[i].focusMinutes += minutes }
    }

    /// Consecutive days (ending today or yesterday) with any focus time.
    public func focusStreak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if (focusLog[UsageLog.dayKey(day, calendar: calendar)] ?? 0) == 0 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        while (focusLog[UsageLog.dayKey(day, calendar: calendar)] ?? 0) > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }
}
