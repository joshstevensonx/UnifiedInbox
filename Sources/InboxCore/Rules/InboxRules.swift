import Foundation

/// A user rule: when a message matches the conditions, apply the actions (FEATURES: rules engine).
public struct InboxRule: Codable, Identifiable, Equatable, Sendable {
    public enum Condition: Codable, Equatable, Sendable {
        case senderContains(String)
        case textContains(String)        // title, subtitle or body
        case platformIs(Platform)
        case subtitleContains(String)    // e.g. email subject or chat name

        public var label: String {
            switch self {
            case .senderContains(let s): return "From contains “\(s)”"
            case .textContains(let s): return "Text contains “\(s)”"
            case .platformIs(let p): return "App is \(p.displayName)"
            case .subtitleContains(let s): return "Subject/chat contains “\(s)”"
            }
        }
    }

    public enum Action: Codable, Equatable, Sendable {
        case archive, markRead, pin, priority
        case label(String)
        /// No banner/sound for this message (still captured).
        case mute

        public var label: String {
            switch self {
            case .archive: return "Archive"
            case .markRead: return "Mark read"
            case .pin: return "Pin"
            case .priority: return "Mark priority"
            case .label(let l): return "Label “\(l)”"
            case .mute: return "Don't alert"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var matchAll: Bool
    public var conditions: [Condition]
    public var actions: [Action]

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, matchAll: Bool = true,
                conditions: [Condition], actions: [Action]) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.matchAll = matchAll
        self.conditions = conditions; self.actions = actions
    }

    public func matches(_ item: InboxItem) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        let results = conditions.map { Self.test($0, item) }
        return matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    static func test(_ c: Condition, _ item: InboxItem) -> Bool {
        func has(_ hay: String?, _ needle: String) -> Bool {
            guard let hay, !needle.isEmpty else { return false }
            return hay.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        switch c {
        case .senderContains(let s): return has(item.title, s)
        case .subtitleContains(let s): return has(item.subtitle, s)
        case .platformIs(let p): return item.platform == p
        case .textContains(let s): return has(item.title, s) || has(item.subtitle, s) || has(item.body, s)
        }
    }
}

/// Hours during which alerts are silenced (messages are still captured).
public struct QuietHours: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Minutes after midnight. If start > end the window crosses midnight (e.g. 22:00–07:00).
    public var startMinute: Int
    public var endMinute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar weekday). Empty = every day.
    public var weekdays: Set<Int>
    /// Empty = all apps.
    public var platforms: Set<Platform>

    public init(isEnabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 7 * 60,
                weekdays: Set<Int> = [], platforms: Set<Platform> = []) {
        self.isEnabled = isEnabled; self.startMinute = startMinute; self.endMinute = endMinute
        self.weekdays = weekdays; self.platforms = platforms
    }

    public func isQuiet(_ platform: Platform, at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, platforms.isEmpty || platforms.contains(platform) else { return false }
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let inWindow = startMinute <= endMinute ? (m >= startMinute && m < endMinute) : (m >= startMinute || m < endMinute)
        guard inWindow else { return false }
        if weekdays.isEmpty { return true }
        // For windows crossing midnight, the early-morning part belongs to the previous evening's day.
        var day = c.weekday ?? 1
        if startMinute > endMinute && m < endMinute { day = day == 1 ? 7 : day - 1 }
        return weekdays.contains(day)
    }
}

/// Everything rule-related, persisted as one JSON document.
public struct RuleSet: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var rules: [InboxRule] = []
    /// Label name → colour hex (for chips).
    public var labelColors: [String: String] = [:]
    public var quietHours = QuietHours()
    /// Archive read, unpinned messages older than this many hours (nil = off).
    public var autoArchiveReadAfterHours: Int?
    public var savedSearches: [SavedSearch] = []

    public init() {}

    public struct Outcome: Equatable, Sendable {
        public var item: InboxItem
        public var muted: Bool
        public var matchedRules: [String]
    }

    /// Applies every matching rule in order.
    public func apply(to item: InboxItem) -> Outcome {
        var out = item
        var muted = false
        var matched: [String] = []
        for rule in rules where rule.matches(item) {
            matched.append(rule.name)
            for action in rule.actions {
                switch action {
                case .archive: out.isArchived = true
                case .markRead: out.isRead = true
                case .pin: out.isPinned = true
                case .priority: out.isPriority = true
                case .label(let l): if !out.labels.contains(l) { out.labels.append(l) }
                case .mute: muted = true
                }
            }
        }
        return Outcome(item: out, muted: muted, matchedRules: matched)
    }

    /// Should a new message produce a banner/sound right now?
    public func shouldAlert(_ outcome: Outcome, at date: Date = Date()) -> Bool {
        !outcome.muted && !outcome.item.isArchived && !quietHours.isQuiet(outcome.item.platform, at: date)
    }

    public var allLabels: [String] {
        var set = Set(labelColors.keys)
        for r in rules { for a in r.actions { if case .label(let l) = a { set.insert(l) } } }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// A named search pinned to the sidebar.
public struct SavedSearch: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String
    public var platform: Platform?
    public var label: String?
    public var unreadOnly: Bool

    public init(id: UUID = UUID(), name: String, query: String, platform: Platform? = nil, label: String? = nil, unreadOnly: Bool = false) {
        self.id = id; self.name = name; self.query = query; self.platform = platform
        self.label = label; self.unreadOnly = unreadOnly
    }
}
