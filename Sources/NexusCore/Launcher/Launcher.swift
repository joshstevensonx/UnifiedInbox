import Foundation

public enum LauncherItemKind: String, Codable, Sendable {
    case app, folder, url
}

public struct LauncherItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: LauncherItemKind
    public var title: String
    /// File path for apps/folders, absolute URL string for URLs.
    public var target: String
    public var bundleId: String?
    public var groupId: UUID?
    public var isPinned: Bool
    public var sortOrder: Int
    public var useCount: Int
    public var lastUsed: Date?
    /// Security-scoped bookmark for user-chosen folders (sandbox-ready).
    public var bookmarkData: Data?
    /// Discovered automatically (vs. added by the user).
    public var isDiscovered: Bool

    public init(id: UUID = UUID(), kind: LauncherItemKind, title: String, target: String, bundleId: String? = nil,
                groupId: UUID? = nil, isPinned: Bool = false, sortOrder: Int = 0, useCount: Int = 0,
                lastUsed: Date? = nil, bookmarkData: Data? = nil, isDiscovered: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.target = target; self.bundleId = bundleId
        self.groupId = groupId; self.isPinned = isPinned; self.sortOrder = sortOrder; self.useCount = useCount
        self.lastUsed = lastUsed; self.bookmarkData = bookmarkData; self.isDiscovered = isDiscovered
    }

    /// Identity used to merge rediscovered apps with saved state (pins, usage).
    public var mergeKey: String { bundleId.map { "b:\($0.lowercased())" } ?? "t:\(target)" }
}

public struct LauncherGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var iconName: String?
    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0, iconName: String? = nil) {
        self.id = id; self.name = name; self.sortOrder = sortOrder; self.iconName = iconName
    }
}

public enum LauncherSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, alphabetical, recent, frequent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .manual: return "Manual"
        case .alphabetical: return "A–Z"
        case .recent: return "Recent"
        case .frequent: return "Most used"
        }
    }
}

public enum LauncherSearch {
    /// Score a title against a query; nil = no match. Higher is better.
    /// exact > prefix > word-start > initials ("vsc" → Visual Studio Code) > substring > subsequence.
    public static func score(_ title: String, query: String) -> Int? {
        let t = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 800 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 600 }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(q) { return 500 }
        if t.contains(q) { return 400 }
        // Subsequence: every query char appears in order.
        var idx = t.startIndex
        for ch in q where ch != " " {
            guard let found = t[idx...].firstIndex(of: ch) else { return nil }
            idx = t.index(after: found)
        }
        return 100
    }

    /// Ranked search; ties broken by pinned, usage, shorter title, then A–Z.
    public static func search(_ items: [LauncherItem], query: String, limit: Int = 50) -> [LauncherItem] {
        items.compactMap { item in score(item.title, query: query).map { (item, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.isPinned != b.0.isPinned { return a.0.isPinned }
                if a.0.useCount != b.0.useCount { return a.0.useCount > b.0.useCount }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    public static func sorted(_ items: [LauncherItem], by sort: LauncherSort) -> [LauncherItem] {
        switch sort {
        case .manual:
            return items.sorted { ($0.sortOrder, $0.title.lowercased()) < ($1.sortOrder, $1.title.lowercased()) }
        case .alphabetical:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent:
            return items.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        case .frequent:
            return items.sorted { $0.useCount != $1.useCount ? $0.useCount > $1.useCount
                                                             : $0.title.lowercased() < $1.title.lowercased() }
        }
    }
}

/// Persisted launcher configuration (versioned, spec §9).
public struct LauncherConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var items: [LauncherItem]
    public var groups: [LauncherGroup]
    public var sort: LauncherSort

    public init(items: [LauncherItem] = [], groups: [LauncherGroup] = [], sort: LauncherSort = .alphabetical) {
        schemaVersion = Self.currentSchema; self.items = items; self.groups = groups; self.sort = sort
    }

    /// Merge freshly discovered apps with saved state: keep pins/usage/groups, add new apps,
    /// drop discovered apps that disappeared, keep user-added items (marked missing in UI if gone).
    public mutating func mergeDiscovered(_ discovered: [LauncherItem]) {
        let saved = Dictionary(items.map { ($0.mergeKey, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [LauncherItem] = discovered.map { d in
            guard var s = saved[d.mergeKey] else { return d }
            s.target = d.target   // app may have moved
            s.title = d.title
            s.isDiscovered = true
            return s
        }
        let discoveredKeys = Set(discovered.map(\.mergeKey))
        merged += items.filter { !$0.isDiscovered && !discoveredKeys.contains($0.mergeKey) }
        items = merged
    }

    public mutating func recordLaunch(_ id: UUID, at date: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].useCount += 1
        items[i].lastUsed = date
    }
}

/// JSON file store under Application Support.
public final class JSONFileStore<Value: Codable> {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UnifiedInbox/\(name).json")
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
