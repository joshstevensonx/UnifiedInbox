import Foundation

/// Minimal Model Context Protocol server (JSON-RPC 2.0, one message per line on stdin/stdout) so local AI
/// assistants can search the inbox. Read-only unless started with `allowWrites`. Nothing goes over the network.
public final class InboxMCPServer {
    public static let protocolVersion = "2025-06-18"
    let store: InboxStore
    let allowWrites: Bool
    let version: String

    public init(store: InboxStore, allowWrites: Bool = false, version: String = "1.0") {
        self.store = store; self.allowWrites = allowWrites; self.version = version
    }

    /// Handles one incoming line. Returns the response line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let msg = obj as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id == nil ? nil : encode(error(id, -32600, "Invalid request"))
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        if id == nil { return nil }   // notification (e.g. notifications/initialized)
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return encode(result(id, [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "unified-inbox", "version": version],
                "instructions": "Read-only access to the user's local Unified Inbox (Teams, Outlook, WhatsApp and other notifications captured on this Mac)." + (allowWrites ? " mark_messages can change read/archive/pin state." : ""),
            ]))
        case "ping":
            return encode(result(id, [:]))
        case "tools/list":
            return encode(result(id, ["tools": tools()]))
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name, args)
                return encode(result(id, ["content": [["type": "text", "text": text]], "isError": false]))
            } catch let e as ToolError {
                if e.unknown { return encode(error(id, -32602, e.message)) }
                return encode(result(id, ["content": [["type": "text", "text": e.message]], "isError": true]))
            } catch {
                return encode(result(id, ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]))
            }
        default:
            return encode(error(id, -32601, "Method not found: \(method)"))
        }
    }

    /// Reads stdin until EOF, writing one response per request.
    public func runStdio() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let out = handle(line: line) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
    }

    // MARK: Tools

    struct ToolError: Error { var message: String; var unknown = false }

    func tools() -> [[String: Any]] {
        let platformProp: [String: Any] = ["type": "string", "description": "Optional app: " + Platform.allCases.map(\.rawValue).joined(separator: ", ")]
        var list: [[String: Any]] = [
            ["name": "search_messages",
             "description": "Full-text search of captured messages (sender, title and text). Newest first.",
             "inputSchema": ["type": "object", "properties": [
                "query": ["type": "string", "description": "Words to search for"],
                "platform": platformProp,
                "limit": ["type": "integer", "description": "Max results (default 20, max 200)"]],
                "required": ["query"]],
             "annotations": ["readOnlyHint": true]],
            ["name": "list_messages",
             "description": "Recent messages in a view: all, unread, priority (VIP/keywords), pinned, snoozed or archived.",
             "inputSchema": ["type": "object", "properties": [
                "filter": ["type": "string", "enum": ["all", "unread", "priority", "pinned", "snoozed", "archived"]],
                "platform": platformProp,
                "limit": ["type": "integer"]]],
             "annotations": ["readOnlyHint": true]],
            ["name": "get_message",
             "description": "One message by id, with labels and the user's private note.",
             "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
             "annotations": ["readOnlyHint": true]],
            ["name": "messages_in_range",
             "description": "Messages received between two dates (inclusive, YYYY-MM-DD), oldest first.",
             "inputSchema": ["type": "object", "properties": [
                "from": ["type": "string"], "to": ["type": "string"], "platform": platformProp,
                "limit": ["type": "integer"]], "required": ["from", "to"]],
             "annotations": ["readOnlyHint": true]],
            ["name": "inbox_stats",
             "description": "Unread counts per app and priority count.",
             "inputSchema": ["type": "object", "properties": [String: Any]()],
             "annotations": ["readOnlyHint": true]],
        ]
        if allowWrites {
            list.append(["name": "mark_messages",
                         "description": "Change messages: read, unread, archive, unarchive, pin or unpin.",
                         "inputSchema": ["type": "object", "properties": [
                            "ids": ["type": "array", "items": ["type": "string"]],
                            "action": ["type": "string", "enum": ["read", "unread", "archive", "unarchive", "pin", "unpin"]]],
                            "required": ["ids", "action"]],
                         "annotations": ["readOnlyHint": false, "destructiveHint": false]])
        }
        return list
    }

    func call(_ name: String, _ a: [String: Any]) throws -> String {
        func limit(_ d: Int = 20) -> Int { min(max((a["limit"] as? Int) ?? d, 1), 200) }
        func platform() throws -> Platform? {
            do { return try InboxCLI.platform(a["platform"] as? String) } catch let e as InboxCLI.CLIError { throw ToolError(message: e.message) }
        }
        switch name {
        case "search_messages":
            guard let q = a["query"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError(message: "query is required") }
            let items = try InboxCLI.query(store, filter: .all, platform: try platform(), label: nil, search: q, limit: limit())
            return try InboxCLI.json(items.map(InboxCLI.dictionary))
        case "list_messages":
            let f: InboxFilter
            do { f = try InboxCLI.filter(named: a["filter"] as? String) } catch let e as InboxCLI.CLIError { throw ToolError(message: e.message) }
            let items = try InboxCLI.query(store, filter: f, platform: try platform(), label: nil, search: nil, limit: limit())
            return try InboxCLI.json(items.map(InboxCLI.dictionary))
        case "get_message":
            guard let id = a["id"] as? String else { throw ToolError(message: "id is required") }
            guard let item = try store.item(id: id) else { throw ToolError(message: "No message with id \(id)") }
            return try InboxCLI.json(InboxCLI.dictionary(item))
        case "messages_in_range":
            guard let from = InboxCLI.parseDay(a["from"] as? String), let to = InboxCLI.parseDay(a["to"] as? String) else {
                throw ToolError(message: "from and to must be dates like 2026-10-01")
            }
            let items = try store.fetch(from: from, to: to.addingTimeInterval(86_399), platforms: try platform().map { [$0] })
            return try InboxCLI.json(items.prefix(limit(100)).map(InboxCLI.dictionary))
        case "inbox_stats":
            return try InboxCLI.json(InboxCLI.statsDictionary(store))
        case "mark_messages" where allowWrites:
            guard let ids = a["ids"] as? [String], !ids.isEmpty, let action = a["action"] as? String else {
                throw ToolError(message: "ids and action are required")
            }
            let r = InboxCLI.run(CLIArguments([action] + ids), store: store)
            if r.exitCode != 0 { throw ToolError(message: r.output) }
            return r.output
        default:
            throw ToolError(message: "Unknown tool: \(name)", unknown: true)
        }
    }

    // MARK: JSON-RPC helpers

    func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }

    func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    func encode(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
    }
}
