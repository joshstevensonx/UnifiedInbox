import Foundation
import GRDB

/// Captures Teams / Outlook / WhatsApp notifications by reading the macOS Notification Center
/// database read-only. Fully local, no accounts. Requires Full Disk Access on macOS 15+.
///
/// Limits (see SPEC.md): only sees what the apps post as notifications (so muted chats,
/// focus-filtered or "preview hidden" notifications are missing or truncated), and the
/// schema is private — it has changed across macOS versions and may change again.
public final class NotificationCenterSource: CaptureSource, @unchecked Sendable {
    public let identifier = "notificationCenter"
    public let pollInterval: TimeInterval
    public private(set) var platforms: Set<Platform>
    private let dbPathOverride: String?
    private let lock = NSLock()

    public static let cursorKey = "notificationCenter.lastRecId"
    private var cursorKey: String { Self.cursorKey }

    public init(platforms: Set<Platform> = Platform.defaultEnabled,
                pollInterval: TimeInterval = 2,
                databasePath: String? = nil) {
        self.platforms = platforms
        self.pollInterval = pollInterval
        self.dbPathOverride = databasePath
    }

    /// Lets the coordinator hand a platform over to Graph (avoids duplicates).
    public func setPlatforms(_ new: Set<Platform>) {
        lock.lock(); platforms = new; lock.unlock()
    }

    // MARK: - Locating the database

    /// Candidate paths, newest macOS layout first.
    public static func candidatePaths() -> [String] {
        var paths: [String] = []
        let home = NSHomeDirectory()
        // macOS 15 Sequoia and later
        paths.append("\(home)/Library/Group Containers/group.com.apple.usernoted/db2/db")
        // macOS 13–14: $(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db
        #if os(macOS)
        if let userDir = darwinUserDir() {
            paths.append("\(userDir)com.apple.notificationcenter/db2/db")
        }
        #endif
        return paths
    }

    #if os(macOS)
    private static func darwinUserDir() -> String? {
        let len = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        confstr(_CS_DARWIN_USER_DIR, &buf, len)
        return String(cString: buf)
    }
    #endif

    public func resolvedDatabasePath() -> String? {
        if let dbPathOverride { return dbPathOverride }
        return Self.candidatePaths().first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Quick health check for onboarding: can we actually open and query the DB?
    public func checkAccess() -> CaptureStatus {
        guard let path = resolvedDatabasePath() else {
            let exists = Self.candidatePaths().contains { FileManager.default.fileExists(atPath: $0) }
            return exists
                ? .needsSetup("Grant Full Disk Access to UnifiedInbox in System Settings → Privacy & Security.")
                : .failed("Notification Center database not found on this macOS version.")
        }
        do {
            let q = try Self.openReadOnly(path)
            _ = try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM record") }
            return .running
        } catch {
            return .needsSetup("Cannot read Notification Center database (\(error.localizedDescription)). Grant Full Disk Access.")
        }
    }

    private static func openReadOnly(_ path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.label = "NotificationCenterDB"
        return try DatabaseQueue(path: path, configuration: config)
    }

    // MARK: - Polling

    private func currentPlatforms() -> Set<Platform> {
        lock.lock(); defer { lock.unlock() }
        return platforms
    }

    public func poll(store: InboxStore) async throws -> [InboxItem] {
        try pollSync(store: store)
    }

    /// Synchronous body of `poll` (GRDB's blocking API; runs off the main actor via the coordinator).
    public func pollSync(store: InboxStore) throws -> [InboxItem] {
        let wanted = currentPlatforms()
        guard !wanted.isEmpty, let path = resolvedDatabasePath() else { return [] }

        let bundleIds = wanted.flatMap(\.bundleIdentifiers).map { $0.lowercased() }
        let stored = Int64(try store.value(for: cursorKey) ?? "0") ?? 0

        let source = try Self.openReadOnly(path)
        let (rows, cursor): ([NotificationRecordParser.RawRecord], Int64) = try source.read { db in
            let maxId = try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(rec_id), 0) FROM record") ?? 0
            // DB was reset/vacuumed (or migrated): rescan; ids dedupe in the store.
            let cursor = maxId < stored ? 0 : stored

            let placeholders = databaseQuestionMarks(count: bundleIds.count)
            var args: [DatabaseValueConvertible] = [cursor]
            args.append(contentsOf: bundleIds)
            let sql = """
                SELECT r.rec_id, r.uuid, r.data, r.delivered_date, a.identifier
                FROM record r JOIN app a ON a.app_id = r.app_id
                WHERE r.rec_id > ? AND lower(a.identifier) IN (\(placeholders))
                ORDER BY r.rec_id ASC LIMIT 1000
                """
            let raw = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row -> NotificationRecordParser.RawRecord? in
                let uuidValue: Any? = {
                    switch (row["uuid"] as DatabaseValue).storage {
                    case .blob(let d): return d
                    case .string(let s): return s
                    default: return nil
                    }
                }()
                guard let data = row["data"] as Data?,
                      let uuid = NotificationRecordParser.uuidString(from: uuidValue) else { return nil }
                return .init(recId: row["rec_id"], uuid: uuid, appIdentifier: row["identifier"],
                             data: data, deliveredDate: row["delivered_date"])
            }
            return (raw, cursor)
        }

        let items = rows.compactMap { NotificationRecordParser.parse($0) }
        let newCursor = rows.last?.recId ?? cursor
        try store.setValue(String(newCursor), for: cursorKey)
        return items
    }
}
