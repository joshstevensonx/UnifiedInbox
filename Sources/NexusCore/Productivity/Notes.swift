import Foundation

// MARK: - Notes (feature spec §10): plain Markdown files, [[wiki links]], backlinks, daily notes

/// One note = one `.md` file in the notes folder. The file name (without extension) is the title.
public struct Note: Identifiable, Equatable, Sendable {
    public var id: String { title.lowercased() }
    public var title: String
    public var body: String
    public var modified: Date

    public init(title: String, body: String, modified: Date = Date()) {
        self.title = title; self.body = body; self.modified = modified
    }

    public var links: [String] { NoteLinks.links(in: body) }
    public var tags: [String] { NoteLinks.tags(in: body) }
    public var isDaily: Bool { DailyNotes.date(fromTitle: title) != nil }

    /// First non-empty, non-heading line, for list previews.
    public var preview: String {
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
    }
}

public enum NoteLinks {
    /// `[[Title]]` and `[[Title|shown text]]` → ["Title"], in order, without duplicates (case-insensitive).
    public static func links(in text: String) -> [String] {
        var result: [String] = [], seen = Set<String>()
        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            let inner = after[..<close.lowerBound]
            if !inner.contains("\n"), !inner.contains("[") {
                let target = inner.split(separator: "|", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !target.isEmpty, seen.insert(target.lowercased()).inserted { result.append(target) }
            }
            rest = after[close.upperBound...]
        }
        return result
    }

    /// `#tag` words (letters, digits, - and _; not headings, not `#123` numbers), lowercased, unique.
    public static func tags(in text: String) -> [String] {
        var result: [String] = [], seen = Set<String>()
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                if chars[i] == "#", i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "(" {
                    var j = i + 1
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" || chars[j] == "/" { j += 1 }
                    let tag = String(chars[(i + 1)..<j])
                    if !tag.isEmpty, tag.contains(where: \.isLetter), seen.insert(tag.lowercased()).inserted {
                        result.append(tag.lowercased())
                    }
                    i = j
                } else {
                    i += 1
                }
            }
        }
        return result
    }

    /// Notes that link to `title`, most recently modified first.
    public static func backlinks(to title: String, in notes: [Note]) -> [Note] {
        let key = title.lowercased()
        return notes.filter { $0.id != key && $0.links.contains { $0.lowercased() == key } }
            .sorted { $0.modified > $1.modified }
    }

    /// Notes that mention `title` as plain text without linking it ("unlinked mentions").
    public static func unlinkedMentions(of title: String, in notes: [Note]) -> [Note] {
        let key = title.lowercased()
        guard key.count >= 3 else { return [] }
        return notes.filter { n in
            n.id != key && !n.links.contains { $0.lowercased() == key } && n.body.lowercased().contains(key)
        }
    }

    /// Rewrites `[[old]]` / `[[old|alias]]` to point at `new` (used when a note is renamed).
    public static func renameLinks(in text: String, from old: String, to new: String) -> String {
        var out = "", rest = Substring(text)
        while let open = rest.range(of: "[[") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { out += rest[open.lowerBound...]; return out }
            let inner = after[..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, first.trimmingCharacters(in: .whitespaces).lowercased() == old.lowercased() {
                out += "[[" + new + (parts.count > 1 ? "|" + parts[1] : "") + "]]"
            } else {
                out += "[[" + inner + "]]"
            }
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    /// Titles that are linked somewhere but have no note yet.
    public static func missingTargets(in notes: [Note]) -> [String] {
        let existing = Set(notes.map(\.id))
        var seen = Set<String>(), result: [String] = []
        for n in notes { for l in n.links where !existing.contains(l.lowercased()) && seen.insert(l.lowercased()).inserted { result.append(l) } }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

public enum DailyNotes {
    /// "2026-11-02"
    public static func title(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(fromTitle title: String, calendar: Calendar = .current) -> Date? {
        let parts = title.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: comps), title == Self.title(for: date, calendar: calendar) else { return nil }
        return date
    }

    public static func template(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "EEEE d MMMM yyyy"
        let prev = calendar.date(byAdding: .day, value: -1, to: date).map { title(for: $0, calendar: calendar) } ?? ""
        return "# \(f.string(from: date))\n\n← [[\(prev)]]\n\n## Tasks\n- [ ] \n\n## Notes\n\n"
    }
}

// MARK: - Markdown blocks (for the preview; inline styling is done by the UI)

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(number: Int, text: String)
    case task(checked: Bool, text: String, line: Int)
    case quote(String)
    case code(String)
    case rule
    case paragraph(String)
}

public enum MarkdownParser {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) / 2
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush(); blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1)))); continue
                }
            }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line == "- [ ]" {
                flush()
                blocks.append(.task(checked: line.hasPrefix("- [x]") || line.hasPrefix("- [X]"), text: String(line.dropFirst(6)), line: index))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); blocks.append(.bullet(indent: indent, text: String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); blocks.append(.numbered(number: n, text: String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            paragraph.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Flips the checkbox on `line` (0-based). Returns the text unchanged if that line isn't a task.
    public static func toggleTask(in text: String, line: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        let l = lines[line]
        if let r = l.range(of: "- [ ]") { lines[line] = l.replacingCharacters(in: r, with: "- [x]") }
        else if let r = l.range(of: "- [x]") ?? l.range(of: "- [X]") { lines[line] = l.replacingCharacters(in: r, with: "- [ ]") }
        return lines.joined(separator: "\n")
    }

    /// Turns `[[Title]]` / `[[Title|text]]` into Markdown links with the `note:` scheme, for inline rendering.
    public static func linkify(_ text: String) -> String {
        var out = "", rest = Substring(text)
        while let open = rest.range(of: "[[") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { out += rest[open.lowerBound...]; return out }
            let parts = after[..<close.lowerBound].split(separator: "|", maxSplits: 1)
            let target = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let shown = parts.count > 1 ? String(parts[1]) : target
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            out += "[\(shown)](note:\(encoded))"
            rest = after[close.upperBound...]
        }
        return out + rest
    }
}

// MARK: - Folder store

/// Reads and writes notes as `<title>.md` in a folder (default: Application Support/UnifiedInbox/Notes).
public final class NoteFolder {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    public static func defaultFolder() -> URL {
        JSONFileStore<String>.defaultURL("x").deletingLastPathComponent().appendingPathComponent("Notes", isDirectory: true)
    }

    /// Characters macOS / Finder dislike in file names are replaced with "-".
    public static func fileName(for title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        let safe: String = cleaned.hasPrefix(".") ? "_" + String(cleaned.dropFirst()) : cleaned
        return (safe.isEmpty ? "Untitled" : safe) + ".md"
    }

    public func url(for title: String) -> URL { folder.appendingPathComponent(Self.fileName(for: title)) }

    public func loadAll() -> [Note] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return Note(title: url.deletingPathExtension().lastPathComponent, body: body, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    public func save(_ note: Note) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try note.body.write(to: url(for: note.title), atomically: true, encoding: .utf8)
    }

    public func delete(title: String) throws {
        try FileManager.default.removeItem(at: url(for: title))
    }

    /// Renames the file and rewrites links in every other note. Returns the notes that changed.
    @discardableResult
    public func rename(_ old: String, to new: String, notes: [Note]) throws -> [Note] {
        let fm = FileManager.default
        let from = url(for: old), to = url(for: new)
        if from.path.lowercased() != to.path.lowercased(), fm.fileExists(atPath: to.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.moveItem(at: from, to: to)
        var changed: [Note] = []
        for n in notes where n.id != old.lowercased() {
            let body = NoteLinks.renameLinks(in: n.body, from: old, to: new)
            if body != n.body {
                let updated = Note(title: n.title, body: body)
                try save(updated)
                changed.append(updated)
            }
        }
        return changed
    }
}

public enum NoteSearch {
    /// Title hits first (prefix > contains), then body hits; most recent first within each tier.
    public static func search(_ query: String, in notes: [Note]) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes.sorted { $0.modified > $1.modified } }
        if q.hasPrefix("#") {
            let tag = String(q.dropFirst())
            return notes.filter { $0.tags.contains(tag) }.sorted { $0.modified > $1.modified }
        }
        func tier(_ n: Note) -> Int? {
            let t = n.title.lowercased()
            if t.hasPrefix(q) { return 0 }
            if t.contains(q) { return 1 }
            if n.body.lowercased().contains(q) { return 2 }
            return nil
        }
        return notes.compactMap { n in tier(n).map { (n, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.modified > $1.0.modified }
            .map(\.0)
    }
}
