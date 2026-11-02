import Foundation

/// Preset snooze durations. `wakeDate(from:)` is pure so it's easy to test.
public enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case threeHours
    case thisEvening
    case tomorrowMorning
    case nextWeek

    public var id: String { rawValue }

    /// Hour of day used for "morning" and "evening".
    public static let morningHour = 8
    public static let eveningHour = 18

    public var title: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .threeHours: return "3 Hours"
        case .thisEvening: return "This Evening"
        case .tomorrowMorning: return "Tomorrow Morning"
        case .nextWeek: return "Next Week"
        }
    }

    public func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3_600)
        case .threeHours:
            return now.addingTimeInterval(3 * 3_600)
        case .thisEvening:
            let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: now)!
            // Already evening → tomorrow evening.
            return evening > now ? evening : calendar.date(byAdding: .day, value: 1, to: evening)!
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: tomorrow)!
        case .nextWeek:
            // Next Monday morning (always at least one day ahead).
            var comps = DateComponents()
            comps.weekday = 2
            comps.hour = Self.morningHour
            comps.minute = 0
            return calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(86_400 - 1),
                                     matching: comps, matchingPolicy: .nextTime)!
        }
    }
}
