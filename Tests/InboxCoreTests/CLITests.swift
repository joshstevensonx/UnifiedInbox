import Foundation
import XCTest
@testable import InboxCore

final class CLITests: XCTestCase {
    var store: InboxStore!

    override func setUpWithError() throws {
        store = try InboxStore(path: nil)
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        func item(_ id: String, _ p: Platform, _ who: String, _ body: String, _ ago: Double) -> InboxItem {
            InboxItem(id: id, platform: p, origin: .notificationCenter, sourceBundleId: "x", title: who, body: body,
                      receivedAt: base.addingTimeInterval(-ago))
        }
        _ = try store.insertNew([
            item("1", .teams, "Jane", "Invoice for October", 60),
            item("2", .whatsapp, "Mom", "Call me", 120),
            item("3", .teams, "Bob", "Standup moved", 180),
        ], rules: AlertRules(vipText: "Mom", keywordText: ""))
    }

    func testArgumentParsing() {
        let a = CLIArguments(["list", "--filter", "unread", "--json", "-n", "5", "--platform=teams", "extra"])
        XCTAssertEqual(a.command, "list")
        XCTAssertEqual(a.options, ["filter": "unread", "limit": "5", "platform": "teams"])
        XCTAssertEqual(a.flags, ["json"])
        XCTAssertEqual(a.positional, ["extra"])
        XCTAssertEqual(CLIArguments([]).command, "help")
        XCTAssertEqual(CLIArguments(["mcp", "--allow-writes"]).flags, ["allow-writes"])
    }

    func testCommands() throws {
        let list = InboxCLI.run(CLIArguments(["list", "--platform", "teams", "--json"]), store: store)
        XCTAssertEqual(list.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(list.output.utf8)) as! [[String: Any]]
        XCTAssertEqual(arr.map { $0["id"] as! String }, ["1", "3"])

        XCTAssertTrue(InboxCLI.run(CLIArguments(["search", "invoice"]), store: store).output.contains("[1]"))
        XCTAssertEqual(InboxCLI.run(CLIArguments(["list", "--filter", "priority"]), store: store).output.contains("Mom"), true)
        XCTAssertEqual(InboxCLI.run(CLIArguments(["read", "1", "2"]), store: store).output, "read: 2 messages")
        XCTAssertTrue(InboxCLI.run(CLIArguments(["stats"]), store: store).output.contains("Unread: 1"))
        XCTAssertTrue(InboxCLI.run(CLIArguments(["show", "3"]), store: store).output.contains("Standup moved"))
        XCTAssertEqual(InboxCLI.run(CLIArguments(["show", "nope"]), store: store).exitCode, 1)
        XCTAssertEqual(InboxCLI.run(CLIArguments(["list", "--platform", "myspace"]), store: store).exitCode, 64)
        XCTAssertEqual(InboxCLI.run(CLIArguments(["frobnicate"]), store: store).exitCode, 64)
        let csv = InboxCLI.run(CLIArguments(["export", "--format", "csv", "--from", "2026-01-01"]), store: store)
        XCTAssertEqual(csv.exitCode, 0)
        XCTAssertTrue(csv.output.contains("Invoice"))
    }

    private func call(_ server: InboxMCPServer, _ obj: [String: Any]) throws -> [String: Any]? {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        return server.handle(line: line).map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testMCPProtocol() throws {
        let server = InboxMCPServer(store: store)
        let initResp = try call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]])
        let r = initResp?["result"] as? [String: Any]
        XCTAssertEqual(r?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((r?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNil(try call(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]))

        let tools = (try call(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.map { $0["name"] as! String }.contains("mark_messages"), false)   // read-only by default
        XCTAssertEqual(tools?.count, 5)

        let search = try call(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                       "params": ["name": "search_messages", "arguments": ["query": "standup"]]])
        let content = ((search?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertTrue(content?.contains("Standup moved") ?? false)

        let bad = try call(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "get_message", "arguments": [:]]])
        XCTAssertEqual((bad?["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try call(server, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "mark_messages", "arguments": [:]]])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32602)
        let nomethod = try call(server, ["jsonrpc": "2.0", "id": 6, "method": "resources/list"])
        XCTAssertEqual((nomethod?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertTrue(server.handle(line: "{not json")!.contains("-32700"))
    }

    func testMCPWritesWhenAllowed() throws {
        let server = InboxMCPServer(store: store, allowWrites: true)
        let resp = try call(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                     "params": ["name": "mark_messages", "arguments": ["ids": ["2"], "action": "archive"]]])
        XCTAssertEqual((resp?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(try store.item(id: "2")?.isArchived, true)
    }
}
