import Foundation
import XCTest
@testable import NexusCore

final class FileToolsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("filetools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/node_modules"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ rel: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        return u
    }

    func testScanSkipsAndRanksLargest() throws {
        try write("big.bin", Data(repeating: 1, count: 300_000))
        try write("sub/mid.bin", Data(repeating: 2, count: 200_000))
        try write("small.txt", Data("hi".utf8))
        try write(".hidden", Data(repeating: 3, count: 500_000))
        try write("sub/node_modules/dep.js", Data(repeating: 4, count: 900_000))
        let files = FileScanner.files(under: root)
        let names = Set(files.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["big.bin", "mid.bin", "small.txt"]))
        XCTAssertFalse(names.contains(".hidden"))
        XCTAssertFalse(names.contains("dep.js"))
        XCTAssertEqual(FileScanner.largest(files, minSize: 100_000).map(\.name), ["big.bin", "mid.bin"])
    }

    func testCategoriesAndSuggestions() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = now.addingTimeInterval(-10 * 86_400), ancient = now.addingTimeInterval(-100 * 86_400)
        let files = [
            FileEntry(path: "/d/Setup.dmg", size: 500, modified: old),
            FileEntry(path: "/d/new.zip", size: 400, modified: now),
            FileEntry(path: "/d/photo.HEIC", size: 50, modified: ancient),
            FileEntry(path: "/d/report.pdf", size: 10, modified: old),
            FileEntry(path: "/d/Project", size: 1_000, modified: ancient, isDirectory: true),
            FileEntry(path: "/d/Tool.app", size: 2_000, modified: now, isDirectory: true),
        ]
        XCTAssertEqual(FileCategory.of(files[2]), .images)
        XCTAssertEqual(FileCategory.of(files[4]), .folders)
        XCTAssertEqual(FileCategory.of(files[5]), .installers)
        let groups = DownloadsCleanup.groups(files)
        XCTAssertEqual(groups.first?.category, .installers)
        XCTAssertEqual(groups.first?.totalSize, 2_500)
        XCTAssertEqual(DownloadsCleanup.suggestions(files, now: now).map(\.name), ["Project", "Setup.dmg", "photo.HEIC"])
    }

    func testDuplicates() throws {
        let content = Data((0..<100_000).map { UInt8($0 % 251) })
        var other = content; other[99_999] ^= 0xFF               // same size + same head, different tail
        let t = Date(timeIntervalSince1970: 1_000)
        try write("a/one.bin", content, modified: t)
        try write("b/two.bin", content, modified: t + 100)
        try write("c/three.bin", other)
        try write("d/x.txt", Data("same".utf8))
        try write("d/y.txt", Data("same".utf8))
        try write("d/z.txt", Data("diff".utf8))
        let groups = DuplicateFinder.find(FileScanner.files(under: root))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].files.map(\.name), ["one.bin", "two.bin"])   // oldest first
        XCTAssertEqual(groups[0].wasted, groups[0].size)
        XCTAssertEqual(Set(groups[1].files.map(\.name)), ["x.txt", "y.txt"])
        XCTAssertEqual(DuplicateFinder.filesToRemove(groups[0]).map(\.name), ["two.bin"])
        XCTAssertEqual(DuplicateFinder.filesToRemove(groups[0], keepNewest: true).map(\.name), ["one.bin"])
    }

    func testCancel() throws {
        for i in 0..<20 { try write("f\(i).txt", Data("x".utf8)) }
        let c = ScanControl(); c.cancel()
        XCTAssertTrue(FileScanner.files(under: root, control: c).isEmpty)
    }
}
