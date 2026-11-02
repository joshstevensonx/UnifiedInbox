import Foundation

/// Why an item was flagged as priority.
public enum PriorityReason: Equatable, Sendable {
    case vip(String)
    case keyword(String)

    public var label: String {
        switch self {
        case .vip(let name): return "VIP: \(name)"
        case .keyword(let word): return "Keyword: \(word)"
        }
    }
}

/// VIP senders + keyword alerts. Matching is case- and diacritic-insensitive.
/// - VIP: the entry appears in the item's title (sender / chat name), e.g. "Martin" matches "Martin Nicholson".
/// - Keyword: whole-word (or phrase) match in title, subtitle or body, e.g. "invoice" matches "Invoice #42" but not "invoices"…
///   unless the keyword ends with `*`, which makes it a prefix ("invoice*").
public struct AlertRules: Codable, Equatable, Sendable {
    public var vipSenders: [String]
    public var keywords: [String]

    public init(vipSenders: [String] = [], keywords: [String] = []) {
        self.vipSenders = Self.normalizeList(vipSenders)
        self.keywords = Self.normalizeList(keywords)
    }

    /// Parses comma- or newline-separated user input.
    public init(vipText: String, keywordText: String) {
        self.init(vipSenders: Self.split(vipText), keywords: Self.split(keywordText))
    }

    public var isEmpty: Bool { vipSenders.isEmpty && keywords.isEmpty }

    public func match(_ item: InboxItem) -> PriorityReason? {
        let title = Self.fold(item.title)
        if let vip = vipSenders.first(where: { title.contains(Self.fold($0)) }) {
            return .vip(vip)
        }
        let text = Self.fold([item.title, item.subtitle ?? "", item.body].joined(separator: " "))
        if let kw = keywords.first(where: { Self.containsWord(text, Self.fold($0)) }) {
            return .keyword(kw)
        }
        return nil
    }

    // MARK: helpers

    static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
    }

    static func normalizeList(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func containsWord(_ text: String, _ keyword: String) -> Bool {
        var kw = keyword
        let prefix = kw.hasSuffix("*")
        if prefix { kw.removeLast() }
        guard !kw.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: kw)
        let pattern = prefix ? "(?<![\\p{L}\\p{N}])\(escaped)" : "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
