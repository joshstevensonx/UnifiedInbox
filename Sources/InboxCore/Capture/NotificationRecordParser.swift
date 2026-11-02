import Foundation

/// Decodes a row of the macOS Notification Center database (`record` table) into an `InboxItem`.
///
/// The `data` column is a binary plist shaped roughly like:
/// ```
/// { app: "com.microsoft.teams2",
///   date: 783456789.12,            // seconds since 2001-01-01 (Mac absolute time)
///   req: { titl: "Jane Doe", subt: "Project chat", body: "Can you review?",
///          thre: "19:abc@thread.v2", iden: "…" } }
/// ```
/// Keys are undocumented and have shifted between macOS versions, so every field is optional.
public enum NotificationRecordParser {
    public struct RawRecord: Sendable {
        public var recId: Int64
        public var uuid: String
        public var appIdentifier: String
        public var data: Data
        /// `delivered_date` column (Mac absolute time), if present.
        public var deliveredDate: Double?

        public init(recId: Int64, uuid: String, appIdentifier: String, data: Data, deliveredDate: Double?) {
            self.recId = recId
            self.uuid = uuid
            self.appIdentifier = appIdentifier
            self.data = data
            self.deliveredDate = deliveredDate
        }
    }

    /// Returns nil for apps we don't aggregate or records with no usable text.
    public static func parse(_ raw: RawRecord, capturedAt: Date = Date()) -> InboxItem? {
        guard let platform = Platform.from(bundleIdentifier: raw.appIdentifier) else { return nil }

        let plist = (try? PropertyListSerialization.propertyList(from: raw.data, options: [], format: nil)) as? [String: Any]
        let req = plist?["req"] as? [String: Any] ?? [:]

        let title = clean(req["titl"] as? String)
        let subtitle = clean(req["subt"] as? String)
        let body = clean(req["body"] as? String)
        guard title != nil || body != nil else { return nil }

        let macTime = raw.deliveredDate ?? (plist?["date"] as? Double)
        let received = macTime.map { Date(timeIntervalSinceReferenceDate: $0) } ?? capturedAt

        return InboxItem(
            id: "nc:\(raw.uuid)",
            platform: platform,
            origin: .notificationCenter,
            sourceBundleId: raw.appIdentifier,
            title: title ?? platform.displayName,
            subtitle: subtitle,
            body: body ?? "",
            threadId: clean(req["thre"] as? String),
            receivedAt: received,
            capturedAt: capturedAt
        )
    }

    /// Converts the 16-byte `uuid` blob (or a text uuid) into a canonical string.
    public static func uuidString(from value: Any?) -> String? {
        if let data = value as? Data, data.count == 16 {
            let b = [UInt8](data)
            let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            return uuid.uuidString
        }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
