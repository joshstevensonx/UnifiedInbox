import Foundation
import XCTest
@testable import NexusCore

final class BackupTests: XCTestCase {
    func testPackUnpackRoundTrip() throws {
        let files = ["inbox.sqlite": Data([1, 2, 3]), "Notes/Today.md": Data("# hi".utf8), "empty.json": Data()]
        let packed = try BackupArchive.pack(files, created: Date(timeIntervalSince1970: 0), appVersion: "1.0")
        let (manifest, out) = try BackupArchive.unpack(packed)
        XCTAssertEqual(out, files)
        XCTAssertEqual(manifest.entries.map(\.path), ["Notes/Today.md", "empty.json", "inbox.sqlite"])
        XCTAssertEqual(manifest.appVersion, "1.0")
    }

    func testRejectsBadInput() throws {
        XCTAssertThrowsError(try BackupArchive.pack(["../evil": Data()])) { XCTAssertEqual($0 as? BackupError, .unsafePath("../evil")) }
        XCTAssertThrowsError(try BackupArchive.pack(["/etc/passwd": Data()]))
        XCTAssertFalse(BackupArchive.isSafe("a//b"))
        XCTAssertFalse(BackupArchive.isSafe("a/./b"))
        XCTAssertTrue(BackupArchive.isSafe("Notes/a b.md"))
        XCTAssertThrowsError(try BackupArchive.unpack(Data("nope".utf8))) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        var packed = try BackupArchive.pack(["a": Data([1, 2, 3])])
        packed.removeLast()
        XCTAssertThrowsError(try BackupArchive.unpack(packed)) { XCTAssertEqual($0 as? BackupError, .corrupt) }
        packed.append(contentsOf: [3, 9])
        XCTAssertThrowsError(try BackupArchive.unpack(packed)) { XCTAssertEqual($0 as? BackupError, .corrupt) }
    }

    func testCollectWriteAndStagedRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("UnifiedInbox")
        try BackupArchive.write(["a.json": Data("A".utf8), "Notes/n.md": Data("N".utf8), "skip.tmp": Data()], to: base)
        let collected = BackupArchive.collect(from: base, excluding: ["skip.tmp"])
        XCTAssertEqual(Set(collected.keys), ["a.json", "Notes/n.md"])

        XCTAssertFalse(StagedRestore.hasPending(for: base))
        XCTAssertFalse(try StagedRestore.applyPending(for: base))
        try StagedRestore.stage(["a.json": Data("RESTORED".utf8)], for: base)
        XCTAssertTrue(StagedRestore.hasPending(for: base))
        XCTAssertTrue(try StagedRestore.applyPending(for: base))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("a.json"), encoding: .utf8), "RESTORED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Notes/n.md").path))
        let before = root.appendingPathComponent("UnifiedInbox.before-restore/Notes/n.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.path))   // previous data kept aside
        XCTAssertFalse(StagedRestore.hasPending(for: base))
    }

    func testEncryptedHeaderParsing() throws {
        let salt = Data(repeating: 7, count: 16)
        var file = BackupCrypto.header(salt: salt, iterations: 1_000)
        file.append(Data(repeating: 0, count: 40))
        let h = try BackupCrypto.parseHeader(file)
        XCTAssertEqual(h.salt, salt)
        XCTAssertEqual(h.iterations, 1_000)
        XCTAssertEqual(h.box.count, 40)
        XCTAssertThrowsError(try BackupCrypto.parseHeader(Data("UIBE1".utf8)))
    }

    #if canImport(CryptoKit) && canImport(CommonCrypto)
    func testEncryptDecrypt() throws {
        let plain = Data("secret inbox".utf8)
        let sealed = try BackupCrypto.encrypt(plain, password: "correct horse", iterations: 1_000)
        XCTAssertEqual(try BackupCrypto.decrypt(sealed, password: "correct horse"), plain)
        XCTAssertThrowsError(try BackupCrypto.decrypt(sealed, password: "wrong")) { XCTAssertEqual($0 as? BackupError, .wrongPassword) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try BackupCrypto.decrypt(tampered, password: "correct horse"))
    }
    #endif

    func testLockPolicy() {
        var p = LockPolicy()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(p.shouldLock(on: .launch, now: now))   // disabled
        p.enabled = true
        p.lockAfterMinutes = 5
        XCTAssertTrue(p.shouldLock(on: .launch, now: now))
        XCTAssertFalse(p.shouldLock(on: .appActivated(lastActive: now - 120), now: now))
        XCTAssertTrue(p.shouldLock(on: .appActivated(lastActive: now - 300), now: now))
        p.lockOnSleep = false
        XCTAssertFalse(p.shouldLock(on: .systemSleep, now: now))
        XCTAssertTrue(p.shouldLock(on: .screenLocked, now: now))
    }
}
