import Foundation
import XCTest
@testable import NexusCore

final class HabitsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }()

    func day(_ d: Int, hour: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))! }
    // Nov 2026: Mon 2, Tue 3, … Sun 8, Mon 9 …

    func testDailyStreakAndToday() {
        var cfg = HabitConfig()
        let h = Habit(name: "Read", createdAt: day(1))
        cfg.habits = [h]
        for d in [3, 4, 5] { cfg.toggle(h.id, on: day(d), calendar: cal) }
        // Today (6th) not done yet: streak still counts through yesterday.
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(6), calendar: cal), 3)
        cfg.toggle(h.id, on: day(6), calendar: cal)
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(6), calendar: cal), 4)
        // A missed day breaks it.
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(8), calendar: cal), 0)
        cfg.toggle(h.id, on: day(6), calendar: cal)
        XCTAssertFalse(cfg.isDone(h.id, on: day(6), calendar: cal))
    }

    func testWeekdayScheduleSkipsOffDays() {
        var cfg = HabitConfig()
        let h = Habit(name: "Gym", schedule: .weekdays([2, 4, 6]), createdAt: day(1))   // Mon, Wed, Fri
        cfg.habits = [h]
        for d in [2, 4, 6] { cfg.toggle(h.id, on: day(d), calendar: cal) }
        XCTAssertTrue(HabitMath.isScheduled(h, on: day(2), calendar: cal))
        XCTAssertFalse(HabitMath.isScheduled(h, on: day(3), calendar: cal))
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(8), calendar: cal), 3)   // weekend doesn't break it
        XCTAssertEqual(HabitMath.completionRate(h, cfg, days: 7, now: day(8), calendar: cal), 1, accuracy: 1e-9)
    }

    func testTimesPerWeek() {
        var cfg = HabitConfig()
        let h = Habit(name: "Run", schedule: .timesPerWeek(2), createdAt: day(1))
        cfg.habits = [h]
        // Week of Nov 2: done twice. Week of Nov 9: once so far.
        for d in [3, 5, 10] { cfg.toggle(h.id, on: day(d), calendar: cal) }
        XCTAssertEqual(HabitMath.doneInWeek(h, cfg, containing: day(4), calendar: cal), 2)
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(11), calendar: cal), 1)   // current week not met yet
        cfg.toggle(h.id, on: day(11), calendar: cal)
        XCTAssertEqual(HabitMath.streak(h, cfg, now: day(11), calendar: cal), 2)
    }

    func testWeeklyReviewAndMarkdown() throws {
        var todos = TodoConfig()
        todos.items = [
            TodoItem(title: "Ship", isDone: true, createdAt: day(2), completedAt: day(3)),
            TodoItem(title: "Old", isDone: true, createdAt: day(1), completedAt: day(1)),   // previous week
            TodoItem(title: "Open", due: day(4), createdAt: day(4)),
        ]
        todos.focusLog[UsageLog.dayKey(day(2), calendar: cal)] = 50
        todos.focusLog[UsageLog.dayKey(day(8), calendar: cal)] = 25
        var habits = HabitConfig()
        let h = Habit(name: "Read", createdAt: day(1))
        habits.habits = [h]
        habits.toggle(h.id, on: day(2), calendar: cal)
        var usage = UsageLog()
        usage.record("com.apple.Safari", name: "Safari", from: day(3, hour: 9), to: day(3, hour: 10), calendar: cal)

        let r = WeeklyReview.make(weekContaining: day(5), todos: todos, habits: habits, usage: usage,
                                  messagesReceived: 42, now: day(6), calendar: cal)
        XCTAssertEqual(r.weekStart, cal.startOfDay(for: day(2)))
        XCTAssertEqual(r.tasksCompleted, ["Ship"])
        XCTAssertEqual(r.tasksCreated, 2)
        XCTAssertEqual(r.overdueTasks, 1)
        XCTAssertEqual(r.focusMinutes, 75)
        XCTAssertEqual(r.focusMinutesByDay.first, 50)
        XCTAssertEqual(r.habits, [WeeklyReview.HabitLine(name: "Read", done: 1, expected: 7)])
        XCTAssertEqual(r.topApps.first?.name, "Safari")
        XCTAssertEqual(r.screenTimeSeconds, 3_600)
        let md = r.markdown(reflection: "Good week", calendar: cal)
        XCTAssertTrue(md.contains("- [x] Ship"))
        XCTAssertTrue(md.contains("Messages received: 42"))
        XCTAssertTrue(md.contains("Good week"))
    }

    func testConfigCodable() throws {
        var cfg = HabitConfig()
        let h = Habit(name: "x", schedule: .weekdays([1, 7]))
        cfg.habits = [h]
        cfg.toggle(h.id, on: Date())
        cfg.reflections["2026-11-02"] = "ok"
        XCTAssertEqual(try JSONDecoder().decode(HabitConfig.self, from: JSONEncoder().encode(cfg)), cfg)
    }
}
