import Foundation
import GRDB
import XCTest
@testable import InboxCore

final class PlatformTests: XCTestCase {
    func testBundleMapping() {
        XCTAssertEqual(Platform.from(bundleIdentifier: "com.microsoft.teams2"), .teams)
        XCTAssertEqual(Platform.from(bundleIdentifier: "com.microsoft.outlook"), .outlook)
        XCTAssertEqual(Platform.from(bundleIdentifier: "net.whatsapp.WhatsApp"), .whatsapp)
        XCTAssertNil(Platform.from(bundleIdentifier: "com.apple.Notes"))
    }
}

final class ParserTests: XCTestCase {
    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    func testParsesTeamsRecord() throws {
        let data = try plist([
            "app": "com.microsoft.teams2",
            "date": 783_456_789.0,
            "req": ["titl": "Jane Doe", "subt": "Project chat", "body": "Can you review?", "thre": "19:abc"],
        ])
        let raw = NotificationRecordParser.RawRecord(
            recId: 1, uuid: "U1", appIdentifier: "com.microsoft.teams2", data: data, deliveredDate: nil)
        let item = try XCTUnwrap(NotificationRecordParser.parse(raw))
        XCTAssertEqual(item.id, "nc:U1")
        XCTAssertEqual(item.platform, .teams)
        XCTAssertEqual(item.title, "Jane Doe")
        XCTAssertEqual(item.subtitle, "Project chat")
        XCTAssertEqual(item.body, "Can you review?")
        XCTAssertEqual(item.threadId, "19:abc")
        XCTAssertEqual(item.receivedAt, Date(timeIntervalSinceReferenceDate: 783_456_789))
    }

    func testIgnoresOtherAppsAndEmptyRecords() throws {
        let data = try plist(["req": ["titl": "Hi"]])
        XCTAssertNil(NotificationRecordParser.parse(.init(recId: 1, uuid: "a", appIdentifier: "com.apple.Notes", data: data, deliveredDate: nil)))
        let empty = try plist(["req": [String: Any]()])
        XCTAssertNil(NotificationRecordParser.parse(.init(recId: 2, uuid: "b", appIdentifier: "net.whatsapp.WhatsApp", data: empty, deliveredDate: nil)))
    }

    func testUUIDBlob() {
        let uuid = UUID()
        let data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        XCTAssertEqual(NotificationRecordParser.uuidString(from: data), uuid.uuidString)
    }
}

final class StoreTests: XCTestCase {
    private func item(_ id: String, _ platform: Platform, _ title: String, _ body: String, minutesAgo: Double = 0) -> InboxItem {
        InboxItem(id: id, platform: platform, origin: .notificationCenter, sourceBundleId: platform.launchBundleIdentifier,
                  title: title, body: body, receivedAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    func testInsertDedupeAndUserStatePreserved() throws {
        let store = try InboxStore(path: nil)
        XCTAssertEqual(try store.insertNew([item("1", .teams, "Jane", "hello")]).count, 1)
        try store.setRead(["1"], true)
        XCTAssertEqual(try store.insertNew([item("1", .teams, "Jane", "hello")]).count, 0)
        XCTAssertTrue(try store.fetch(filter: .all).first!.isRead)
    }

    func testFiltersAndCounts() throws {
        let store = try InboxStore(path: nil)
        try store.insertNew([
            item("1", .teams, "Jane", "standup notes", minutesAgo: 3),
            item("2", .outlook, "Invoice", "Payment due", minutesAgo: 2),
            item("3", .whatsapp, "Mom", "Call me", minutesAgo: 1),
        ])
        XCTAssertEqual(try store.fetch(filter: .all).map(\.id), ["3", "2", "1"])
        XCTAssertEqual(try store.fetch(filter: .platform(.outlook)).map(\.id), ["2"])
        try store.setArchived(["3"], true)
        try store.setPinned(["1"], true)
        XCTAssertEqual(try store.fetch(filter: .archived).map(\.id), ["3"])
        XCTAssertEqual(try store.fetch(filter: .pinned).map(\.id), ["1"])
        XCTAssertEqual(try store.unreadCounts(), [.teams: 1, .outlook: 1])
        try store.markAllRead(in: .platform(.teams))
        XCTAssertEqual(try store.unreadCounts(), [.outlook: 1])
    }

    func testFullTextSearch() throws {
        let store = try InboxStore(path: nil)
        try store.insertNew([
            item("1", .teams, "Jane", "Quarterly roadmap review"),
            item("2", .outlook, "Billing", "Your invoice is ready"),
        ])
        XCTAssertEqual(try store.fetch(filter: .all, search: "road").map(\.id), ["1"])
        XCTAssertEqual(try store.fetch(filter: .all, search: "INVOICE").map(\.id), ["2"])
        XCTAssertEqual(try store.fetch(filter: .all, search: "\"unbalanced").count, 0)
        XCTAssertEqual(try store.fetch(filter: .all, search: "   ").count, 2)
    }

    func testPurgeKeepsPinned() throws {
        let store = try InboxStore(path: nil)
        try store.insertNew([item("old", .teams, "a", "b", minutesAgo: 60 * 24 * 40),
                             item("pinned", .teams, "a", "b", minutesAgo: 60 * 24 * 40)])
        try store.setPinned(["pinned"], true)
        XCTAssertEqual(try store.purge(olderThan: Date().addingTimeInterval(-86_400 * 30)), 1)
        XCTAssertEqual(try store.fetch(filter: .pinned).map(\.id), ["pinned"])
    }
}

final class NotificationCenterSourceTests: XCTestCase {
    /// Builds a fake Notification Center DB with the same shape as macOS's.
    func testPollReadsOnlyTrackedAppsAndAdvancesCursor() async throws {
        let path = try makeFakeDB()
        let store = try InboxStore(path: nil)
        let source = NotificationCenterSource(databasePath: path)
        XCTAssertEqual(source.checkAccess(), .running)
        let first = try await source.poll(store: store)
        XCTAssertEqual(first.map(\.title).sorted(), ["Teams msg", "WA msg"])
        XCTAssertEqual(try store.value(for: "notificationCenter.lastRecId"), "3")
        let second = try await source.poll(store: store)
        XCTAssertTrue(second.isEmpty)
    }

    private func makeFakeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db").path
        let fake = try DatabaseQueue(path: path)
        func blob(_ app: String, _ title: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["app": app, "req": ["titl": title, "body": "msg"]], format: .binary, options: 0)
        }
        try fake.write { db in
            try db.execute(sql: """
                CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT);
                CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL);
                INSERT INTO app VALUES (1, 'com.microsoft.teams2'), (2, 'com.apple.mail'), (3, 'net.whatsapp.WhatsApp');
                """)
            for (rec, app, title) in [(1, 1, "Teams msg"), (2, 2, "Mail msg"), (3, 3, "WA msg")] {
                let uuid = withUnsafeBytes(of: UUID().uuid) { Data($0) }
                try db.execute(sql: "INSERT INTO record VALUES (?, ?, ?, ?, ?)",
                               arguments: [rec, app, uuid, try blob(app == 1 ? "com.microsoft.teams2" : "x", title), 700_000_000.0 + Double(rec)])
            }
        }
        try fake.close()
        return path
    }
}

final class AlertRulesTests: XCTestCase {
    private func item(_ title: String, _ body: String, subtitle: String? = nil) -> InboxItem {
        InboxItem(id: UUID().uuidString, platform: .teams, origin: .notificationCenter,
                  sourceBundleId: "com.microsoft.teams2", title: title, subtitle: subtitle, body: body, receivedAt: Date())
    }

    func testParsingAndDedupe() {
        let r = AlertRules(vipText: "Martin, martin ,\nChatru", keywordText: " urgent,, invoice* ")
        XCTAssertEqual(r.vipSenders, ["Martin", "Chatru"])
        XCTAssertEqual(r.keywords, ["urgent", "invoice*"])
    }

    func testVIPMatchesTitleCaseInsensitive() {
        let r = AlertRules(vipSenders: ["martin nicholson"])
        XCTAssertEqual(r.match(item("Martin Nicholson", "hi")), .vip("martin nicholson"))
        XCTAssertNil(r.match(item("Jane", "martin nicholson said hi")))
    }

    func testKeywordWholeWordAndPrefix() {
        let r = AlertRules(keywords: ["urgent", "invoice*", "server down"])
        XCTAssertEqual(r.match(item("Ops", "This is URGENT!")), .keyword("urgent"))
        XCTAssertNil(r.match(item("Ops", "nonurgentthing")))
        XCTAssertEqual(r.match(item("Billing", "Your invoices are ready")), .keyword("invoice*"))
        XCTAssertEqual(r.match(item("Alerts", "x", subtitle: "Server down in eu-west")), .keyword("server down"))
        XCTAssertEqual(AlertRules(keywords: ["cafe"]).match(item("A", "Meet at the Café")), .keyword("cafe"))
    }
}

final class SnoozeTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testWakeDates() {
        let mon10 = date(2026, 11, 2, 10)        // Monday 10:00
        XCTAssertEqual(SnoozeOption.oneHour.wakeDate(from: mon10, calendar: cal), date(2026, 11, 2, 11))
        XCTAssertEqual(SnoozeOption.thisEvening.wakeDate(from: mon10, calendar: cal), date(2026, 11, 2, 18))
        XCTAssertEqual(SnoozeOption.thisEvening.wakeDate(from: date(2026, 11, 2, 19), calendar: cal), date(2026, 11, 3, 18))
        XCTAssertEqual(SnoozeOption.tomorrowMorning.wakeDate(from: mon10, calendar: cal), date(2026, 11, 3, 8))
        XCTAssertEqual(SnoozeOption.nextWeek.wakeDate(from: mon10, calendar: cal), date(2026, 11, 9, 8))
        XCTAssertEqual(SnoozeOption.nextWeek.wakeDate(from: date(2026, 11, 8, 12), calendar: cal), date(2026, 11, 9, 8)) // Sunday
    }

    func testSnoozeHidesThenWakesUnread() throws {
        let store = try InboxStore(path: nil)
        let now = Date()
        try store.insertNew([InboxItem(id: "1", platform: .whatsapp, origin: .notificationCenter,
                                       sourceBundleId: "net.whatsapp.WhatsApp", title: "Mom", body: "Call", receivedAt: now)])
        try store.setRead(["1"], true)
        try store.snooze(["1"], until: now.addingTimeInterval(60))
        XCTAssertTrue(try store.fetch(filter: .all).isEmpty)
        XCTAssertEqual(try store.fetch(filter: .snoozed).map(\.id), ["1"])
        XCTAssertEqual(try store.unreadCounts(), [:])
        XCTAssertTrue(try store.wakeSnoozed(now: now).isEmpty)
        XCTAssertEqual(try store.wakeSnoozed(now: now.addingTimeInterval(61)).map(\.id), ["1"])
        let back = try XCTUnwrap(store.fetch(filter: .all).first)
        XCTAssertFalse(back.isRead)
        XCTAssertNil(back.snoozedUntil)
    }

    func testPriorityFlagAndReclassify() throws {
        let store = try InboxStore(path: nil)
        let rules = AlertRules(vipSenders: ["Boss"])
        let new = try store.insertNew([
            InboxItem(id: "a", platform: .teams, origin: .notificationCenter, sourceBundleId: "x", title: "Boss", body: "hi", receivedAt: Date()),
            InboxItem(id: "b", platform: .teams, origin: .notificationCenter, sourceBundleId: "x", title: "Jane", body: "hi", receivedAt: Date()),
        ], rules: rules)
        XCTAssertEqual(new.filter(\.isPriority).map(\.id), ["a"])
        XCTAssertEqual(try store.fetch(filter: .priority).map(\.id), ["a"])
        try store.reclassify(with: AlertRules(vipSenders: ["Jane"]))
        XCTAssertEqual(try store.fetch(filter: .priority).map(\.id), ["b"])
        XCTAssertEqual(try store.dbQueue.read { try InboxStore.count($0, filter: .priority, unreadOnly: true) }, 1)
    }

    func testNewPlatformsMap() {
        XCTAssertEqual(Platform.from(bundleIdentifier: "com.tinyspeck.slackmacgap"), .slack)
        XCTAssertEqual(Platform.from(bundleIdentifier: "com.apple.MobileSMS"), .messages)
        XCTAssertEqual(Platform.decodeSet(Platform.encodeSet([.slack, .teams])), [.slack, .teams])
        XCTAssertEqual(Platform.decodeSet(nil), Platform.defaultEnabled)
    }
}

final class GroupingAndExportTests: XCTestCase {
    private func item(_ id: String, _ p: Platform, _ title: String, thread: String? = nil, read: Bool = false,
                      body: String = "hi", minutesAgo: Double) -> InboxItem {
        InboxItem(id: id, platform: p, origin: .notificationCenter, sourceBundleId: p.launchBundleIdentifier,
                  title: title, body: body, threadId: thread, receivedAt: Date().addingTimeInterval(-minutesAgo * 60),
                  isRead: read)
    }

    func testGroupsByThreadThenTitle() {
        let items = [
            item("1", .whatsapp, "Jane", minutesAgo: 1),
            item("2", .teams, "Bob", thread: "chatA", minutesAgo: 2),
            item("3", .whatsapp, "jane", read: true, minutesAgo: 3),
            item("4", .teams, "Alice", thread: "chatA", minutesAgo: 4),
            item("5", .teams, "Jane", minutesAgo: 5),
        ]
        let groups = InboxGrouping.group(items)
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["1", "3"], ["2", "4"], ["5"]])
        XCTAssertEqual(groups[0].unreadCount, 1)
        XCTAssertEqual(groups[1].latest.id, "2")
    }

    func testCSVEscaping() throws {
        let csv = String(decoding: try InboxExporter.export(
            [item("1", .outlook, "Doe, Jane", body: "He said \"hi\"\nbye", minutesAgo: 0)], as: .csv), as: UTF8.self)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "received_at,app,from,subject,message,read,pinned,priority,archived")
        XCTAssertTrue(csv.contains(",Outlook,\"Doe, Jane\",,\"He said \"\"hi\"\"\nbye\",false,false,false,false"))
    }

    func testJSONAndMarkdown() throws {
        let items = [item("1", .slack, "Ops", body: "deploy done", minutesAgo: 0)]
        let decoded = try JSONDecoder.iso.decode([InboxItem].self, from: try InboxExporter.export(items, as: .json))
        XCTAssertEqual(decoded.map(\.id), ["1"])
        let md = String(decoding: try InboxExporter.export(items, as: .markdown), as: UTF8.self)
        XCTAssertTrue(md.contains("## Ops · Slack"))
        XCTAssertTrue(md.contains("> deploy done"))
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

final class DayBucketTests: XCTestCase {
    func testBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
        func d(_ day: Int, _ h: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h))! }
        XCTAssertEqual(DayBucket.bucket(for: d(5, 1), now: now, calendar: cal), .today)
        XCTAssertEqual(DayBucket.bucket(for: d(4, 23), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(DayBucket.bucket(for: d(1), now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(DayBucket.bucket(for: d(10, 0).addingTimeInterval(-86_400 * 20), now: now, calendar: cal), .earlier)
        let secs = DayBucket.sections([d(5), d(5, 2), d(1)], now: now, calendar: cal) { $0 }
        XCTAssertEqual(secs.map(\.bucket), [.today, .thisWeek])
        XCTAssertEqual(secs[0].rows.count, 2)
    }
}

final class RulesTests: XCTestCase {
    private func item(_ id: String, _ p: Platform, title: String, subtitle: String? = nil, body: String = "hi") -> InboxItem {
        InboxItem(id: id, platform: p, origin: .notificationCenter, sourceBundleId: p.launchBundleIdentifier,
                  title: title, subtitle: subtitle, body: body, receivedAt: Date())
    }

    func testRuleMatchingAndActions() {
        var set = RuleSet()
        set.rules = [
            InboxRule(name: "Martin = client", conditions: [.senderContains("martin")], actions: [.label("Nexora"), .priority]),
            InboxRule(name: "Noise", matchAll: false, conditions: [.textContains("newsletter"), .subtitleContains("promo")],
                      actions: [.archive, .markRead, .mute]),
            InboxRule(name: "Disabled", isEnabled: false, conditions: [.platformIs(.teams)], actions: [.pin]),
        ]
        let a = set.apply(to: item("1", .outlook, title: "Martin Nicholson", body: "Invoice"))
        XCTAssertEqual(a.item.labels, ["Nexora"]); XCTAssertTrue(a.item.isPriority); XCTAssertFalse(a.muted)
        XCTAssertTrue(set.shouldAlert(a))
        let b = set.apply(to: item("2", .outlook, title: "Shop", subtitle: "PROMO week"))
        XCTAssertTrue(b.item.isArchived && b.item.isRead && b.muted)
        XCTAssertFalse(set.shouldAlert(b))
        XCTAssertFalse(set.apply(to: item("3", .teams, title: "x")).item.isPinned)
        XCTAssertEqual(set.allLabels, ["Nexora"])
    }

    func testQuietHoursAcrossMidnightAndWeekdays() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        func d(_ day: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h))! }
        var q = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertTrue(q.isQuiet(.teams, at: d(2, 23), calendar: cal))
        XCTAssertTrue(q.isQuiet(.teams, at: d(3, 6), calendar: cal))
        XCTAssertFalse(q.isQuiet(.teams, at: d(3, 12), calendar: cal))
        q.platforms = [.whatsapp]
        XCTAssertFalse(q.isQuiet(.teams, at: d(2, 23), calendar: cal))
        q.platforms = []
        q.weekdays = [6] // Friday evening (Nov 6 2026 is a Friday)
        XCTAssertTrue(q.isQuiet(.teams, at: d(7, 2), calendar: cal))   // Sat 02:00 belongs to Friday night
        XCTAssertFalse(q.isQuiet(.teams, at: d(2, 23), calendar: cal)) // Monday
    }

    func testStoreLabelsNotesRulesAndAutoArchive() throws {
        let store = try InboxStore(path: nil)
        var set = RuleSet()
        set.rules = [InboxRule(name: "VIP", conditions: [.senderContains("jane")], actions: [.label("Client A")])]
        let inserted = try store.insertNew([item("1", .teams, title: "Jane"), item("2", .teams, title: "Bob")], ruleSet: set)
        XCTAssertEqual(inserted.first { $0.id == "1" }?.labels, ["Client A"])
        XCTAssertEqual(try store.fetch(filter: .label("Client A")).map(\.id), ["1"])
        try store.setLabel(["2"], "Client A", on: true)
        XCTAssertEqual(Set(try store.fetch(filter: .label("Client A")).map(\.id)), ["1", "2"])
        try store.setLabel(["2"], "Client A", on: false)
        try store.setNote("1", "  call back Friday ")
        XCTAssertEqual(try store.fetch(filter: .all).first { $0.id == "1" }?.note, "call back Friday")
        set.rules.append(InboxRule(name: "Bob", conditions: [.senderContains("bob")], actions: [.pin]))
        XCTAssertEqual(try store.apply(set), 1)
        XCTAssertEqual(try store.fetch(filter: .pinned).map(\.id), ["2"])
        try store.setRead(["1"], true)
        XCTAssertEqual(try store.autoArchiveRead(before: Date().addingTimeInterval(60)), 1)
        XCTAssertEqual(try store.fetch(filter: .archived).map(\.id), ["1"])
        XCTAssertEqual(try store.fetch(from: .distantPast, to: .distantFuture).count, 2)
    }
}
