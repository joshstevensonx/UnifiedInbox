import Foundation

/// Opt-in performance alerts (NEXUS §5.10, feature spec §4.4).
public enum ThresholdKind: String, Codable, CaseIterable, Sendable {
    case cpu, memory, battery, disk

    public var title: String {
        switch self {
        case .cpu: return "High CPU"
        case .memory: return "Memory pressure"
        case .battery: return "Low battery"
        case .disk: return "Low disk space"
        }
    }
}

public struct ThresholdSettings: Codable, Equatable, Sendable {
    public var enabled: Set<ThresholdKind> = []
    /// CPU above this fraction for `cpuSustainSeconds`.
    public var cpuLimit: Double = 0.9
    public var cpuSustainSeconds: Double = 60
    /// Alert at `.warning` or only `.critical`.
    public var memoryCriticalOnly = false
    public var memorySustainSeconds: Double = 30
    public var batteryLimit: Double = 0.15
    public var diskFreeLimitBytes: Int64 = 10_000_000_000
    /// Minimum gap between two alerts of the same kind.
    public var cooldownMinutes: Double = 30

    public init() {}
}

/// Debounced evaluation: a condition must hold for its sustain time, fires once,
/// and can fire again only after it has cleared *and* the cooldown has passed.
public struct ThresholdEvaluator: Sendable {
    private var breachedSince: [ThresholdKind: Date] = [:]
    private var active: Set<ThresholdKind> = []
    private var lastFired: [ThresholdKind: Date] = [:]

    public init() {}

    public struct Alert: Equatable, Sendable {
        public var kind: ThresholdKind
        public var message: String
    }

    public mutating func evaluate(_ s: SystemSnapshot, settings: ThresholdSettings, now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        for kind in ThresholdKind.allCases {
            guard settings.enabled.contains(kind) else {
                breachedSince[kind] = nil; active.remove(kind); continue
            }
            guard let (breached, sustain, message) = check(kind, s, settings) else { continue } // metric unavailable: no change
            if !breached {
                breachedSince[kind] = nil
                active.remove(kind)
                continue
            }
            let since = breachedSince[kind] ?? now
            breachedSince[kind] = since
            guard !active.contains(kind), now.timeIntervalSince(since) >= sustain else { continue }
            if let last = lastFired[kind], now.timeIntervalSince(last) < settings.cooldownMinutes * 60 { continue }
            active.insert(kind)
            lastFired[kind] = now
            alerts.append(Alert(kind: kind, message: message))
        }
        return alerts
    }

    private func check(_ kind: ThresholdKind, _ s: SystemSnapshot, _ t: ThresholdSettings) -> (Bool, Double, String)? {
        switch kind {
        case .cpu:
            guard let c = s.cpu else { return nil }
            return (c.total >= t.cpuLimit, t.cpuSustainSeconds,
                    "CPU has been above \(MetricFormat.percent(t.cpuLimit)) for \(Int(t.cpuSustainSeconds)) s (now \(MetricFormat.percent(c.total))).")
        case .memory:
            guard let m = s.memory, m.pressure != .unknown else { return nil }
            let breached = t.memoryCriticalOnly ? m.pressure == .critical : (m.pressure == .warning || m.pressure == .critical)
            return (breached, t.memorySustainSeconds,
                    "Memory pressure is \(m.pressure.rawValue). \(MetricFormat.bytes(Double(m.usedBytes))) of \(MetricFormat.bytes(Double(m.totalBytes))) used.")
        case .battery:
            guard case .reading(let b)? = s.battery else { return nil }
            return (!b.onACPower && b.level <= t.batteryLimit, 0,
                    "Battery at \(MetricFormat.percent(b.level))" + (b.minutesRemaining.map { ", about \(MetricFormat.duration(Double($0) * 60)) left." } ?? "."))
        case .disk:
            guard let d = s.storage else { return nil }
            return (d.availableBytes <= t.diskFreeLimitBytes, 0,
                    "Only \(MetricFormat.bytes(Double(d.availableBytes))) free on the startup disk.")
        }
    }
}
