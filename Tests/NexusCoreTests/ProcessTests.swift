import Foundation
import XCTest
@testable import NexusCore

final class ProcessTests: XCTestCase {
    func testCPURateAndPidReuse() {
        var t = ProcessTable()
        let t0 = Date(timeIntervalSince1970: 1_000), s0 = Date(timeIntervalSince1970: 1)
        _ = t.update([ProcessSample(pid: 10, ppid: 1, name: "a", cpuNanos: 1_000_000_000, started: s0)], at: t0)
        let r = t.update([ProcessSample(pid: 10, ppid: 1, name: "a", cpuNanos: 2_000_000_000, started: s0)], at: t0 + 2)
        XCTAssertEqual(r[0].cpu ?? -1, 0.5, accuracy: 1e-9)
        // Same pid, new process (different start): no bogus rate.
        let reused = t.update([ProcessSample(pid: 10, ppid: 1, name: "b", cpuNanos: 9_000_000_000, started: s0 + 5)], at: t0 + 4)
        XCTAssertNil(reused[0].cpu)
        // Unreadable process (no cpu time): stays nil.
        XCTAssertNil(t.update([ProcessSample(pid: 11, ppid: 1, name: "root")], at: t0 + 6)[0].cpu)
    }

    func testSortFilterTreeTotals() {
        let list = [
            ProcessSample(pid: 1, ppid: 0, name: "launchd", uid: 0, memory: 10, cpu: 0.01),
            ProcessSample(pid: 50, ppid: 1, name: "Safari", path: "/Applications/Safari.app", uid: 501, memory: 500, cpu: 0.2),
            ProcessSample(pid: 51, ppid: 50, name: "WebContent", uid: 501, memory: 800, cpu: 0.5),
            ProcessSample(pid: 52, ppid: 51, name: "Helper", uid: 501, memory: 100, cpu: nil),
            ProcessSample(pid: 99, ppid: 7777, name: "orphan", uid: 501, memory: 1, cpu: 0),
        ]
        XCTAssertEqual(ProcessTable.sorted(list, by: .cpu).map(\.pid), [51, 50, 1, 99, 52])
        XCTAssertEqual(ProcessTable.sorted(list, by: .memory).first?.pid, 51)
        XCTAssertEqual(ProcessTable.filter(list, query: "safari", mineOnly: false, uid: 501).map(\.pid), [50])
        XCTAssertEqual(ProcessTable.filter(list, query: "51", mineOnly: false, uid: 501).map(\.pid), [51])
        XCTAssertEqual(ProcessTable.filter(list, query: "", mineOnly: true, uid: 501).count, 4)
        let tree = ProcessTable.tree(list, sort: .pid)
        XCTAssertEqual(tree.map(\.process.pid), [1, 50, 51, 52, 99])
        XCTAssertEqual(tree.map(\.depth), [0, 1, 2, 3, 0])
        let g = ProcessTable.groupTotals(list, root: 50)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.memory, 1_400)
        XCTAssertEqual(g.cpu, 0.7, accuracy: 1e-9)
    }

    func testLogParsing() {
        let text = """
        Filtering the log data using "process == x"
        {"timestamp":"2026-11-02 20:00:00.123456+0000","messageType":"Error","processImagePath":"/usr/libexec/foo","processID":42,"subsystem":"com.x","category":"net","eventMessage":"boom"}
        {"timestamp":"bad","messageType":"Default","processImagePath":"","eventMessage":"hi"}
        not json
        """
        let e = LogParser.parse(ndjson: text)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[0].level, .error)
        XCTAssertEqual(e[0].process, "foo")
        XCTAssertEqual(e[0].pid, 42)
        XCTAssertEqual(e[0].message, "boom")
        XCTAssertEqual(e[0].date?.timeIntervalSince1970 ?? 0, 1_793_649_600.123, accuracy: 0.001)
        XCTAssertNil(e[1].date)
        XCTAssertEqual(e[1].level, .default)
        XCTAssertTrue(LogLevel.fault > LogLevel.error)
    }

    func testLogArgumentsEscapeInput() {
        let args = LogParser.showArguments(lastMinutes: 5, minLevel: .error, process: "Saf\"ari", subsystem: "", text: "a\\b")
        XCTAssertEqual(Array(args.prefix(5)), ["show", "--style", "ndjson", "--last", "5m"])
        XCTAssertFalse(args.contains("--info"))
        let pred = args.last!
        XCTAssertTrue(pred.contains(#"process CONTAINS[c] "Saf\"ari""#))
        XCTAssertTrue(pred.contains(#"eventMessage CONTAINS[c] "a\\b""#))
        XCTAssertTrue(pred.contains("messageType == error OR messageType == fault"))
        let debug = LogParser.showArguments(lastMinutes: 0, minLevel: .debug, process: "", subsystem: "", text: "")
        XCTAssertEqual(debug, ["show", "--style", "ndjson", "--last", "1m", "--info", "--debug"])
    }
}
