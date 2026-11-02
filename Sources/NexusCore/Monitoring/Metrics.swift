import Foundation

// MARK: - Readings
// Every metric is optional at the snapshot level: `nil` = not sampled yet / unavailable on this Mac.
// Never substitute 0 for a missing value (spec §5.3 / §11).

public struct CPUReading: Equatable, Sendable {
    /// 0...1
    public var total: Double
    public var user: Double
    public var system: Double
    public init(total: Double, user: Double, system: Double) {
        self.total = total; self.user = user; self.system = system
    }
}

public enum MemoryPressure: String, Sendable {
    case normal, warning, critical, unknown

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public init(sysctlLevel: Int32?) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var pressure: MemoryPressure
    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    public init(totalBytes: UInt64, usedBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, pressure: MemoryPressure) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes; self.pressure = pressure
    }
}

public enum BatteryState: Equatable, Sendable {
    case reading(BatteryReading)
    /// Desktop Macs: explicitly "no battery", not 0 %.
    case noBattery
}

public struct BatteryReading: Equatable, Sendable {
    /// 0...1
    public var level: Double
    public var isCharging: Bool
    public var onACPower: Bool
    /// Minutes to empty (on battery) or to full (charging), when macOS provides an estimate.
    public var minutesRemaining: Int?
    public init(level: Double, isCharging: Bool, onACPower: Bool, minutesRemaining: Int?) {
        self.level = level; self.isCharging = isCharging; self.onACPower = onACPower; self.minutesRemaining = minutesRemaining
    }
}

public struct NetworkReading: Equatable, Sendable {
    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double
    public init(down: Double, up: Double) { downBytesPerSecond = down; upBytesPerSecond = up }
}

public struct StorageReading: Equatable, Sendable {
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(totalBytes - availableBytes) / Double(totalBytes) }
    public init(totalBytes: Int64, availableBytes: Int64) { self.totalBytes = totalBytes; self.availableBytes = availableBytes }
}

public struct MacIdentity: Equatable, Sendable {
    public var name: String
    public var model: String
    public var chip: String
    public var osVersion: String
    public var physicalMemory: UInt64
    public var cpuCount: Int
    public init(name: String, model: String, chip: String, osVersion: String, physicalMemory: UInt64, cpuCount: Int) {
        self.name = name; self.model = model; self.chip = chip; self.osVersion = osVersion
        self.physicalMemory = physicalMemory; self.cpuCount = cpuCount
    }
}

/// Immutable snapshot published to every consumer (dashboard, menu bar, widgets).
public struct SystemSnapshot: Equatable, Sendable {
    public var timestamp: Date
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var battery: BatteryState?
    public var network: NetworkReading?
    public var storage: StorageReading?
    public var uptime: TimeInterval?

    public init(timestamp: Date = Date(), cpu: CPUReading? = nil, memory: MemoryReading? = nil,
                battery: BatteryState? = nil, network: NetworkReading? = nil,
                storage: StorageReading? = nil, uptime: TimeInterval? = nil) {
        self.timestamp = timestamp; self.cpu = cpu; self.memory = memory; self.battery = battery
        self.network = network; self.storage = storage; self.uptime = uptime
    }

    /// Older than 3 sampling periods → shown as stale.
    public func isStale(now: Date = Date(), interval: TimeInterval = 2) -> Bool {
        now.timeIntervalSince(timestamp) > interval * 3
    }
}

// MARK: - Calculations (pure, unit-tested)

/// Cumulative CPU ticks from `host_statistics(HOST_CPU_LOAD_INFO)`.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    var total: UInt64 { user + system + idle + nice }

    /// Usage between two samples. Returns nil when counters went backwards (reset) or no time passed.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> CPUReading? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
        let total = Double(b.total - a.total)
        guard total > 0 else { return nil }
        let user = Double((b.user - a.user) + (b.nice - a.nice)) / total
        let system = Double(b.system - a.system) / total
        return CPUReading(total: min(max(user + system, 0), 1), user: user, system: system)
    }
}

/// Byte counters summed over interfaces.
public struct NetworkCounters: Equatable, Sendable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var timestamp: Date
    public init(bytesIn: UInt64, bytesOut: UInt64, timestamp: Date) {
        self.bytesIn = bytesIn; self.bytesOut = bytesOut; self.timestamp = timestamp
    }

    /// `bytes_per_second = (current - previous) / elapsed`. Negative deltas (counter reset,
    /// interface change, 32-bit wrap) return nil for that sample instead of a bogus spike.
    public static func throughput(from a: NetworkCounters, to b: NetworkCounters) -> NetworkReading? {
        let elapsed = b.timestamp.timeIntervalSince(a.timestamp)
        guard elapsed > 0.2, b.bytesIn >= a.bytesIn, b.bytesOut >= a.bytesOut else { return nil }
        return NetworkReading(down: Double(b.bytesIn - a.bytesIn) / elapsed,
                              up: Double(b.bytesOut - a.bytesOut) / elapsed)
    }

    /// Interfaces counted for throughput: physical / cellular / bridge. Excludes loopback, tunnels
    /// (would double-count VPN traffic) and Apple-internal links.
    public static func isCountedInterface(_ name: String) -> Bool {
        let excluded = ["lo", "gif", "stf", "awdl", "llw", "utun", "anpi", "ap", "ipsec"]
        return !excluded.contains { name.hasPrefix($0) }
    }
}

/// Fixed-capacity history buffer (bounded memory, spec §7).
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    /// Oldest → newest.
    public var elements: [Element] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
    public var last: Element? { elements.last }
    public mutating func removeAll() { storage.removeAll(keepingCapacity: true); head = 0 }
}

/// A timestamped value for charts.
public struct MetricPoint: Identifiable, Equatable, Sendable {
    public var id: Date { time }
    public var time: Date
    public var value: Double
    public init(time: Date, value: Double) { self.time = time; self.value = value }
}

// MARK: - Formatting

public enum MetricFormat {
    public static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    public static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.1f" : "%.0f", v) + " " + units[i]
    }

    public static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }

    public static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}
