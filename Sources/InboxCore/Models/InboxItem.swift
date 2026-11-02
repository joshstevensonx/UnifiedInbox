import Foundation
import GRDB

/// Where an item was captured from.
public enum CaptureOrigin: String, Codable, Sendable {
    /// Read from the macOS Notification Center database (local, read-only).
    case notificationCenter
    /// Fetched from Microsoft Graph (Teams / Outlook, Phase 2).
    case graph
}

/// One unified notification/message in the inbox.
public struct InboxItem: Codable, Identifiable, Hashable, Sendable {
    /// Stable id. For Notification Center items this is the record UUID;
    /// for Graph items, "graph:<resource id>".
    public var id: String
    public var platform: Platform
    public var origin: CaptureOrigin
    public var sourceBundleId: String
    public var title: String
    public var subtitle: String?
    public var body: String
    /// Conversation/thread key from the source (chat id, email conversation, WhatsApp contact).
    public var threadId: String?
    public var receivedAt: Date
    public var capturedAt: Date
    public var isRead: Bool
    public var isPinned: Bool
    public var isArchived: Bool
    /// Flagged by VIP / keyword rules at capture time.
    public var isPriority: Bool
    /// Hidden from normal views until this time (then automatically un-snoozed and unread).
    public var snoozedUntil: Date?
    /// User / rule labels, e.g. a client name.
    public var labels: [String]
    /// Private note (never leaves the Mac).
    public var note: String?

    public init(
        id: String,
        platform: Platform,
        origin: CaptureOrigin,
        sourceBundleId: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        threadId: String? = nil,
        receivedAt: Date,
        capturedAt: Date = Date(),
        isRead: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isPriority: Bool = false,
        snoozedUntil: Date? = nil,
        labels: [String] = [],
        note: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.origin = origin
        self.sourceBundleId = sourceBundleId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadId = threadId
        self.receivedAt = receivedAt
        self.capturedAt = capturedAt
        self.isRead = isRead
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isPriority = isPriority
        self.snoozedUntil = snoozedUntil
        self.labels = labels
        self.note = note
    }
}

extension InboxItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "inbox_item"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let platform = Column(CodingKeys.platform)
        public static let title = Column(CodingKeys.title)
        public static let body = Column(CodingKeys.body)
        public static let receivedAt = Column(CodingKeys.receivedAt)
        public static let isRead = Column(CodingKeys.isRead)
        public static let isPinned = Column(CodingKeys.isPinned)
        public static let isArchived = Column(CodingKeys.isArchived)
        public static let isPriority = Column(CodingKeys.isPriority)
        public static let snoozedUntil = Column(CodingKeys.snoozedUntil)
    }
}
