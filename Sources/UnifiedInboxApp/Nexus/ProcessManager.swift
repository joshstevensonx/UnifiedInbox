import AppKit
import Combine
import Darwin
import NexusCore
import SwiftUI

/// Every process on the Mac (public libproc API), sampled off the main thread while the page is open,
/// plus a viewer for the unified log via `/usr/bin/log show`.
@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var processes: [ProcessSample] = []
    @Published var sort: ProcessSort = .cpu
    @Published var query = ""
    @Published var mineOnly = false
    @Published var treeView = false
    @Published var pendingKill: (process: ProcessSample, force: Bool)?
    @Published private(set) var message: String?

    // Logs
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var logLoading = false
    @Published private(set) var logError: String?
    @Published var logMinutes = 5
    @Published var logLevel: LogLevel = .default
    @Published var logProcess = ""
    @Published var logSubsystem = ""
    @Published var logText = ""

    let myUID = getuid()
    private var table = ProcessTable()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "nexus.processes", qos: .utility)
    private var watchers = 0

    var visible: [ProcessSample] {
        ProcessTable.sorted(ProcessTable.filter(processes, query: query, mineOnly: mineOnly, uid: myUID), by: sort)
    }

    var treeRows: [(process: ProcessSample, depth: Int)] {
        ProcessTable.tree(ProcessTable.filter(processes, query: query, mineOnly: mineOnly, uid: myUID), sort: sort)
    }

    var totalCPU: Double { processes.reduce(0) { $0 + ($1.cpu ?? 0) } }

    func start() {
        watchers += 1
        guard watchers == 1 else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        queue.async { [weak self] in
            let list = Self.snapshot()
            let now = Date()
            Task { @MainActor in
                guard let self else { return }
                self.processes = self.table.update(list, at: now)
            }
        }
    }

    // MARK: libproc

    nonisolated static func snapshot() -> [ProcessSample] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var users: [uid_t: String] = [:]
        var out: [ProcessSample] = []
        out.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
                let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                return s
            }
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = pathLen > 0 ? String(cString: pathBuf) : nil
            let uid = bsd.pbi_uid
            if users[uid] == nil { users[uid] = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)" }

            var sample = ProcessSample(
                pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid),
                name: name.isEmpty ? (comm.isEmpty ? (path.map { ($0 as NSString).lastPathComponent } ?? "?") : comm) : name,
                path: path, uid: uid, user: users[uid] ?? "",
                started: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6))

            var task = proc_taskinfo()
            let tsize = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, tsize) == tsize { sample.threads = Int(task.pti_threadnum) }

            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 {
                let ticks = usage.ri_user_time + usage.ri_system_time
                sample.cpuNanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
                sample.memory = usage.ri_phys_footprint
            }
            out.append(sample)
        }
        return out
    }

    // MARK: Actions

    func requestKill(_ p: ProcessSample, force: Bool) { pendingKill = (p, force) }

    func kill(_ p: ProcessSample, force: Bool) {
        let result = Darwin.kill(p.pid, force ? SIGKILL : SIGTERM)
        if result == 0 {
            message = "\(force ? "Force quit" : "Asked to quit"): \(p.name) (\(p.pid))"
        } else {
            message = errno == EPERM ? "Not allowed: \(p.name) belongs to \(p.user). Use Activity Monitor with an admin password."
                                     : "Couldn't stop \(p.name): \(String(cString: strerror(errno)))"
        }
        sample()
    }

    func reveal(_ p: ProcessSample) {
        guard let path = p.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func showLogs(for p: ProcessSample) {
        logProcess = p.name
        loadLogs()
    }

    // MARK: Logs

    func loadLogs() {
        logLoading = true
        logError = nil
        let args = LogParser.showArguments(lastMinutes: logMinutes, minLevel: logLevel, process: logProcess,
                                           subsystem: logSubsystem, text: logText)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            var entries: [LogEntry] = []
            var failure: String?
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                entries = LogParser.parse(ndjson: String(decoding: data, as: UTF8.self))
                if p.terminationStatus != 0, entries.isEmpty {
                    failure = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = error.localizedDescription
            }
            let newest = Array(entries.suffix(5_000).reversed())
            DispatchQueue.main.async {
                self?.logEntries = newest
                self?.logError = failure
                self?.logLoading = false
            }
        }
    }

    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "log \(Date().formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = logEntries.reversed().map { e in
            "\(e.date.map { $0.formatted(.iso8601) } ?? "?") [\(e.level.title)] \(e.process)\(e.pid.map { "[\($0)]" } ?? "") \(e.subsystem) \(e.category): \(e.message)"
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Views

struct ProcessesView: View {
    @EnvironmentObject private var pm: ProcessManager
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text("Processes").tag(0)
                Text("Logs").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            if tab == 0 { ProcessListPanel(tab: $tab) } else { LogPanel() }
        }
        .padding(28)
        .navigationTitle("Processes")
        .onAppear { pm.start() }
        .onDisappear { pm.stop() }
        .confirmationDialog(pm.pendingKill.map { "\($0.force ? "Force quit" : "Quit") \($0.process.name) (\($0.process.pid))?" } ?? "",
                            isPresented: Binding(get: { pm.pendingKill != nil }, set: { if !$0 { pm.pendingKill = nil } })) {
            Button(pm.pendingKill?.force == true ? "Force Quit" : "Quit", role: .destructive) {
                if let k = pm.pendingKill { pm.kill(k.process, force: k.force) }
                pm.pendingKill = nil
            }
        } message: {
            Text(pm.pendingKill?.force == true ? "The process stops immediately; unsaved work is lost." : "Sends a normal quit signal (SIGTERM).")
        }
    }
}

struct ProcessListPanel: View {
    @EnvironmentObject private var pm: ProcessManager
    @Binding var tab: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Name, PID or path", text: $pm.query).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("Sort", selection: $pm.sort) { ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(width: 140)
                Toggle("Only mine", isOn: $pm.mineOnly)
                Toggle("Tree", isOn: $pm.treeView)
                Spacer()
                Text("\(pm.processes.count) processes · \(MetricFormat.percent(pm.totalCPU)) of one core")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 12))
            if let m = pm.message { Text(m).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 60, alignment: .trailing)
                Text("User").frame(width: 90, alignment: .trailing)
                Text("CPU").frame(width: 60, alignment: .trailing)
                Text("Memory").frame(width: 80, alignment: .trailing)
                Text("Threads").frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 12)
            List {
                if pm.treeView {
                    ForEach(pm.treeRows, id: \.process.pid) { row in ProcessRowView(p: row.process, depth: row.depth, tab: $tab) }
                } else {
                    ForEach(pm.visible) { ProcessRowView(p: $0, depth: 0, tab: $tab) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassCard()
            Text("Processes of other users (e.g. root) can be listed but not inspected or stopped without admin rights; their CPU and memory show as —.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}

struct ProcessRowView: View {
    @EnvironmentObject private var pm: ProcessManager
    let p: ProcessSample
    let depth: Int
    @Binding var tab: Int

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let path = p.path, path.contains(".app/") || path.hasSuffix(".app") {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: String(path[..<(path.range(of: ".app")?.upperBound ?? path.endIndex)])))
                        .resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "gearshape").font(.system(size: 10)).foregroundStyle(Theme.tertiary).frame(width: 14)
                }
                Text(p.name).lineLimit(1).foregroundStyle(p.uid == pm.myUID ? Theme.primary : Theme.secondary)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.pid)").frame(width: 60, alignment: .trailing).foregroundStyle(Theme.tertiary)
            Text(p.user).frame(width: 90, alignment: .trailing).foregroundStyle(Theme.tertiary).lineLimit(1)
            Text(p.cpu.map { MetricFormat.percent($0) } ?? "—").frame(width: 60, alignment: .trailing)
                .foregroundStyle((p.cpu ?? 0) > 0.5 ? Theme.warning : Theme.secondary)
            Text(p.memory.map { MetricFormat.bytes(Double($0)) } ?? "—").frame(width: 80, alignment: .trailing).foregroundStyle(Theme.secondary)
            Text(p.threads.map(String.init) ?? "—").frame(width: 60, alignment: .trailing).foregroundStyle(Theme.tertiary)
        }
        .font(.system(size: 12).monospacedDigit())
        .help(p.path ?? p.name)
        .contextMenu {
            Button("Quit") { pm.requestKill(p, force: false) }
            Button("Force Quit…") { pm.requestKill(p, force: true) }
            Divider()
            Button("Show Logs") { pm.showLogs(for: p); tab = 1 }
            Button("Show in Finder") { pm.reveal(p) }.disabled(p.path == nil)
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.pid)", forType: .string)
            }
            let g = ProcessTable.groupTotals(pm.processes, root: p.pid)
            if g.count > 1 {
                Text("With \(g.count - 1) child processes: \(MetricFormat.percent(g.cpu)) CPU, \(MetricFormat.bytes(Double(g.memory)))")
            }
        }
    }
}

struct LogPanel: View {
    @EnvironmentObject private var pm: ProcessManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Last", selection: $pm.logMinutes) {
                    Text("1 min").tag(1); Text("5 min").tag(5); Text("15 min").tag(15); Text("1 hour").tag(60)
                }
                .frame(width: 120)
                Picker("Level", selection: $pm.logLevel) {
                    ForEach(LogLevel.allCases) { Text($0.title + ($0 == .error || $0 == .fault ? " and up" : "")).tag($0) }
                }
                .frame(width: 170)
                TextField("Process", text: $pm.logProcess).frame(width: 120)
                TextField("Subsystem", text: $pm.logSubsystem).frame(width: 130)
                TextField("Message contains", text: $pm.logText, onCommit: { pm.loadLogs() })
                Button("Show") { pm.loadLogs() }.keyboardShortcut(.defaultAction).disabled(pm.logLoading)
                Button("This App") { pm.logProcess = "UnifiedInbox"; pm.loadLogs() }
                    .help("Logs written by Unified Inbox")
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            HStack {
                if pm.logLoading { ProgressView().controlSize(.small); Text("Reading the log…") }
                else { Text("\(pm.logEntries.count) entries, newest first") }
                Spacer()
                Button("Export…") { pm.exportLogs() }.disabled(pm.logEntries.isEmpty)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            if let e = pm.logError {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            List(pm.logEntries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(e.date.map { $0.formatted(date: .omitted, time: .standard) } ?? "")
                            .foregroundStyle(Theme.tertiary)
                        Text(e.level.title).foregroundStyle(color(e.level))
                        Text(e.process + (e.pid.map { "[\($0)]" } ?? "")).foregroundStyle(Theme.secondary)
                        if !e.subsystem.isEmpty { Text("\(e.subsystem)\(e.category.isEmpty ? "" : " · " + e.category)").foregroundStyle(Theme.tertiary).lineLimit(1) }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    Text(e.message).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary)
                        .lineLimit(4).textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassCard()
        }
    }

    private func color(_ l: LogLevel) -> Color {
        switch l {
        case .fault: return .red
        case .error: return Theme.warning
        case .debug: return Theme.tertiary
        default: return Theme.secondary
        }
    }
}
