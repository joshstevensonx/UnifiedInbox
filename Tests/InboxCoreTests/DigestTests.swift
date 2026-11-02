import Foundation
import XCTest
@testable import InboxCore

final class DigestTests: XCTestCase {
    func testDigest() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        func item(_ id: String, _ p: Platform, _ who: String, hour: Int, read: Bool = false, prio: Bool = false, dayOffset: Int = 0) -> InboxItem {
            var i = InboxItem(id: id, platform: p, origin: .notificationCenter, sourceBundleId: "x", title: who, body: "msg \(id)\nline2",
                              receivedAt: cal.date(from: DateComponents(year: 2026, month: 11, day: 2 + dayOffset, hour: hour))!)
            i.isRead = read; i.isPriority = prio
            return i
        }
        let items = [
            item("1", .teams, "Jane", hour: 9, read: true),
            item("2", .teams, "Jane", hour: 9),
            item("3", .teams, "Jane", hour: 10, prio: true),
            item("4", .whatsapp, "Mom", hour: 8, read: true),
            item("5", .slack, "Bob", hour: 11),
            item("6", .slack, "Old", hour: 11, dayOffset: -1),
        ]
        let d = DailyDigest.make(items, day: day, calendar: cal)
        XCTAssertEqual(d.total, 5)
        XCTAssertEqual(d.unread, 3)
        XCTAssertEqual(d.byPlatform.map(\.platform), [.teams, .slack, .whatsapp])
        XCTAssertEqual(d.priority.map(\.id), ["3"])
        XCTAssertEqual(d.topSenders.first?.name, "Jane")
        XCTAssertEqual(d.topSenders.first?.count, 3)
        XCTAssertEqual(d.awaiting.map(\.name), ["Jane", "Bob"])      // Mom's last message is read
        XCTAssertEqual(d.busiestHour, 9)
        XCTAssertEqual(d.headline, "5 messages, 3 unread, 1 priority. Waiting on you: Jane, Bob.")
        let md = d.markdown(calendar: cal)
        XCTAssertTrue(md.contains("- [ ] Jane (Microsoft Teams): msg 3 line2"))
        XCTAssertFalse(d.markdown(hideText: true, calendar: cal).contains("msg 3"))
        XCTAssertEqual(DailyDigest.make([], day: day, calendar: cal).headline, "No messages today.")
        XCTAssertTrue(d.modelPrompt(items: items).contains("[Slack] Bob: msg 5 line2"))
    }
}
