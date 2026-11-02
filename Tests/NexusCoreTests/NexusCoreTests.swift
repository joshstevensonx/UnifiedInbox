import Foundation
import XCTest
@testable import NexusCore

final class MetricCalculationTests: XCTestCase {
    func testCPUUsage() throws {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)   // +60 +20 +100 +20 = 200
        let r = try XCTUnwrap(CPUTicks.usage(from: a, to: b))
        XCTAssertEqual(r.total, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.user, 0.4, accuracy: 1e-9)   // (60 + 20 nice) / 200
        XCTAssertEqual(r.system, 0.1, accuracy: 1e-9)
    }

    func testCPUResetAndNoTimeReturnNil() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        XCTAssertNil(CPUTicks.usage(from: a, to: CPUTicks(user: 10, system: 50, idle: 900, nice: 0)))
        XCTAssertNil(CPUTicks.usage(from: a, to: a))
    }

    func testNetworkThroughputAndReset() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        let a = NetworkCounters(bytesIn: 1_000, bytesOut: 500, timestamp: t0)
        let b = NetworkCounters(bytesIn: 5_000, bytesOut: 1_500, timestamp: t0.addingTimeInterval(2))
        let r = try XCTUnwrap(NetworkCounters.throughput(from: a, to: b))
        XCTAssertEqual(r.downBytesPerSecond, 2_000)
        XCTAssertEqual(r.upBytesPerSecond, 500)
        let reset = NetworkCounters(bytesIn: 10, bytesOut: 10, timestamp: t0.addingTimeInterval(4))
        XCTAssertNil(NetworkCounters.throughput(from: b, to: reset))
        XCTAssertNil(NetworkCounters.throughput(from: a, to: a))
    }

    func testInterfaceFilter() {
        XCTAssertTrue(NetworkCounters.isCountedInterface("en0"))
        XCTAssertTrue(NetworkCounters.isCountedInterface("pdp_ip0"))
        XCTAssertFalse(NetworkCounters.isCountedInterface("lo0"))
        XCTAssertFalse(NetworkCounters.isCountedInterface("utun3"))
        XCTAssertFalse(NetworkCounters.isCountedInterface("awdl0"))
    }

    func testRingBuffer() {
        var r = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(r.elements, [])
        [1, 2].forEach { r.append($0) }
        XCTAssertEqual(r.elements, [1, 2])
        [3, 4, 5].forEach { r.append($0) }
        XCTAssertEqual(r.elements, [3, 4, 5])
        XCTAssertEqual(r.last, 5)
        r.removeAll()
        XCTAssertEqual(r.count, 0)
    }

    func testMemoryPressureAndFormatting() {
        XCTAssertEqual(MemoryPressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(sysctlLevel: nil), .unknown)
        XCTAssertEqual(MetricFormat.percent(0.456), "46%")
        XCTAssertEqual(MetricFormat.bytes(512), "512 B")
        XCTAssertEqual(MetricFormat.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(MetricFormat.rate(25_000_000), "25 MB/s")
        XCTAssertEqual(MetricFormat.duration(3 * 86_400 + 5 * 3600), "3d 5h")
        XCTAssertEqual(MetricFormat.duration(125 * 60), "2h 5m")
    }

    func testStaleSnapshot() {
        let s = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(s.isStale(now: Date(timeIntervalSince1970: 105)))
        XCTAssertTrue(s.isStale(now: Date(timeIntervalSince1970: 107)))
    }
}

final class LauncherTests: XCTestCase {
    private func app(_ title: String, pinned: Bool = false, uses: Int = 0, bundle: String? = nil) -> LauncherItem {
        LauncherItem(kind: .app, title: title, target: "/Applications/\(title).app",
                     bundleId: bundle ?? "com.test.\(title.lowercased().replacingOccurrences(of: " ", with: ""))",
                     isPinned: pinned, useCount: uses, isDiscovered: true)
    }

    func testScoringOrder() {
        XCTAssertEqual(LauncherSearch.score("Safari", query: "safari"), 1000)
        XCTAssertGreaterThan(LauncherSearch.score("Safari", query: "saf")!, LauncherSearch.score("Visual Studio Code", query: "stu")!)
        XCTAssertEqual(LauncherSearch.score("Visual Studio Code", query: "vsc"), 500)
        XCTAssertEqual(LauncherSearch.score("Activity Monitor", query: "ivity"), 400)
        XCTAssertEqual(LauncherSearch.score("Activity Monitor", query: "acmn"), 100)
        XCTAssertNil(LauncherSearch.score("Safari", query: "xyz"))
    }

    func testSearchRanksAndBreaksTies() {
        let items = [app("Notes"), app("Notion", uses: 5), app("Numbers", pinned: true), app("Xcode")]
        XCTAssertEqual(LauncherSearch.search(items, query: "no").map(\.title), ["Notion", "Notes"])
        XCTAssertEqual(LauncherSearch.search(items, query: "n").map(\.title), ["Numbers", "Notion", "Notes"])
        XCTAssertEqual(LauncherSearch.search(items, query: "").count, 4)
    }

    func testSorting() {
        var a = app("B"), b = app("a"), c = app("C")
        a.lastUsed = Date(timeIntervalSince1970: 10); c.lastUsed = Date(timeIntervalSince1970: 20)
        a.useCount = 3
        XCTAssertEqual(LauncherSearch.sorted([a, b, c], by: .alphabetical).map(\.title), ["a", "B", "C"])
        XCTAssertEqual(LauncherSearch.sorted([a, b, c], by: .recent).map(\.title), ["C", "B", "a"])
        XCTAssertEqual(LauncherSearch.sorted([a, b, c], by: .frequent).first?.title, "B")
    }

    func testMergeKeepsStateAndHandlesMovesAndRemovals() {
        var config = LauncherConfig()
        var safari = app("Safari", bundle: "com.apple.Safari"); safari.isPinned = true; safari.useCount = 7
        let removed = app("OldApp", bundle: "com.old")
        let url = LauncherItem(kind: .url, title: "Docs", target: "https://example.com")
        config.items = [safari, removed, url]
        var moved = app("Safari", bundle: "com.apple.Safari"); moved.target = "/System/Applications/Safari.app"
        config.mergeDiscovered([moved, app("New App", bundle: "com.new")])
        let s = config.items.first { $0.bundleId == "com.apple.Safari" }!
        XCTAssertTrue(s.isPinned); XCTAssertEqual(s.useCount, 7); XCTAssertEqual(s.id, safari.id)
        XCTAssertEqual(s.target, "/System/Applications/Safari.app")
        XCTAssertNil(config.items.first { $0.bundleId == "com.old" })
        XCTAssertNotNil(config.items.first { $0.kind == .url })
        XCTAssertEqual(config.items.count, 3)
        config.recordLaunch(s.id, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(config.items.first { $0.id == s.id }?.useCount, 8)
    }

    func testJSONStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/launcher.json")
        let store = JSONFileStore<LauncherConfig>(url: url)
        XCTAssertNil(store.load())
        var config = LauncherConfig(items: [app("Mail")], groups: [LauncherGroup(name: "Work")], sort: .recent)
        config.items[0].lastUsed = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(config)
        XCTAssertEqual(store.load(), config)
    }
}

final class WidgetLayoutTests: XCTestCase {
    let main = DisplayInfo(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isPrimary: true)
    let side = DisplayInfo(id: 2, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055), isPrimary: false)

    func testClampKeepsWidgetOnScreen() {
        let f = WidgetLayout.clamp(CGRect(x: 1400, y: 860, width: 200, height: 120), to: main.visibleFrame)
        XCTAssertEqual(f, CGRect(x: 1240, y: 755, width: 200, height: 120))
        let tiny = WidgetLayout.clamp(CGRect(x: 10, y: 10, width: 20, height: 20), to: main.visibleFrame)
        XCTAssertEqual(tiny.size, WidgetKind.minimumSize)
    }

    func testRestorePrefersKnownDisplayThenOverlapThenPrimary() {
        var w = WidgetInstance(kind: .cpu, frame: CGRect(x: 2000, y: 100, width: 180, height: 130), displayID: 2)
        XCTAssertEqual(WidgetLayout.restore(w, displays: [main, side]).displayID, 2)
        w.displayID = 99
        XCTAssertEqual(WidgetLayout.restore(w, displays: [main, side]).displayID, 2)   // overlap
        // Side display disconnected → primary, clamped on-screen.
        let r = WidgetLayout.restore(w, displays: [main])
        XCTAssertEqual(r.displayID, 1)
        XCTAssertTrue(main.visibleFrame.contains(r.frame))
    }

    func testPlacementCascades() {
        let first = WidgetLayout.placement(for: .cpu, existing: [], in: main.visibleFrame)
        let second = WidgetLayout.placement(for: .cpu, existing: [first], in: main.visibleFrame)
        XCTAssertNotEqual(first.origin, second.origin)
        XCTAssertTrue(main.visibleFrame.contains(second))
    }

    func testConfigCodable() throws {
        let config = WidgetConfig(widgets: [WidgetInstance(kind: .clock, frame: CGRect(x: 1, y: 2, width: 220, height: 110))])
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(WidgetConfig.self, from: data), config)
    }
}

final class ClipboardTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(ClipClassifier.classify("https://nexoraweb.agency/x?y=1"), .url)
        XCTAssertEqual(ClipClassifier.classify("#1E2A44"), .color)
        XCTAssertEqual(ClipClassifier.classify("#fff"), .color)
        XCTAssertEqual(ClipClassifier.classify("#ggg"), .text)
        XCTAssertEqual(ClipClassifier.classify("~/Desktop/DEV/UnifiedInbox"), .path)
        XCTAssertEqual(ClipClassifier.classify("/Applications/Safari.app"), .path)
        XCTAssertEqual(ClipClassifier.classify("hello world"), .text)
        XCTAssertEqual(ClipClassifier.classify("line1\nhttps://x.com"), .text)
        XCTAssertEqual(ClipClassifier.classify("https://"), .text)
        let c = ClipClassifier.rgba("#FF000080")!
        XCTAssertEqual(c.0, 1); XCTAssertEqual(c.1, 0); XCTAssertEqual(c.3, 128.0 / 255, accuracy: 1e-9)
    }

    func testHistoryDedupeLimitAndPins() {
        var h = ClipHistory(limit: 3)
        let a = ClipEntry(kind: .text, text: "a", date: Date(timeIntervalSince1970: 1))
        h.add(a)
        h.add(ClipEntry(kind: .text, text: "b", date: Date(timeIntervalSince1970: 2)))
        h.togglePin(a.id)
        h.add(ClipEntry(kind: .text, text: "c", date: Date(timeIntervalSince1970: 3)))
        h.add(ClipEntry(kind: .text, text: "d", date: Date(timeIntervalSince1970: 4)))
        h.add(ClipEntry(kind: .text, text: "e", date: Date(timeIntervalSince1970: 5)))
        // limit 3 unpinned (e, d, c) + pinned a
        XCTAssertEqual(h.entries.map(\.text), ["e", "d", "c", "a"])
        h.add(ClipEntry(kind: .text, text: "c", date: Date(timeIntervalSince1970: 6)))
        XCTAssertEqual(h.entries.first?.text, "c")
        XCTAssertEqual(h.entries.count, 4)
        XCTAssertEqual(h.search("").first?.text, "a")     // pinned first
        XCTAssertEqual(h.search("D").map(\.text), ["d"])
        h.clearUnpinned()
        XCTAssertEqual(h.entries.map(\.text), ["a"])
    }
}

final class PaletteTests: XCTestCase {
    func testAliasResolveAndExpand() {
        var cfg = AliasConfig()
        cfg.aliases.append(CommandAlias(alias: "G", target: .url("https://www.google.com/search?q={query}"), title: "Google"))
        XCTAssertEqual(cfg.resolve("yt")?.alias.title, "YouTube")
        let r = cfg.resolve("g swift concurrency")
        XCTAssertEqual(r?.argument, "swift concurrency")
        if case .url(let u)? = r?.alias.target {
            XCTAssertEqual(AliasConfig.expand(u, argument: r?.argument), "https://www.google.com/search?q=swift%20concurrency")
        } else { XCTFail() }
        XCTAssertNil(cfg.resolve("youtube"))
    }

    func testRankUsesKeywords() {
        struct C { let t: String; let k: [String] }
        let items = [C(t: "Take Screenshot", k: ["capture", "region"]), C(t: "Capture Text (OCR)", k: ["ocr"])]
        let r = PaletteRanking.rank(items, query: "capt", title: \.t, keywords: \.k)
        XCTAssertEqual(r.map(\.t), ["Capture Text (OCR)", "Take Screenshot"])
        XCTAssertTrue(PaletteRanking.rank(items, query: "zzz", title: \.t, keywords: \.k).isEmpty)
    }
}

final class UsageTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Africa/Johannesburg")!; return c }
    func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

    func testRecordSplitsAtMidnightAndRanks() {
        var log = UsageLog()
        log.record("com.apple.Safari", name: "Safari", from: d(2, 23, 30), to: d(3, 0, 30), calendar: cal)
        log.record("com.microsoft.teams2", name: "Teams", from: d(3, 9), to: d(3, 10), calendar: cal)
        XCTAssertEqual(log.total(on: d(2, 12), calendar: cal), 1800, accuracy: 0.001)
        XCTAssertEqual(log.top(on: d(3, 12), calendar: cal).map(\.bundleId), ["com.microsoft.teams2", "com.apple.Safari"])
        log.categories["com.microsoft.teams2"] = .productive
        let cats = log.byCategory(on: d(3, 12), calendar: cal)
        XCTAssertEqual(cats[.productive], 3600); XCTAssertEqual(cats[.neutral], 1800)
        XCTAssertEqual(log.dailyTotals(endingOn: d(3, 12), count: 2, calendar: cal).map(\.seconds), [1800, 5400])
        log.retentionDays = 0
        log.prune(now: d(3, 12), calendar: cal)
        XCTAssertNil(log.days["2026-11-02"])
        XCTAssertNotNil(log.days["2026-11-03"])
    }
}

final class FocusTests: XCTestCase {
    func testPomodoroCycle() {
        var t = PomodoroTimer()
        let t0 = Date(timeIntervalSince1970: 0)
        t.startFocus(now: t0)
        XCTAssertEqual(t.phase, .focus)
        XCTAssertNil(t.tick(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(t.progress(now: t0.addingTimeInterval(750)), 0.5, accuracy: 1e-9)
        t.pause(now: t0.addingTimeInterval(600))
        XCTAssertEqual(t.remaining(now: t0.addingTimeInterval(9999)), 900)
        t.resume(now: t0.addingTimeInterval(1000))
        XCTAssertEqual(t.tick(now: t0.addingTimeInterval(1900)), .focus)   // 1000 + 900
        XCTAssertEqual(t.phase, .shortBreak)
        XCTAssertEqual(t.completedFocusSessions, 1)
        XCTAssertEqual(t.tick(now: t0.addingTimeInterval(1900 + 300)), .shortBreak)
        XCTAssertEqual(t.phase, .idle)
        XCTAssertEqual(PomodoroTimer.format(65), "01:05")
    }

    func testLongBreakEveryFourth() {
        var t = PomodoroTimer()
        var now = Date(timeIntervalSince1970: 0)
        for _ in 0..<4 {
            t.startFocus(now: now)
            now = now.addingTimeInterval(25 * 60)
            _ = t.tick(now: now)
        }
        XCTAssertEqual(t.phase, .longBreak)
    }

    func testQuickAddParsingAndSorting() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10))!
        let item = TodoItem.parse("Call Martin tomorrow !high #nexora", now: now, calendar: cal)
        XCTAssertEqual(item.title, "Call Martin")
        XCTAssertEqual(item.priority, .high)
        XCTAssertEqual(item.tags, ["nexora"])
        XCTAssertEqual(item.due, cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9)))

        var cfg = TodoConfig()
        cfg.items = [
            TodoItem(title: "done", isDone: true, createdAt: now),
            TodoItem(title: "low", priority: .low, createdAt: now),
            TodoItem(title: "overdue", priority: .low, due: now.addingTimeInterval(-60), createdAt: now),
            TodoItem(title: "urgent", priority: .urgent, createdAt: now),
        ]
        XCTAssertEqual(cfg.sorted(now: now).map(\.title), ["overdue", "urgent", "low", "done"])
        XCTAssertTrue(cfg.items[2].isOverdue(now: now))

        cfg.logFocus(minutes: 25, taskId: cfg.items[1].id, on: now, calendar: cal)
        cfg.logFocus(minutes: 25, taskId: nil, on: now.addingTimeInterval(-86_400), calendar: cal)
        XCTAssertEqual(cfg.items[1].focusMinutes, 25)
        XCTAssertEqual(cfg.focusStreak(now: now, calendar: cal), 2)
    }
}
