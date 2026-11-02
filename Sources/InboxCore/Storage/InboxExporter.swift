import Foundation

/// Exports inbox items for record-keeping, billing or sharing.
public enum InboxExporter {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv, json, markdown
        public var id: String { rawValue }
        public var fileExtension: String { self == .markdown ? "md" : rawValue }
        public var title: String {
            switch self {
            case .csv: return "CSV (Excel, Numbers, Sheets)"
            case .json: return "JSON"
            case .markdown: return "Markdown"
            }
        }
    }

    public static func export(_ items: [InboxItem], as format: Format) throws -> Data {
        switch format {
        case .csv: return Data(csv(items).utf8)
        case .json: return try json(items)
        case .markdown: return Data(markdown(items).utf8)
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func csv(_ items: [InboxItem]) -> String {
        func field(_ s: String?) -> String {
            let v = s ?? ""
            let needsQuotes = v.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            return needsQuotes ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v
        }
        var lines = ["received_at,app,from,subject,message,read,pinned,priority,archived"]
        for i in items {
            lines.append([
                iso.string(from: i.receivedAt), i.platform.displayName, i.title, i.subtitle, i.body,
                String(i.isRead), String(i.isPinned), String(i.isPriority), String(i.isArchived),
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func json(_ items: [InboxItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    static func markdown(_ items: [InboxItem]) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var out = "# Unified Inbox export\n\n\(items.count) messages\n"
        for i in items {
            out += "\n## \(i.title) · \(i.platform.displayName)\n"
            out += "_\(df.string(from: i.receivedAt))_"
            if i.isPriority { out += " · ★ priority" }
            out += "\n\n"
            if let s = i.subtitle { out += "**\(s)**\n\n" }
            out += i.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }
}
