import Foundation
import XCTest
@testable import InboxCore

final class BackupStoreTests: XCTestCase {
    func testOnlineBackupCopiesItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbbackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try InboxStore(path: dir.appendingPathComponent("inbox.sqlite").path)
        try store.insertNew([InboxItem(id: "1", platform: .teams, origin: .notificationCenter,
                                       sourceBundleId: "com.microsoft.teams2", title: "Jane", body: "Hi", receivedAt: Date())])
        let copy = dir.appendingPathComponent("copy.sqlite").path
        try store.backup(toPath: copy)
        let reopened = try InboxStore(path: copy)
        XCTAssertEqual(try reopened.fetch(filter: .all).map(\.id), ["1"])
    }
}
