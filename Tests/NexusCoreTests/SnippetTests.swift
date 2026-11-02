import Foundation
import XCTest
@testable import NexusCore

final class SnippetTests: XCTestCase {
    func type(_ s: String, _ m: inout SnippetMatcher, _ snippets: [Snippet]) -> Snippet? {
        var hit: Snippet?
        for ch in s { if let h = m.type(ch, snippets: snippets) { hit = h } }
        return hit
    }

    func testMatchingAndBoundaries() {
        let snippets = [Snippet(abbreviation: ";sig", expansion: "Josh"), Snippet(abbreviation: "addr", expansion: "1 Road"),
                        Snippet(abbreviation: "off", expansion: "x", enabled: false)]
        var m = SnippetMatcher()
        XCTAssertEqual(type("hello ;sig", &m, snippets)?.expansion, "Josh")
        XCTAssertEqual(m.buffer, "")                       // reset after a match
        XCTAssertEqual(type("x;sig", &m, snippets)?.abbreviation, ";sig")   // punctuation start: fine mid-word
        XCTAssertNil(type("myaddr", &m, snippets))         // word abbreviation inside a word: no
        XCTAssertEqual(type(" addr", &m, snippets)?.expansion, "1 Road")
        XCTAssertNil(type(" off", &m, snippets))           // disabled
        // A prefix of a longer abbreviation fires first (reported by `problems`).
        var p = SnippetMatcher()
        XCTAssertEqual(type(";sig", &p, snippets + [Snippet(abbreviation: ";s", expansion: "short")])?.expansion, "short")
    }

    func testBackspaceAndCapacity() {
        let snippets = [Snippet(abbreviation: ";ok", expansion: "OK")]
        var m = SnippetMatcher(capacity: 4)
        _ = type(";ox", &m, snippets)
        m.backspace()
        XCTAssertEqual(type("k", &m, snippets)?.expansion, "OK")
        _ = type("abcdefgh", &m, snippets)
        XCTAssertEqual(m.buffer, "efgh")
    }

    func testExpansion() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 5))!
        let locale = Locale(identifier: "en_US_POSIX")
        let r = SnippetExpander.expand("Hi {cursor}, see {clipboard} on {isodate} ({weekday})", now: now, clipboard: "link",
                                       locale: locale, calendar: cal)
        XCTAssertEqual(r.text, "Hi , see link on 2026-11-02 (Monday)")
        XCTAssertEqual(r.caretFromEnd, ", see link on 2026-11-02 (Monday)".count)
        XCTAssertEqual(SnippetExpander.expand("plain").caretFromEnd, 0)
    }

    func testProblems() {
        var cfg = SnippetConfig()
        cfg.snippets = [Snippet(abbreviation: ";a", expansion: ""), Snippet(abbreviation: ";a", expansion: ""),
                        Snippet(abbreviation: "x;a", expansion: ""), Snippet(abbreviation: "q", expansion: "")]
        XCTAssertTrue(cfg.problems.contains("“;a” is used twice"))
        XCTAssertTrue(cfg.problems.contains { $0.contains("also ends") })
        XCTAssertTrue(cfg.problems.contains("“q” is too short"))
        cfg.snippets = [Snippet(abbreviation: ";s", expansion: ""), Snippet(abbreviation: ";sig", expansion: "")]
        XCTAssertEqual(cfg.problems, ["“;s” expands before “;sig” can be typed"])
        XCTAssertEqual(try JSONDecoder().decode(SnippetConfig.self, from: JSONEncoder().encode(cfg)), cfg)
    }
}
