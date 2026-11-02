import Foundation

/// Productivity category for screen-time reporting (spec §2.3).
public enum UsageCategory: String, Codable, CaseIterable, Sendable {
    case productive, neutral, distracting
}

/// Local foreground-time log, one bucket per calendar day. Nothing leaves the Mac.
public struct UsageLog: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    /// "yyyy-MM-dd" → bundle id → seconds
    public var days: [String: [String: Double]] = [:]
    /// bundle id → display name
    public var names: [String: String] = [:]
    /// bundle id → category (user-assigned)
    public var categories: [String: UsageCategory] = [:]
    /// bundle id → number of activations
    public var activations: [String: Int] = [:]
    public var retentionDays = 30

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds foreground time, splitting intervals that cross midnight.
    public mutating func record(_ bundleId: String, name: String?, from start: Date, to end: Date,
                                calendar: Calendar = .current) {
        guard end > start else { return }
        if let name { names[bundleId] = name }
        var cursor = start
        while cursor < end {
            let nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: cursor)!)
            let sliceEnd = min(end, nextMidnight)
            days[Self.dayKey(cursor, calendar: calendar), default: [:]][bundleId, default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
    }

    public mutating func recordActivation(_ bundleId: String) { activations[bundleId, default: 0] += 1 }

    /// Apps by time for a day, highest first.
    public func top(on date: Date, limit: Int = 10, calendar: Calendar = .current) -> [(bundleId: String, seconds: Double)] {
        (days[Self.dayKey(date, calendar: calendar)] ?? [:])
            .map { (bundleId: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { $0 }
    }

    public func total(on date: Date, calendar: Calendar = .current) -> Double {
        (days[Self.dayKey(date, calendar: calendar)] ?? [:]).values.reduce(0, +)
    }

    /// Seconds per category for a day (uncategorised apps count as neutral).
    public func byCategory(on date: Date, calendar: Calendar = .current) -> [UsageCategory: Double] {
        var out: [UsageCategory: Double] = [:]
        for (app, secs) in days[Self.dayKey(date, calendar: calendar)] ?? [:] {
            out[categories[app] ?? .neutral, default: 0] += secs
        }
        return out
    }

    /// Daily totals for the last `count` days, oldest first.
    public func dailyTotals(endingOn date: Date, count: Int = 7, calendar: Calendar = .current) -> [(day: Date, seconds: Double)] {
        (0..<count).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date)) else { return nil }
            return (d, total(on: d, calendar: calendar))
        }
    }

    public mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoffKey = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }
}
