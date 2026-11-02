import Foundation
import GRDB

/// Local SQLite store for the unified inbox. All data stays on this Mac.
///
/// - `inbox_item`: one row per captured notification/message (user state lives here too).
/// - `inbox_fts`: FTS5 index over title/subtitle/body, kept in sync with triggers.
/// - `kv`: small key/value table for capture cursors and settings.
public final class InboxStore: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    /// Opens (or creates) the store at `path`. Pass `nil` for an in-memory store (tests/previews).
    public init(path: String?) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // The app and `inboxctl` can use the database at the same time: wait for a lock instead of failing.
        config.busyMode = .timeout(5)
        if let path {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbQueue = try DatabaseQueue(configuration: config)
        }
        try Self.migrator.migrate(dbQueue)
    }

    /// Consistent copy of the whole database into a new file at `path` (SQLite online backup API),
    /// safe while capture keeps writing. Used by encrypted backups.
    public func backup(toPath path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let destination = try DatabaseQueue(path: path)
        try dbQueue.backup(to: destination)
        try destination.close()
    }

    /// Default location: ~/Library/Application Support/UnifiedInbox/inbox.sqlite
    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UnifiedInbox/inbox.sqlite").path
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "inbox_item") { t in
                t.column("id", .text).primaryKey()
                t.column("platform", .text).notNull().indexed()
                t.column("origin", .text).notNull()
                t.column("sourceBundleId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("body", .text).notNull()
                t.column("threadId", .text).indexed()
                t.column("receivedAt", .datetime).notNull().indexed()
                t.column("capturedAt", .datetime).notNull()
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE inbox_fts USING fts5(
                    title, subtitle, body,
                    content='inbox_item', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER inbox_item_ai AFTER INSERT ON inbox_item BEGIN
                    INSERT INTO inbox_fts(rowid, title, subtitle, body)
                    VALUES (new.rowid, new.title, new.subtitle, new.body);
                END;
                CREATE TRIGGER inbox_item_ad AFTER DELETE ON inbox_item BEGIN
                    INSERT INTO inbox_fts(inbox_fts, rowid, title, subtitle, body)
                    VALUES ('delete', old.rowid, old.title, old.subtitle, old.body);
                END;
                CREATE TRIGGER inbox_item_au AFTER UPDATE OF title, subtitle, body ON inbox_item BEGIN
                    INSERT INTO inbox_fts(inbox_fts, rowid, title, subtitle, body)
                    VALUES ('delete', old.rowid, old.title, old.subtitle, old.body);
                    INSERT INTO inbox_fts(rowid, title, subtitle, body)
                    VALUES (new.rowid, new.title, new.subtitle, new.body);
                END;
                """)
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2-priority-snooze") { db in
            try db.alter(table: "inbox_item") { t in
                t.add(column: "isPriority", .boolean).notNull().defaults(to: false)
                t.add(column: "snoozedUntil", .datetime)
            }
            try db.create(index: "inbox_item_snoozedUntil", on: "inbox_item", columns: ["snoozedUntil"])
        }
        m.registerMigration("v3-labels-notes") { db in
            try db.alter(table: "inbox_item") { t in
                t.add(column: "labels", .text).notNull().defaults(to: "[]")
                t.add(column: "note", .text)
            }
        }
        return m
    }

    // MARK: - Writes

    /// Inserts new items; existing ids are left untouched so user state (read/pinned/archived) survives.
    /// Items matching `rules` are flagged `isPriority`. Returns the items that were actually new.
    @discardableResult
    public func insertNew(_ items: [InboxItem], rules: AlertRules = AlertRules(), ruleSet: RuleSet? = nil) throws -> [InboxItem] {
        guard !items.isEmpty else { return [] }
        return try dbQueue.write { db in
            var inserted: [InboxItem] = []
            for var item in items {
                if !rules.isEmpty, rules.match(item) != nil { item.isPriority = true }
                if let ruleSet { item = ruleSet.apply(to: item).item }
                try item.insert(db, onConflict: .ignore)
                if db.changesCount > 0 { inserted.append(item) }
            }
            return inserted
        }
    }

    public func setRead(_ ids: [String], _ value: Bool) throws {
        try update(ids, column: "isRead", value)
    }

    public func setPinned(_ ids: [String], _ value: Bool) throws {
        try update(ids, column: "isPinned", value)
    }

    public func setArchived(_ ids: [String], _ value: Bool) throws {
        try update(ids, column: "isArchived", value)
    }

    /// Hides items until `date`; they come back unread when `wakeSnoozed` runs after that time.
    public func snooze(_ ids: [String], until date: Date) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            var args: [DatabaseValueConvertible] = [date]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE inbox_item SET snoozedUntil = ?, isRead = 0 WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(args)
            )
        }
    }

    public func unsnooze(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE inbox_item SET snoozedUntil = NULL WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Returns items whose snooze has expired to the inbox as unread. Returns the woken items.
    @discardableResult
    public func wakeSnoozed(now: Date = Date()) throws -> [InboxItem] {
        try dbQueue.write { db in
            let due = try InboxItem.fetchAll(
                db, sql: "SELECT * FROM inbox_item WHERE snoozedUntil IS NOT NULL AND snoozedUntil <= ?", arguments: [now])
            guard !due.isEmpty else { return [] }
            try db.execute(
                sql: "UPDATE inbox_item SET snoozedUntil = NULL, isRead = 0 WHERE snoozedUntil IS NOT NULL AND snoozedUntil <= ?",
                arguments: [now])
            return due
        }
    }

    /// Re-applies VIP/keyword rules to every stored item (after the user edits rules).
    public func reclassify(with rules: AlertRules) throws {
        try dbQueue.write { db in
            let items = try InboxItem.fetchAll(db)
            for item in items {
                let flagged = !rules.isEmpty && rules.match(item) != nil
                if flagged != item.isPriority {
                    try db.execute(sql: "UPDATE inbox_item SET isPriority = ? WHERE id = ?", arguments: [flagged, item.id])
                }
            }
        }
    }

    public func setNote(_ id: String, _ note: String?) throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE inbox_item SET note = ? WHERE id = ?",
                           arguments: [trimmed?.isEmpty == false ? trimmed : nil, id])
        }
    }

    public func setLabel(_ ids: [String], _ label: String, on: Bool) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for var item in try InboxItem.fetchAll(db, keys: ids) {
                if on, !item.labels.contains(label) { item.labels.append(label) }
                if !on { item.labels.removeAll { $0 == label } }
                try item.update(db)
            }
        }
    }

    /// Re-runs rules over stored messages (labels / flags only ever get added, never removed).
    @discardableResult
    public func apply(_ ruleSet: RuleSet) throws -> Int {
        try dbQueue.write { db in
            var changed = 0
            for item in try InboxItem.fetchAll(db) {
                let out = ruleSet.apply(to: item).item
                if out != item { try out.update(db); changed += 1 }
            }
            return changed
        }
    }

    /// Archives read, unpinned messages received before `date`. Returns how many.
    @discardableResult
    public func autoArchiveRead(before date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE inbox_item SET isArchived = 1 WHERE isRead = 1 AND isPinned = 0 AND isArchived = 0 AND receivedAt < ?",
                           arguments: [date])
            return db.changesCount
        }
    }

    /// Everything received in a date range (export).
    public func fetch(from start: Date, to end: Date, platforms: Set<Platform>? = nil) throws -> [InboxItem] {
        try dbQueue.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_item WHERE receivedAt >= ? AND receivedAt <= ? ORDER BY receivedAt",
                                   arguments: [start, end])
                .filter { platforms == nil || platforms!.contains($0.platform) }
        }
    }

    public func markAllRead(in filter: InboxFilter) throws {
        let (whereSQL, args) = Self.whereClause(filter: filter, search: nil)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE inbox_item SET isRead = 1 WHERE \(whereSQL)", arguments: args)
        }
    }

    /// Deletes non-pinned items received before `date`. Returns number of rows removed.
    @discardableResult
    public func purge(olderThan date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM inbox_item WHERE receivedAt < ? AND isPinned = 0",
                arguments: [date]
            )
            return db.changesCount
        }
    }

    private func update(_ ids: [String], column: String, _ value: Bool) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            var args: [DatabaseValueConvertible] = [value]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE inbox_item SET \(column) = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Reads

    public func item(id: String) throws -> InboxItem? {
        try dbQueue.read { db in try InboxItem.fetchOne(db, key: id) }
    }

    public func fetch(filter: InboxFilter, search: String? = nil, limit: Int = 500) throws -> [InboxItem] {
        try dbQueue.read { db in try Self.fetch(db, filter: filter, search: search, limit: limit) }
    }

    public static func fetch(_ db: Database, filter: InboxFilter, search: String?, limit: Int) throws -> [InboxItem] {
        let (whereSQL, args) = whereClause(filter: filter, search: search)
        var all = args
        all += [limit]
        return try InboxItem.fetchAll(
            db,
            sql: "SELECT * FROM inbox_item WHERE \(whereSQL) ORDER BY receivedAt DESC LIMIT ?",
            arguments: all
        )
    }

    /// Number of items in a view (unreadOnly: only unread ones).
    public static func count(_ db: Database, filter: InboxFilter, unreadOnly: Bool) throws -> Int {
        let (whereSQL, args) = whereClause(filter: filter, search: nil)
        let sql = "SELECT COUNT(*) FROM inbox_item WHERE \(whereSQL)" + (unreadOnly ? " AND isRead = 0" : "")
        return try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
    }

    /// Unread, visible (not archived / snoozed) counts per platform.
    public static func unreadCounts(_ db: Database) throws -> [Platform: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT platform, COUNT(*) AS n FROM inbox_item
            WHERE isRead = 0 AND isArchived = 0 AND snoozedUntil IS NULL GROUP BY platform
            """)
        var result: [Platform: Int] = [:]
        for row in rows {
            if let p = Platform(rawValue: row["platform"]) { result[p] = row["n"] }
        }
        return result
    }

    public func unreadCounts() throws -> [Platform: Int] {
        try dbQueue.read { try Self.unreadCounts($0) }
    }

    // MARK: - Key/value (capture cursors, settings)

    public func value(for key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    public func setValue(_ value: String, for key: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Query building

    static func whereClause(filter: InboxFilter, search: String?) -> (String, StatementArguments) {
        var clauses: [String] = []
        var args = StatementArguments()
        let visible = "isArchived = 0 AND snoozedUntil IS NULL"
        switch filter {
        case .all: clauses.append(visible)
        case .unread: clauses.append("isRead = 0 AND \(visible)")
        case .pinned: clauses.append("isPinned = 1")
        case .priority: clauses.append("isPriority = 1 AND \(visible)")
        case .snoozed: clauses.append("snoozedUntil IS NOT NULL AND isArchived = 0")
        case .archived: clauses.append("isArchived = 1")
        case .platform(let p):
            clauses.append("platform = ? AND \(visible)")
            args += [p.rawValue]
        case .label(let l):
            // labels is a JSON array; match the quoted element.
            clauses.append("labels LIKE ? AND isArchived = 0")
            args += ["%" + (String(data: (try? JSONEncoder().encode(l)) ?? Data(), encoding: .utf8) ?? l) + "%"]
        }
        if let query = ftsQuery(from: search) {
            clauses.append("rowid IN (SELECT rowid FROM inbox_fts WHERE inbox_fts MATCH ?)")
            args += [query]
        }
        return (clauses.joined(separator: " AND "), args)
    }

    /// Turns free text into a safe FTS5 prefix query: `foo bar` → `"foo"* "bar"*`.
    static func ftsQuery(from search: String?) -> String? {
        guard let search else { return nil }
        let terms = search
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
