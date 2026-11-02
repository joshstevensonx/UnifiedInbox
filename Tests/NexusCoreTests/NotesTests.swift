import Foundation
import XCTest
@testable import NexusCore

final class NotesTests: XCTestCase {
    func testLinksAndTags() {
        let body = "See [[Project X]] and [[project x|again]], [[Alice]]. Not [[ ]] or [[broken\nlink]].\n#work #Ideas/2026 #123 ## Heading\n```\n#notatag\n```"
        XCTAssertEqual(NoteLinks.links(in: body), ["Project X", "Alice"])
        XCTAssertEqual(NoteLinks.tags(in: body), ["work", "ideas/2026"])
    }

    func testBacklinksMentionsAndMissing() {
        let t = Date(timeIntervalSince1970: 0)
        let notes = [
            Note(title: "Alice", body: "Met about [[Project X]]", modified: t),
            Note(title: "Bob", body: "Project X is late", modified: t + 10),
            Note(title: "Log", body: "[[project x|PX]] and [[Nowhere]]", modified: t + 20),
            Note(title: "Project X", body: "Self link [[Project X]]", modified: t),
        ]
        XCTAssertEqual(NoteLinks.backlinks(to: "Project X", in: notes).map(\.title), ["Log", "Alice"])
        XCTAssertEqual(NoteLinks.unlinkedMentions(of: "Project X", in: notes).map(\.title), ["Bob"])
        XCTAssertEqual(NoteLinks.missingTargets(in: notes), ["Nowhere"])
    }

    func testRenameLinks() {
        let s = "a [[Old]] b [[old|alias]] c [[Older]] [[unclosed"
        XCTAssertEqual(NoteLinks.renameLinks(in: s, from: "Old", to: "New"), "a [[New]] b [[New|alias]] c [[Older]] [[unclosed")
    }

    func testDailyNotes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertEqual(DailyNotes.title(for: d, calendar: cal), "2026-11-02")
        XCTAssertEqual(DailyNotes.date(fromTitle: "2026-11-02", calendar: cal), d)
        XCTAssertNil(DailyNotes.date(fromTitle: "2026-13-40", calendar: cal))
        XCTAssertNil(DailyNotes.date(fromTitle: "Meeting notes", calendar: cal))
        XCTAssertTrue(DailyNotes.template(for: d, calendar: cal).contains("[[2026-11-01]]"))
    }

    func testMarkdownBlocks() {
        let md = "# Title\nsome text\ncontinued\n\n- item\n  - nested\n- [ ] todo\n- [x] done\n1. first\n> quote\n---\n```\ncode #x\n```"
        let b = MarkdownParser.blocks(md)
        XCTAssertEqual(b, [
            .heading(level: 1, text: "Title"),
            .paragraph("some text continued"),
            .bullet(indent: 0, text: "item"),
            .bullet(indent: 1, text: "nested"),
            .task(checked: false, text: "todo", line: 6),
            .task(checked: true, text: "done", line: 7),
            .numbered(number: 1, text: "first"),
            .quote("quote"),
            .rule,
            .code("code #x"),
        ])
        XCTAssertEqual(MarkdownParser.toggleTask(in: md, line: 6).components(separatedBy: "\n")[6], "- [x] todo")
        XCTAssertEqual(MarkdownParser.toggleTask(in: md, line: 7).components(separatedBy: "\n")[7], "- [ ] done")
        XCTAssertEqual(MarkdownParser.linkify("go [[My Note|here]] or [[B]]"), "go [here](note:My%20Note) or [B](note:B)")
    }

    func testFolderStoreRenameAndSearch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteFolder(folder: dir)
        try store.save(Note(title: "Plan", body: "# Plan\nwork on [[Draft]] #todo"))
        try store.save(Note(title: "Draft", body: "first draft"))
        XCTAssertEqual(Set(store.loadAll().map(\.title)), ["Plan", "Draft"])
        let changed = try store.rename("Draft", to: "Final", notes: store.loadAll())
        XCTAssertEqual(changed.map(\.title), ["Plan"])
        let all = store.loadAll()
        XCTAssertEqual(Set(all.map(\.title)), ["Plan", "Final"])
        XCTAssertTrue(all.first { $0.title == "Plan" }!.body.contains("[[Final]]"))
        XCTAssertEqual(NoteSearch.search("fin", in: all).map(\.title), ["Final", "Plan"])  // title hit before body hit
        XCTAssertEqual(NoteSearch.search("draft", in: all).map(\.title), ["Final"])  // body hit
        XCTAssertEqual(NoteSearch.search("#todo", in: all).map(\.title), ["Plan"])
        XCTAssertEqual(NoteFolder.fileName(for: "a/b: c"), "a-b- c.md")
        XCTAssertEqual(NoteFolder.fileName(for: ".hidden"), "_hidden.md")
    }
}
