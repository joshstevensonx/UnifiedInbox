import Foundation

// MARK: - Text snippets (feature spec §1.4): type an abbreviation anywhere, it's replaced by the expansion.

public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What you type, e.g. ";sig" or "@@addr".
    public var abbreviation: String
    public var expansion: String
    public var enabled: Bool
    public var useCount: Int

    public init(id: UUID = UUID(), abbreviation: String, expansion: String, enabled: Bool = true, useCount: Int = 0) {
        self.id = id; self.abbreviation = abbreviation; self.expansion = expansion; self.enabled = enabled; self.useCount = useCount
    }
}

public struct SnippetConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var enabled = false
    public var snippets: [Snippet] = SnippetConfig.examples
    /// Apps (bundle ids) where expansion never happens, e.g. terminals or games.
    public var excludedApps: [String] = []
    public init() {}

    public static let examples: [Snippet] = [
        Snippet(abbreviation: ";date", expansion: "{date}"),
        Snippet(abbreviation: ";time", expansion: "{time}"),
        Snippet(abbreviation: ";shrug", expansion: "¯\\_(ツ)_/¯"),
        Snippet(abbreviation: ";ty", expansion: "Thanks for your message. I'll get back to you {weekday}.{cursor}"),
    ]

    /// Duplicate, too-short or overlapping abbreviations (a prefix of another fires first).
    public var problems: [String] {
        let abbrs = snippets.filter(\.enabled).map(\.abbreviation)
        var out: [String] = []
        for (i, a) in abbrs.enumerated() {
            if a.count < 2 { out.append("“\(a)” is too short") }
            if abbrs[(i + 1)...].contains(a) { out.append("“\(a)” is used twice") }
            if let longer = abbrs.first(where: { $0 != a && $0.hasSuffix(a) }) { out.append("“\(a)” also ends “\(longer)”; the longer one wins") }
            if let longer = abbrs.first(where: { $0 != a && $0.hasPrefix(a) }) { out.append("“\(a)” expands before “\(longer)” can be typed") }
        }
        return out
    }
}

/// Keeps the last typed characters and reports when they end with an abbreviation.
public struct SnippetMatcher: Sendable {
    public private(set) var buffer = ""
    public let capacity: Int
    public init(capacity: Int = 64) { self.capacity = capacity }

    /// Feed one typed character. Returns the matching snippet (longest abbreviation wins), if any.
    /// The abbreviation must start the buffer or follow a non-alphanumeric character, so ";sig" inside
    /// "x;sig" still works but "sig" doesn't fire inside "design".
    public mutating func type(_ ch: Character, snippets: [Snippet]) -> Snippet? {
        buffer.append(ch)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let candidates = snippets.filter { $0.enabled && !$0.abbreviation.isEmpty && buffer.hasSuffix($0.abbreviation) }
            .sorted { $0.abbreviation.count > $1.abbreviation.count }
        for s in candidates {
            let before = buffer.dropLast(s.abbreviation.count).last
            let startsWithWordChar = s.abbreviation.first.map { $0.isLetter || $0.isNumber } ?? false
            if before == nil || !startsWithWordChar || !(before!.isLetter || before!.isNumber) {
                buffer = ""
                return s
            }
        }
        return nil
    }

    public mutating func backspace() { if !buffer.isEmpty { buffer.removeLast() } }

    /// Call on clicks, arrow keys, app switches: the typed context is no longer contiguous.
    public mutating func reset() { buffer = "" }
}

public enum SnippetExpander {
    /// Fills placeholders. `{cursor}` is removed and reported as the number of characters after it,
    /// so the app can move the caret back. Returns (text, caretOffsetFromEnd).
    public static func expand(_ template: String, now: Date = Date(), clipboard: String? = nil,
                              locale: Locale = .current, calendar: Calendar = .current) -> (text: String, caretFromEnd: Int) {
        func fmt(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> String {
            let f = DateFormatter()
            f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
            f.dateStyle = date; f.timeStyle = time
            return f.string(from: now)
        }
        let weekday: String = {
            let f = DateFormatter()
            f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
            f.dateFormat = "EEEE"
            return f.string(from: now)
        }()
        var text = template
            .replacingOccurrences(of: "{date}", with: fmt(.medium, .none))
            .replacingOccurrences(of: "{time}", with: fmt(.none, .short))
            .replacingOccurrences(of: "{datetime}", with: fmt(.medium, .short))
            .replacingOccurrences(of: "{isodate}", with: UsageLog.dayKey(now, calendar: calendar))
            .replacingOccurrences(of: "{weekday}", with: weekday)
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
        var caret = 0
        if let r = text.range(of: "{cursor}") {
            caret = text[r.upperBound...].count
            text.removeSubrange(r)
            text = text.replacingOccurrences(of: "{cursor}", with: "")
        }
        return (text, caret)
    }
}
