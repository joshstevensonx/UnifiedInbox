import Foundation

// MARK: - `inboxctl` (task 23): command-line access to the local inbox database.
// The executable (Sources/inboxctl) only opens the store and prints; all logic lives here so it's tested.

public struct CLIArguments: Equatable, Sendable {
    public var command: String
    public var positional: [String]
    public var options: [String: String]
    public var flags: Set<String>

    /// `--key value`, `--key=value`, and bare `--flag` (when the next word is another option or missing).
    public static let valueOptions: Set<String> = ["limit", "platform", "filter", "format", "from", "to", "label", "db"]

    public init(_ argv: [String]) {
        var words = argv[...]
        command = words.first ?? "help"
        if !words.isEmpty { words = words.dropFirst() }
        positional = []; options = [:]; flags = []
        while let w = words.first {
            words = words.dropFirst()
            if w.hasPrefix("--") {
                let body = String(w.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.valueOptions.contains(body), let next = words.first {
                    options[body] = next; words = words.dropFirst()
                } else {
                    flags.insert(body)
                }
            } else if w == "-n", let next = words.first {
                options["limit"] = next; words = words.dropFirst()
            } else {
                positional.append(w)
            }
        }
    }
}

public enum InboxCLI {
    public static let usage = """
    inboxctl: read your Unified Inbox from the terminal (local database, read-only unless noted).

    USAGE
      inboxctl list   [--filter all|unread|priority|pinned|snoozed|archived] [--platform teams] [--label X] [-n 20] [--json]
      inboxctl search <words…> [--platform slack] [-n 20] [--json]
      inboxctl show   <id> [--json]
      inboxctl stats  [--json]
      inboxctl export --format csv|json|markdown [--from 2026-10-01] [--to 2026-10-31] [--platform outlook]
      inboxctl read | unread | archive | unarchive | pin | unpin <id…>     (changes the database)
      inboxctl mcp [--allow-writes]     Model Context Protocol server on stdin/stdout for AI assistants
      inboxctl help

    Platforms: \(Platform.allCases.map(\.rawValue).joined(separator: ", "))
    Database: --db <path> (default ~/Library/Application Support/UnifiedInbox/inbox.sqlite)
    """

    public struct Result: Equatable {
        public var output: String
        public var exitCode: Int32
        public init(_ output: String, _ exitCode: Int32 = 0) { self.output = output; self.exitCode = exitCode }
    }

    public static func run(_ args: CLIArguments, store: InboxStore) -> Result {
        do {
            switch args.command {
            case "help", "-h", "--help": return Result(usage)
            case "list", "ls": return try list(args, store)
            case "search", "find": return try search(args, store)
            case "show", "get": return try show(args, store)
            case "stats": return try stats(args, store)
            case "export": return try export(args, store)
            case "read", "unread", "archive", "unarchive", "pin", "unpin": return try change(args, store)
            default: return Result("Unknown command “\(args.command)”.\n\n" + usage, 64)
            }
        } catch let e as CLIError {
            return Result(e.message, 64)
        } catch {
            return Result("Error: \(error.localizedDescription)", 1)
        }
    }

    struct CLIError: Error { var message: String }

    static func platform(_ s: String?) throws -> Platform? {
        guard let s, !s.isEmpty else { return nil }
        if let p = Platform(rawValue: s.lowercased()) { return p }
        if let p = Platform.allCases.first(where: { $0.displayName.lowercased() == s.lowercased() }) { return p }
        throw CLIError(message: "Unknown platform “\(s)”. Use one of: \(Platform.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    public static func filter(named name: String?) throws -> InboxFilter {
        switch (name ?? "all").lowercased() {
        case "all", "inbox": return .all
        case "unread": return .unread
        case "priority", "vip": return .priority
        case "pinned": return .pinned
        case "snoozed": return .snoozed
        case "archived", "archive": return .archived
        default: throw CLIError(message: "Unknown filter “\(name ?? "")”. Use all, unread, priority, pinned, snoozed or archived.")
        }
    }

    static func limit(_ args: CLIArguments, default d: Int = 20) throws -> Int {
        guard let s = args.options["limit"] else { return d }
        guard let n = Int(s), n > 0 else { throw CLIError(message: "--limit needs a positive number") }
        return min(n, 10_000)
    }

    /// Fetch for list/search with optional platform / label / filter combined.
    static func query(_ store: InboxStore, filter: InboxFilter, platform: Platform?, label: String?, search: String?, limit: Int) throws -> [InboxItem] {
        if let platform {
            let items = try store.fetch(filter: .platform(platform), search: search, limit: max(limit * 5, 200))
            return Array(items.filter { item in matches(item, filter) && (label.map { item.labels.contains($0) } ?? true) }.prefix(limit))
        }
        if let label {
            let items = try store.fetch(filter: .label(label), search: search, limit: max(limit * 5, 200))
            return Array(items.filter { matches($0, filter) }.prefix(limit))
        }
        return try store.fetch(filter: filter, search: search, limit: limit)
    }

    static func matches(_ i: InboxItem, _ f: InboxFilter) -> Bool {
        switch f {
        case .unread: return !i.isRead && !i.isArchived
        case .priority: return i.isPriority && !i.isArchived
        case .pinned: return i.isPinned
        case .snoozed: return i.snoozedUntil != nil
        case .archived: return i.isArchived
        default: return !i.isArchived
        }
    }

    static func list(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        let items = try query(store, filter: try filter(named: a.options["filter"]), platform: try platform(a.options["platform"]),
                              label: a.options["label"], search: nil, limit: try limit(a))
        return Result(a.flags.contains("json") ? try json(items.map(dictionary)) : table(items))
    }

    static func search(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        let q = a.positional.joined(separator: " ")
        guard !q.isEmpty else { throw CLIError(message: "search needs words to look for, e.g. inboxctl search invoice") }
        let items = try query(store, filter: .all, platform: try platform(a.options["platform"]), label: a.options["label"],
                              search: q, limit: try limit(a))
        return Result(a.flags.contains("json") ? try json(items.map(dictionary)) : table(items))
    }

    static func show(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        guard let id = a.positional.first else { throw CLIError(message: "show needs a message id (see inboxctl list)") }
        guard let item = try store.item(id: id) else { return Result("No message with id \(id)", 1) }
        if a.flags.contains("json") { return Result(try json(dictionary(item))) }
        var s = "\(item.title)\(item.subtitle.map { " · \($0)" } ?? "")\n"
        s += "\(item.platform.displayName) · \(iso(item.receivedAt))\(item.isRead ? "" : " · unread")\(item.isPriority ? " · ★" : "")\(item.isPinned ? " · pinned" : "")\n"
        if !item.labels.isEmpty { s += "Labels: \(item.labels.joined(separator: ", "))\n" }
        s += "\n\(item.body)\n"
        if let n = item.note, !n.isEmpty { s += "\nNote: \(n)\n" }
        return Result(s)
    }

    public static func statsDictionary(_ store: InboxStore) throws -> [String: Any] {
        let counts = try store.unreadCounts()
        let (priority, total) = try store.dbQueue.read { db in
            (try InboxStore.count(db, filter: .priority, unreadOnly: true), try InboxStore.count(db, filter: .all, unreadOnly: false))
        }
        return [
            "unread": counts.values.reduce(0, +),
            "priorityUnread": priority,
            "inInbox": total,
            "unreadByPlatform": Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
        ]
    }

    static func stats(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        let d = try statsDictionary(store)
        if a.flags.contains("json") { return Result(try json(d)) }
        var s = "Unread: \(d["unread"] ?? 0)   Priority: \(d["priorityUnread"] ?? 0)   In inbox: \(d["inInbox"] ?? 0)\n"
        let per = (d["unreadByPlatform"] as? [String: Int] ?? [:]).sorted { $0.value > $1.value }
        for (p, n) in per { s += "  \(p.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n)\n" }
        return Result(s)
    }

    public static func parseDay(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func export(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        let fmt = try InboxExporter.Format(rawValue: (a.options["format"] ?? "csv").lowercased())
            .orThrow(CLIError(message: "--format must be csv, json or markdown"))
        let from = try parseDay(a.options["from"] ?? "1970-01-01").orThrow(CLIError(message: "--from must look like 2026-10-01"))
        let toDay = try parseDay(a.options["to"] ?? "2999-12-31").orThrow(CLIError(message: "--to must look like 2026-10-31"))
        let to = toDay.addingTimeInterval(86_399)
        let items = try store.fetch(from: from, to: to, platforms: try platform(a.options["platform"]).map { [$0] })
        return Result(String(decoding: try InboxExporter.export(items, as: fmt), as: UTF8.self))
    }

    static func change(_ a: CLIArguments, _ store: InboxStore) throws -> Result {
        let ids = a.positional
        guard !ids.isEmpty else { throw CLIError(message: "\(a.command) needs one or more message ids") }
        switch a.command {
        case "read": try store.setRead(ids, true)
        case "unread": try store.setRead(ids, false)
        case "archive": try store.setArchived(ids, true)
        case "unarchive": try store.setArchived(ids, false)
        case "pin": try store.setPinned(ids, true)
        default: try store.setPinned(ids, false)
        }
        return Result("\(a.command): \(ids.count) message\(ids.count == 1 ? "" : "s")")
    }

    // MARK: Formatting

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    public static func dictionary(_ i: InboxItem) -> [String: Any] {
        var d: [String: Any] = [
            "id": i.id, "platform": i.platform.rawValue, "sender": i.title, "body": i.body,
            "receivedAt": iso(i.receivedAt), "isRead": i.isRead, "isPinned": i.isPinned, "isArchived": i.isArchived,
            "isPriority": i.isPriority, "labels": i.labels,
        ]
        if let s = i.subtitle { d["subtitle"] = s }
        if let t = i.threadId { d["threadId"] = t }
        if let n = i.note { d["note"] = n }
        if let s = i.snoozedUntil { d["snoozedUntil"] = iso(s) }
        return d
    }

    public static func json(_ obj: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    static func table(_ items: [InboxItem]) -> String {
        guard !items.isEmpty else { return "No messages." }
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return items.map { i in
            let flag = (i.isRead ? " " : "•") + (i.isPriority ? "★" : " ")
            let who = String(i.title.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
            let text = i.body.replacingOccurrences(of: "\n", with: " ").prefix(60)
            return "\(flag) \(f.string(from: i.receivedAt))  \(i.platform.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(who) \(text)  [\(i.id)]"
        }.joined(separator: "\n")
    }
}

extension Optional {
    func orThrow(_ e: @autoclosure () -> Error) throws -> Wrapped {
        guard let v = self else { throw e() }
        return v
    }
}
