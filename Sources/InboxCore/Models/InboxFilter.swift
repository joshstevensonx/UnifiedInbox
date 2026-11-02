import Foundation

/// Sidebar selection / query scope.
public enum InboxFilter: Hashable, Sendable {
    case all
    case unread
    case pinned
    case priority
    case snoozed
    case archived
    case platform(Platform)
    case label(String)

    public var title: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .pinned: return "Pinned"
        case .priority: return "Priority"
        case .snoozed: return "Snoozed"
        case .archived: return "Archived"
        case .platform(let p): return p.displayName
        case .label(let l): return l
        }
    }
}
