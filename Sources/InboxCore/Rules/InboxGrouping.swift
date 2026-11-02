import Foundation

/// A conversation: consecutive messages from the same chat / thread / sender on one platform.
public struct InboxGroup: Identifiable, Hashable, Sendable {
    /// `platform|key`
    public let id: String
    /// Newest first.
    public let items: [InboxItem]

    public var latest: InboxItem { items[0] }
    public var count: Int { items.count }
    public var unreadCount: Int { items.filter { !$0.isRead }.count }
    public var ids: Set<String> { Set(items.map(\.id)) }
    public var isPriority: Bool { items.contains(where: \.isPriority) }
}

public enum InboxGrouping {
    /// Conversation key: the source thread id when present, otherwise the sender/chat title.
    public static func key(for item: InboxItem) -> String {
        let base = item.threadId?.isEmpty == false ? "t:\(item.threadId!)" : "n:\(item.title.lowercased())"
        return "\(item.platform.rawValue)|\(base)"
    }

    /// Groups items (already sorted newest first) preserving that order by each group's newest item.
    public static func group(_ items: [InboxItem]) -> [InboxGroup] {
        var order: [String] = []
        var buckets: [String: [InboxItem]] = [:]
        for item in items {
            let k = key(for: item)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(item)
        }
        return order.map { InboxGroup(id: $0, items: buckets[$0]!) }
    }
}

/// Day sections for the list ("Today", "Yesterday", "This Week", "Earlier").
public enum DayBucket: Int, CaseIterable, Comparable, Sendable {
    case today, yesterday, thisWeek, earlier

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .earlier: return "Earlier"
        }
    }

    public static func < (a: DayBucket, b: DayBucket) -> Bool { a.rawValue < b.rawValue }

    public static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return .thisWeek
        }
        return .earlier
    }

    /// Splits rows (already newest first) into ordered, non-empty sections.
    public static func sections<T>(_ rows: [T], now: Date = Date(), calendar: Calendar = .current,
                                   date: (T) -> Date) -> [(bucket: DayBucket, rows: [T])] {
        var dict: [DayBucket: [T]] = [:]
        for r in rows { dict[bucket(for: date(r), now: now, calendar: calendar), default: []].append(r) }
        return DayBucket.allCases.compactMap { b in dict[b].map { (b, $0) } }
    }
}
