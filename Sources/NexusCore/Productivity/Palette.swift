import Foundation

/// A user-defined shortcut typed in the launcher, e.g. `yt` → https://youtube.com (spec §1.4).
public struct CommandAlias: Codable, Identifiable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Sendable {
        case url(String)
        case app(String)        // bundle id or path
        case command(String)    // palette command id
    }

    public var id: UUID
    public var alias: String
    public var target: Target
    public var title: String

    public init(id: UUID = UUID(), alias: String, target: Target, title: String) {
        self.id = id; self.alias = alias.lowercased().trimmingCharacters(in: .whitespaces)
        self.target = target; self.title = title
    }

    public static let defaults: [CommandAlias] = [
        CommandAlias(alias: "yt", target: .url("https://www.youtube.com"), title: "YouTube"),
        CommandAlias(alias: "gh", target: .url("https://github.com"), title: "GitHub"),
        CommandAlias(alias: "mail", target: .command("inbox.unread"), title: "Unread messages"),
        CommandAlias(alias: "ss", target: .command("capture.region"), title: "Screenshot region"),
    ]
}

public struct AliasConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var aliases: [CommandAlias]
    public init(aliases: [CommandAlias] = CommandAlias.defaults) { self.aliases = aliases }

    /// Exact alias match (case-insensitive). A trailing query after the alias is returned as `argument`,
    /// so `g swift concurrency` can become a search when the alias URL contains `{query}`.
    public func resolve(_ input: String) -> (alias: CommandAlias, argument: String?)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first?.lowercased(), let alias = aliases.first(where: { $0.alias == head }) else { return nil }
        return (alias, parts.count > 1 ? parts[1] : nil)
    }

    /// Substitutes `{query}` in URL aliases with the percent-encoded argument.
    public static func expand(_ url: String, argument: String?) -> String {
        guard url.contains("{query}") else { return url }
        let encoded = (argument ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return url.replacingOccurrences(of: "{query}", with: encoded)
    }
}

/// Ranking for anything with a title and keywords (commands, settings, pages).
public enum PaletteRanking {
    public static func score(title: String, keywords: [String], query: String) -> Int? {
        let best = ([title] + keywords).compactMap { LauncherSearch.score($0, query: query) }.max()
        // Keyword-only matches rank a little below title matches.
        if let t = LauncherSearch.score(title, query: query), t == best { return t }
        return best.map { $0 - 50 }
    }

    public static func rank<T>(_ items: [T], query: String, title: (T) -> String, keywords: (T) -> [String]) -> [T] {
        items.compactMap { i in score(title: title(i), keywords: keywords(i), query: query).map { (i, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
