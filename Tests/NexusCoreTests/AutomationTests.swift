import Foundation
import XCTest
@testable import NexusCore

final class AutomationTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

    func testMessageMatching() {
        let t = AutomationTrigger.newMessage(platform: "teams", senderContains: "jane", textContains: "", priorityOnly: false)
        let now = Date()
        XCTAssertTrue(AutomationEngine.matches(t, .message(platform: "Teams", sender: "Jane Doe", text: "hi", isPriority: false), now: now))
        XCTAssertFalse(AutomationEngine.matches(t, .message(platform: "whatsapp", sender: "Jane", text: "hi", isPriority: false), now: now))
        XCTAssertFalse(AutomationEngine.matches(t, .message(platform: "teams", sender: "Bob", text: "jane", isPriority: false), now: now))
        let prio = AutomationTrigger.newMessage(platform: "", senderContains: "", textContains: "invoice", priorityOnly: true)
        XCTAssertFalse(AutomationEngine.matches(prio, .message(platform: "x", sender: "a", text: "Invoice due", isPriority: false), now: now))
        XCTAssertTrue(AutomationEngine.matches(prio, .message(platform: "x", sender: "a", text: "Invoice due", isPriority: true), now: now))
        XCTAssertFalse(AutomationEngine.matches(prio, .appLaunched(bundleId: "x", name: "x"), now: now))
    }

    func testAppAndLevelTriggers() {
        let now = Date()
        XCTAssertTrue(AutomationEngine.matches(.appLaunched(bundleId: "com.apple.Safari"), .appLaunched(bundleId: "com.apple.safari", name: "Safari"), now: now))
        XCTAssertTrue(AutomationEngine.matches(.appQuit(bundleId: "Safari"), .appQuit(bundleId: "com.apple.Safari", name: "Safari"), now: now))
        XCTAssertTrue(AutomationEngine.matches(.appQuit(bundleId: ""), .appQuit(bundleId: "a", name: "b"), now: now))
        XCTAssertFalse(AutomationEngine.matches(.appLaunched(bundleId: "a"), .appQuit(bundleId: "a", name: "a"), now: now))
        XCTAssertTrue(AutomationEngine.matches(.batteryBelow(level: 0.2), .battery(level: 0.15, onAC: false), now: now))
        XCTAssertFalse(AutomationEngine.matches(.batteryBelow(level: 0.2), .battery(level: 0.15, onAC: true), now: now))
        XCTAssertTrue(AutomationEngine.matches(.cpuAbove(level: 0.8), .cpu(0.8), now: now))
        XCTAssertTrue(AutomationEngine.matches(.focusEnded, .focusEnded, now: now))
    }

    func testTimeOfDayWeekdaysAndOncePerMinute() {
        // Nov 2 2026 is a Monday (weekday 2).
        let rule = AutomationRule(name: "m", trigger: .timeOfDay(time: "09:00", weekdays: [2, 3]), actions: [.startFocus])
        var cfg = AutomationConfig()
        cfg.rules = [rule]
        XCTAssertEqual(AutomationEngine.due(cfg, for: .tick, now: at(2, 9, 0), calendar: cal).count, 1)
        XCTAssertTrue(AutomationEngine.due(cfg, for: .tick, now: at(2, 9, 1), calendar: cal).isEmpty)
        XCTAssertTrue(AutomationEngine.due(cfg, for: .tick, now: at(1, 9, 0), calendar: cal).isEmpty)   // Sunday
        cfg.record(AutomationLogEntry(date: at(2, 9, 0), ruleId: rule.id, ruleName: "m", trigger: "", results: [], success: true))
        XCTAssertTrue(AutomationEngine.due(cfg, for: .tick, now: at(2, 9, 0).addingTimeInterval(30), calendar: cal).isEmpty)
        XCTAssertEqual(AutomationEngine.due(cfg, for: .tick, now: at(3, 9, 0), calendar: cal).count, 1)
    }

    func testCooldownAndDisabled() {
        var rule = AutomationRule(name: "c", trigger: .focusStarted, actions: [.stopFocus], cooldownMinutes: 10)
        var cfg = AutomationConfig()
        cfg.rules = [rule]
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AutomationEngine.due(cfg, for: .focusStarted, now: t0).count, 1)
        cfg.lastRun[rule.id] = t0
        XCTAssertTrue(AutomationEngine.due(cfg, for: .focusStarted, now: t0 + 300).isEmpty)
        XCTAssertEqual(AutomationEngine.due(cfg, for: .focusStarted, now: t0 + 600).count, 1)
        rule.enabled = false
        cfg.rules = [rule]
        XCTAssertTrue(AutomationEngine.due(cfg, for: .focusStarted, now: t0 + 9_999).isEmpty)
        // Level triggers repeat at most every 10 minutes even with no cooldown.
        let level = AutomationRule(name: "b", trigger: .cpuAbove(level: 0.5), actions: [])
        var c2 = AutomationConfig(); c2.rules = [level]; c2.lastRun[level.id] = t0
        XCTAssertTrue(AutomationEngine.due(c2, for: .cpu(0.9), now: t0 + 60).isEmpty)
    }

    func testTemplatesLogAndCodable() throws {
        let values = AutomationEvent.message(platform: "Teams", sender: "Jane", text: "a b", isPriority: true).values(now: Date())
        XCTAssertEqual(AutomationAction.addTask(title: "Reply to {sender}").filled(values), .addTask(title: "Reply to Jane"))
        XCTAssertEqual(AutomationAction.openURL("https://x.com/?q={text}").filled(values), .openURL("https://x.com/?q=a%20b"))
        XCTAssertEqual(AutomationAction.notify(title: "{unknown}", body: "").filled(values), .notify(title: "{unknown}", body: ""))
        var cfg = AutomationConfig()
        cfg.logLimit = 2
        cfg.rules = AutomationEngine.examples
        for i in 0..<3 {
            cfg.record(AutomationLogEntry(date: Date(timeIntervalSince1970: Double(i)), ruleId: cfg.rules[0].id, ruleName: "r\(i)",
                                          trigger: "t", results: ["ok"], success: true))
        }
        XCTAssertEqual(cfg.log.map(\.ruleName), ["r2", "r1"])
        XCTAssertEqual(try JSONDecoder().decode(AutomationConfig.self, from: JSONEncoder().encode(cfg)), cfg)
        XCTAssertTrue(AutomationTrigger.timeOfDay(time: "09:00", weekdays: []).summary.contains("Every day"))
    }
}
