import Foundation

// MARK: - Daily digest (task 24): an extractive summary of a day's messages. Works without any AI model;
// the app can add an on-device language-model summary (FoundationModels) on top when available.

public struct DailyDigest: Equatable, Sendable {
    public struct Sender: Equatable, Sendable {
        public var name: String
        public var platform: Platform
        public var count: Int
        public var unread: Int
        public var lastText: String
    }

    public var day: Date
    public var total: Int
    public var unread: Int
    public var byPlatform: [(platform: Platform, count: Int)]
    public var priority: [InboxItem]
    public var topSenders: [Sender]
    /// Conversations whose newest message is still unread (likely waiting for a reply).
    public var awaiting: [Sender]
    public var busiestHour: Int?

    public static func == (a: DailyDigest, b: DailyDigest) -> Bool {
        a.day == b.day && a.total == b.total && a.unread == b.unread
            && a.byPlatform.map(\.platform) == b.byPlatform.map(\.platform) && a.byPlatform.map(\.count) == b.byPlatform.map(\.count)
            && a.priority.map(\.id) == b.priority.map(\.id) && a.topSenders == b.topSenders && a.awaiting == b.awaiting
            && a.busiestHour == b.busiestHour
    }

    public static func make(_ items: [InboxItem], day: Date, calendar: Calendar = .current) -> DailyDigest {
        let todays = items.filter { calendar.isDate($0.receivedAt, inSameDayAs: day) }.sorted { $0.receivedAt < $1.receivedAt }
        let platforms = Dictionary(grouping: todays, by: \.platform).map { (platform: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.platform.rawValue < $1.platform.rawValue }
        let groups = Dictionary(grouping: todays, by: InboxGrouping.key(for:))
        let senders: [Sender] = groups.values.compactMap { msgs in
            guard let last = msgs.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
            return Sender(name: last.title, platform: last.platform, count: msgs.count,
                          unread: msgs.filter { !$0.isRead }.count, lastText: last.body)
        }
        let top = senders.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let awaiting = groups.values.compactMap { msgs -> (Sender, Date)? in
            guard let last = msgs.max(by: { $0.receivedAt < $1.receivedAt }), !last.isRead, !last.isArchived else { return nil }
            return (Sender(name: last.title, platform: last.platform, count: msgs.count,
                           unread: msgs.filter { !$0.isRead }.count, lastText: last.body), last.receivedAt)
        }
        .sorted { $0.1 < $1.1 }.map(\.0)
        let hours = Dictionary(grouping: todays) { calendar.component(.hour, from: $0.receivedAt) }
        let busiest = hours.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
        return DailyDigest(day: calendar.startOfDay(for: day), total: todays.count, unread: todays.filter { !$0.isRead }.count,
                           byPlatform: platforms, priority: todays.filter(\.isPriority).reversed(),
                           topSenders: Array(top.prefix(5)), awaiting: Array(awaiting.prefix(8)), busiestHour: busiest)
    }

    /// One line for a notification.
    public var headline: String {
        guard total > 0 else { return "No messages today." }
        var s = "\(total) message\(total == 1 ? "" : "s")"
        if unread > 0 { s += ", \(unread) unread" }
        if !priority.isEmpty { s += ", \(priority.count) priority" }
        if !awaiting.isEmpty { s += ". Waiting on you: " + awaiting.prefix(3).map(\.name).joined(separator: ", ") }
        return s + "."
    }

    public func markdown(hideText: Bool = false, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE d MMMM yyyy"
        var s = "# Daily digest: \(f.string(from: day))\n\n\(headline)\n"
        if !byPlatform.isEmpty { s += "\n## By app\n" + byPlatform.map { "- \($0.platform.displayName): \($0.count)" }.joined(separator: "\n") + "\n" }
        if !priority.isEmpty {
            s += "\n## Priority\n" + priority.prefix(10).map { "- **\($0.title)**" + (hideText ? "" : ": \(oneLine($0.body))") }.joined(separator: "\n") + "\n"
        }
        if !awaiting.isEmpty {
            s += "\n## Waiting for a reply\n" + awaiting.map { "- [ ] \($0.name) (\($0.platform.displayName))" + (hideText ? "" : ": \(oneLine($0.lastText))") }.joined(separator: "\n") + "\n"
        }
        if !topSenders.isEmpty { s += "\n## Most active\n" + topSenders.map { "- \($0.name): \($0.count)" }.joined(separator: "\n") + "\n" }
        if let h = busiestHour { s += "\nBusiest hour: \(String(format: "%02d:00", h))\n" }
        return s
    }

    /// Plain text given to an on-device language model to write a short summary.
    public func modelPrompt(maxMessages: Int = 60, items: [InboxItem]) -> String {
        let lines = items.suffix(maxMessages).map { "[\($0.platform.displayName)] \($0.title): \(oneLine($0.body))" }
        return "Summarise today's messages for the user in 3 to 5 short bullet points. Mention who is waiting for a reply and anything urgent. Don't invent facts.\n\n" + lines.joined(separator: "\n")
    }

    private func oneLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > 140 ? String(t.prefix(140)) + "…" : t
    }
}
