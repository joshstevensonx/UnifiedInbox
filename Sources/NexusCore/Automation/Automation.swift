import Foundation

// MARK: - Automation rules (task 20): "when X happens, do Y", with cooldown and a run log.

public enum AutomationTrigger: Codable, Equatable, Sendable {
    /// A captured message. Empty strings mean "any".
    case newMessage(platform: String, senderContains: String, textContains: String, priorityOnly: Bool)
    case appLaunched(bundleId: String)
    case appQuit(bundleId: String)
    /// Every chosen weekday (1 = Sunday … 7 = Saturday; empty = every day) at "HH:mm".
    case timeOfDay(time: String, weekdays: Set<Int>)
    /// On battery power and at or below this level (0…1).
    case batteryBelow(level: Double)
    /// CPU at or above this fraction (0…1).
    case cpuAbove(level: Double)
    case focusStarted
    case focusEnded

    public var summary: String {
        switch self {
        case .newMessage(let p, let s, let t, let prio):
            var parts = [prio ? "New priority message" : "New message"]
            if !p.isEmpty { parts.append("in \(p)") }
            if !s.isEmpty { parts.append("from “\(s)”") }
            if !t.isEmpty { parts.append("containing “\(t)”") }
            return parts.joined(separator: " ")
        case .appLaunched(let b): return "\(b.isEmpty ? "Any app" : b) opens"
        case .appQuit(let b): return "\(b.isEmpty ? "Any app" : b) quits"
        case .timeOfDay(let t, let days):
            if days.isEmpty || days.count == 7 { return "Every day at \(t)" }
            let symbols = Calendar.current.shortWeekdaySymbols
            return days.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }.joined(separator: ", ") + " at \(t)"
        case .batteryBelow(let l): return "Battery at or below \(Int((l * 100).rounded()))%"
        case .cpuAbove(let l): return "CPU at or above \(Int((l * 100).rounded()))%"
        case .focusStarted: return "Focus session starts"
        case .focusEnded: return "Focus session ends"
        }
    }
}

public enum AutomationAction: Codable, Equatable, Sendable {
    case notify(title: String, body: String)
    case openApp(bundleId: String)
    case quitApp(bundleId: String)
    case hideApp(bundleId: String)
    case openURL(String)
    case switchWorkspace(name: String)
    case startFocus
    case stopFocus
    /// Runs a shortcut from the Shortcuts app by name (`/usr/bin/shortcuts run`).
    case runShortcut(name: String)
    case playSound(name: String)
    case copyText(String)
    case addTask(title: String)
    case appendToDailyNote(text: String)
    case setPrivacyMode(Bool)
    /// Any ⌥Space palette command by id.
    case paletteCommand(id: String)

    public var summary: String {
        switch self {
        case .notify(let t, _): return "Notify “\(t)”"
        case .openApp(let b): return "Open \(b)"
        case .quitApp(let b): return "Quit \(b)"
        case .hideApp(let b): return "Hide \(b)"
        case .openURL(let u): return "Open \(u)"
        case .switchWorkspace(let n): return "Switch to workspace \(n)"
        case .startFocus: return "Start focus session"
        case .stopFocus: return "Stop focus session"
        case .runShortcut(let n): return "Run shortcut “\(n)”"
        case .playSound(let n): return "Play sound \(n)"
        case .copyText(let t): return "Copy “\(t.prefix(30))”"
        case .addTask(let t): return "Add task “\(t)”"
        case .appendToDailyNote(let t): return "Add “\(t.prefix(30))” to today's note"
        case .setPrivacyMode(let on): return "Privacy mode \(on ? "on" : "off")"
        case .paletteCommand(let id): return "Run command \(id)"
        }
    }

    /// The same action with `{placeholders}` filled in.
    public func filled(_ values: [String: String]) -> AutomationAction {
        let f = { (s: String) in AutomationTemplate.fill(s, values) }
        switch self {
        case .notify(let t, let b): return .notify(title: f(t), body: f(b))
        case .openURL(let u): return .openURL(AutomationTemplate.fill(u, values, urlEncode: true))
        case .copyText(let t): return .copyText(f(t))
        case .addTask(let t): return .addTask(title: f(t))
        case .appendToDailyNote(let t): return .appendToDailyNote(text: f(t))
        default: return self
        }
    }
}

public enum AutomationTemplate {
    /// Replaces `{key}` with values; unknown placeholders are left as typed.
    public static func fill(_ s: String, _ values: [String: String], urlEncode: Bool = false) -> String {
        var out = s
        for (k, v) in values {
            let value = urlEncode ? (v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v) : v
            out = out.replacingOccurrences(of: "{\(k)}", with: value)
        }
        return out
    }
}

public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var actions: [AutomationAction]
    /// Minimum minutes between two runs of this rule.
    public var cooldownMinutes: Double

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, trigger: AutomationTrigger,
                actions: [AutomationAction], cooldownMinutes: Double = 0) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger
        self.actions = actions; self.cooldownMinutes = cooldownMinutes
    }
}

/// Something that happened, fed to the engine by the app.
public enum AutomationEvent: Sendable {
    case message(platform: String, sender: String, text: String, isPriority: Bool)
    case appLaunched(bundleId: String, name: String)
    case appQuit(bundleId: String, name: String)
    /// Periodic clock tick (the app sends one at least every minute).
    case tick
    case battery(level: Double, onAC: Bool)
    case cpu(Double)
    case focusStarted
    case focusEnded

    /// Values for `{placeholders}` in actions.
    public func values(now: Date) -> [String: String] {
        var v = ["time": DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short),
                 "date": DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .none)]
        switch self {
        case .message(let p, let s, let t, _): v["platform"] = p; v["sender"] = s; v["text"] = t
        case .appLaunched(let b, let n), .appQuit(let b, let n): v["app"] = n; v["bundleId"] = b
        case .battery(let l, _): v["battery"] = "\(Int((l * 100).rounded()))%"
        case .cpu(let c): v["cpu"] = "\(Int((c * 100).rounded()))%"
        case .tick, .focusStarted, .focusEnded: break
        }
        return v
    }
}

public struct AutomationLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var ruleId: UUID
    public var ruleName: String
    public var trigger: String
    public var results: [String]
    public var success: Bool
    public init(id: UUID = UUID(), date: Date, ruleId: UUID, ruleName: String, trigger: String, results: [String], success: Bool) {
        self.id = id; self.date = date; self.ruleId = ruleId; self.ruleName = ruleName
        self.trigger = trigger; self.results = results; self.success = success
    }
}

public struct AutomationConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var rules: [AutomationRule] = []
    public var log: [AutomationLogEntry] = []
    public var lastRun: [UUID: Date] = [:]
    public var logLimit = 200
    public init() {}

    public mutating func record(_ entry: AutomationLogEntry) {
        log.insert(entry, at: 0)
        if log.count > logLimit { log.removeLast(log.count - logLimit) }
        lastRun[entry.ruleId] = entry.date
    }
}

public enum AutomationEngine {
    /// Whether `trigger` fires for `event`. Level triggers (battery, CPU) fire on every matching sample;
    /// the rule's cooldown (or `edgeState`) keeps them from repeating.
    public static func matches(_ trigger: AutomationTrigger, _ event: AutomationEvent, now: Date, calendar: Calendar = .current) -> Bool {
        switch (trigger, event) {
        case let (.newMessage(p, s, t, prio), .message(platform, sender, text, isPriority)):
            if prio && !isPriority { return false }
            if !p.isEmpty && p.lowercased() != platform.lowercased() { return false }
            if !s.isEmpty && !sender.localizedCaseInsensitiveContains(s) { return false }
            if !t.isEmpty && !text.localizedCaseInsensitiveContains(t) && !sender.localizedCaseInsensitiveContains(t) { return false }
            return true
        case let (.appLaunched(want), .appLaunched(got, name)), let (.appQuit(want), .appQuit(got, name)):
            return want.isEmpty || want.lowercased() == got.lowercased() || want.lowercased() == name.lowercased()
        case let (.timeOfDay(time, days), .tick):
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return false }
            let c = calendar.dateComponents([.hour, .minute, .weekday], from: now)
            guard days.isEmpty || days.contains(c.weekday ?? 0) else { return false }
            return c.hour == parts[0] && c.minute == parts[1]
        case let (.batteryBelow(level), .battery(l, onAC)):
            return !onAC && l <= level
        case let (.cpuAbove(level), .cpu(c)):
            return c >= level
        case (.focusStarted, .focusStarted), (.focusEnded, .focusEnded):
            return true
        default:
            return false
        }
    }

    /// Enabled rules that should run now: trigger matches and the cooldown has passed. A time-of-day rule
    /// runs at most once per minute; battery / CPU rules at least every 10 minutes unless their cooldown is longer.
    public static func due(_ cfg: AutomationConfig, for event: AutomationEvent, now: Date = Date(), calendar: Calendar = .current) -> [AutomationRule] {
        cfg.rules.filter { r in
            guard r.enabled, matches(r.trigger, event, now: now, calendar: calendar) else { return false }
            var minGap = r.cooldownMinutes * 60
            switch r.trigger {
            case .timeOfDay: minGap = max(minGap, 61)
            case .batteryBelow, .cpuAbove: minGap = max(minGap, 600)
            default: break
            }
            if let last = cfg.lastRun[r.id], now.timeIntervalSince(last) < minGap { return false }
            return true
        }
    }

    public static let examples: [AutomationRule] = [
        AutomationRule(name: "Morning: open mail and chat", enabled: false,
                       trigger: .timeOfDay(time: "09:00", weekdays: [2, 3, 4, 5, 6]),
                       actions: [.openApp(bundleId: "com.microsoft.Outlook"), .openApp(bundleId: "com.microsoft.teams2")]),
        AutomationRule(name: "Priority message → task", enabled: false,
                       trigger: .newMessage(platform: "", senderContains: "", textContains: "", priorityOnly: true),
                       actions: [.addTask(title: "Reply to {sender}")], cooldownMinutes: 1),
        AutomationRule(name: "Low battery: stop focus distractions", enabled: false,
                       trigger: .batteryBelow(level: 0.2),
                       actions: [.notify(title: "Battery {battery}", body: "Plug in soon.")], cooldownMinutes: 60),
        AutomationRule(name: "Focus: hide chat apps", enabled: false, trigger: .focusStarted,
                       actions: [.hideApp(bundleId: "com.tinyspeck.slackmacgap"), .setPrivacyMode(true)]),
    ]
}
