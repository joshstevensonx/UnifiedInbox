import Foundation

// MARK: - Process manager (task 22): pure model; sampling with libproc happens in the app.

public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String?
    public var uid: UInt32
    public var user: String
    public var threads: Int?
    /// Physical footprint in bytes (nil when the process belongs to another user and can't be inspected).
    public var memory: UInt64?
    /// Total CPU time used so far, in nanoseconds.
    public var cpuNanos: UInt64?
    public var started: Date?
    /// Fraction of one core over the last interval (computed by `ProcessTable`).
    public var cpu: Double?

    public init(pid: Int32, ppid: Int32, name: String, path: String? = nil, uid: UInt32 = 0, user: String = "",
                threads: Int? = nil, memory: UInt64? = nil, cpuNanos: UInt64? = nil, started: Date? = nil, cpu: Double? = nil) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.uid = uid; self.user = user
        self.threads = threads; self.memory = memory; self.cpuNanos = cpuNanos; self.started = started; self.cpu = cpu
    }
}

public enum ProcessSort: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU", memory = "Memory", name = "Name", pid = "PID"
    public var id: String { rawValue }
}

/// Keeps the previous sample to turn cumulative CPU time into a rate.
public struct ProcessTable: Sendable {
    private var previous: [Int32: (nanos: UInt64, at: Date, started: Date?)] = [:]
    public init() {}

    /// Fills `cpu` from the change in CPU time since the last update. A reused pid (different start time)
    /// or a counter going backwards yields nil for that sample, not a spike.
    public mutating func update(_ samples: [ProcessSample], at now: Date) -> [ProcessSample] {
        var next: [Int32: (UInt64, Date, Date?)] = [:]
        let out = samples.map { s -> ProcessSample in
            var s = s
            if let n = s.cpuNanos {
                if let p = previous[s.pid], p.started == s.started, n >= p.nanos {
                    let dt = now.timeIntervalSince(p.at)
                    s.cpu = dt > 0 ? Double(n - p.nanos) / 1e9 / dt : nil
                }
                next[s.pid] = (n, now, s.started)
            }
            return s
        }
        previous = next.mapValues { (nanos: $0.0, at: $0.1, started: $0.2) }
        return out
    }

    public static func sorted(_ list: [ProcessSample], by sort: ProcessSort) -> [ProcessSample] {
        switch sort {
        case .cpu: return list.sorted { ($0.cpu ?? -1, $1.pid) > ($1.cpu ?? -1, $0.pid) }
        case .memory: return list.sorted { ($0.memory ?? 0, $1.pid) > ($1.memory ?? 0, $0.pid) }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: return list.sorted { $0.pid < $1.pid }
        }
    }

    /// Name, pid or path contains `query`; `mineOnly` keeps processes of `uid`.
    public static func filter(_ list: [ProcessSample], query: String, mineOnly: Bool, uid: UInt32) -> [ProcessSample] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return list.filter { p in
            (!mineOnly || p.uid == uid) &&
            (q.isEmpty || p.name.localizedCaseInsensitiveContains(q) || "\(p.pid)" == q || (p.path?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    /// Process tree as (process, depth) rows, children sorted by `sort`. Orphans (parent not listed) are roots.
    public static func tree(_ list: [ProcessSample], sort: ProcessSort) -> [(process: ProcessSample, depth: Int)] {
        let pids = Set(list.map(\.pid))
        let children = Dictionary(grouping: list.filter { $0.ppid != $0.pid && pids.contains($0.ppid) }, by: \.ppid)
        var out: [(ProcessSample, Int)] = []
        var visited = Set<Int32>()
        func walk(_ p: ProcessSample, _ depth: Int) {
            guard visited.insert(p.pid).inserted else { return }
            out.append((p, depth))
            for c in sorted(children[p.pid] ?? [], by: sort) { walk(c, depth + 1) }
        }
        for root in sorted(list.filter { !pids.contains($0.ppid) || $0.ppid == $0.pid }, by: sort) { walk(root, 0) }
        return out.map { (process: $0.0, depth: $0.1) }
    }

    /// Sum of a process and all its descendants (e.g. a browser and its helpers).
    public static func groupTotals(_ list: [ProcessSample], root: Int32) -> (cpu: Double, memory: UInt64, count: Int) {
        let children = Dictionary(grouping: list, by: \.ppid)
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var stack = [root], seen = Set<Int32>()
        var cpu = 0.0, mem: UInt64 = 0
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let p = byPid[pid] else { continue }
            cpu += p.cpu ?? 0; mem += p.memory ?? 0
            stack += (children[pid] ?? []).map(\.pid).filter { $0 != pid }
        }
        return (cpu, mem, seen.count)
    }
}

// MARK: - Log viewer: parses `log show --style ndjson` output (public /usr/bin/log tool).

public enum LogLevel: String, CaseIterable, Codable, Identifiable, Comparable, Sendable {
    case debug, info, `default`, error, fault
    public var id: String { rawValue }
    public var title: String { rawValue == "default" ? "Default" : rawValue.capitalized }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }

    public init(messageType: String) {
        switch messageType.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "error": self = .error
        case "fault": self = .fault
        default: self = .default
        }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public var id: Int
    public var date: Date?
    public var level: LogLevel
    public var process: String
    public var pid: Int?
    public var subsystem: String
    public var category: String
    public var message: String
}

public enum LogParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// One JSON object per line; non-JSON lines (headers, "Filtering the log data…") are skipped.
    public static func parse(ndjson text: String, startId: Int = 0) -> [LogEntry] {
        var out: [LogEntry] = []
        var id = startId
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let path = obj["processImagePath"] as? String ?? ""
            let ts = obj["timestamp"] as? String ?? ""
            out.append(LogEntry(
                id: id,
                date: formatter.date(from: ts),
                level: LogLevel(messageType: obj["messageType"] as? String ?? ""),
                process: (path as NSString).lastPathComponent,
                pid: obj["processID"] as? Int,
                subsystem: obj["subsystem"] as? String ?? "",
                category: obj["category"] as? String ?? "",
                message: obj["eventMessage"] as? String ?? ""))
            id += 1
        }
        return out
    }

    /// Arguments for `/usr/bin/log show`. `process` / `subsystem` / `text` are passed through a predicate
    /// with quotes escaped, so user input can't break out of the string literal.
    public static func showArguments(lastMinutes: Int, minLevel: LogLevel, process: String, subsystem: String, text: String) -> [String] {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var preds: [String] = []
        if !process.isEmpty { preds.append("process CONTAINS[c] \"\(esc(process))\"") }
        if !subsystem.isEmpty { preds.append("subsystem CONTAINS[c] \"\(esc(subsystem))\"") }
        if !text.isEmpty { preds.append("eventMessage CONTAINS[c] \"\(esc(text))\"") }
        switch minLevel {
        case .error: preds.append("(messageType == error OR messageType == fault)")
        case .fault: preds.append("messageType == fault")
        default: break
        }
        var args = ["show", "--style", "ndjson", "--last", "\(max(1, lastMinutes))m"]
        if minLevel <= .info { args.append("--info") }
        if minLevel == .debug { args.append("--debug") }
        if !preds.isEmpty { args += ["--predicate", preds.joined(separator: " AND ")] }
        return args
    }
}
