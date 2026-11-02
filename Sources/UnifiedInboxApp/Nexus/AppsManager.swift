import AppKit
import Charts
import Combine
import Darwin
import NexusCore
import SwiftUI

// MARK: - Running apps (spec §2.1)

struct RunningAppInfo: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleId: String?
    let bundleURL: URL?
    let isHidden: Bool
    let isActive: Bool
    let launchDate: Date?
    var cpu: Double?          // 0…1 of one core
    var memoryBytes: UInt64?
}

@MainActor
final class AppsManager: ObservableObject {
    @Published private(set) var apps: [RunningAppInfo] = []
    @Published private(set) var usage: UsageLog
    @Published var sort: Sort = .memory
    @Published var pendingForceQuit: RunningAppInfo?

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", cpu = "CPU", memory = "Memory"
        var id: String { rawValue }
    }

    private let store = JSONFileStore<UsageLog>(url: JSONFileStore<UsageLog>.defaultURL("usage"))
    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?
    private var idleTimer: Timer?
    private var lastCPU: [pid_t: (time: UInt64, at: Date)] = [:]
    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    // Screen-time state
    private var current: (bundleId: String, name: String?, since: Date)?
    private var isIdle = false
    let idleThreshold: TimeInterval = 5 * 60

    init() {
        usage = store.load() ?? UsageLog()
        usage.prune()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier, name = app?.localizedName
            Task { @MainActor in self?.activated(bundleId: id, name: name) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closeInterval(at: Date()); self?.isIdle = true }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeFromIdle() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeInterval(at: Date()); self?.saveUsage() }
        })
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier {
            current = (id, front.localizedName, Date())
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
        refresh()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Running list

    /// Sampling CPU/memory only while the Apps page is visible.
    func startSampling() {
        refresh()
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    func refresh() {
        let now = Date()
        var list: [RunningAppInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            var info = RunningAppInfo(id: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "App",
                                      bundleId: app.bundleIdentifier, bundleURL: app.bundleURL, isHidden: app.isHidden,
                                      isActive: app.isActive, launchDate: app.launchDate)
            if let r = Self.rusage(app.processIdentifier) {
                info.memoryBytes = r.footprint
                if let prev = lastCPU[app.processIdentifier] {
                    let dt = now.timeIntervalSince(prev.at)
                    if dt > 0, r.cpuNanos >= prev.time { info.cpu = Double(r.cpuNanos - prev.time) / 1e9 / dt }
                }
                lastCPU[app.processIdentifier] = (r.cpuNanos, now)
            }
            list.append(info)
        }
        apps = sorted(list)
    }

    private func sorted(_ list: [RunningAppInfo]) -> [RunningAppInfo] {
        switch sort {
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cpu: return list.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }
        case .memory: return list.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
        }
    }

    /// Public libproc call: CPU time (ns) and physical footprint (bytes). nil if the process isn't visible.
    private static func rusage(_ pid: pid_t) -> (cpuNanos: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        let nanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return (nanos, info.ri_phys_footprint)
    }

    private func running(_ info: RunningAppInfo) -> NSRunningApplication? { NSRunningApplication(processIdentifier: info.id) }

    func quit(_ info: RunningAppInfo) { running(info)?.terminate() }

    /// Always confirmed in the UI first (spec: force quit only with warning).
    func forceQuit(_ info: RunningAppInfo) { running(info)?.forceTerminate() }

    func toggleHidden(_ info: RunningAppInfo) {
        guard let app = running(info) else { return }
        _ = app.isHidden ? app.unhide() : app.hide()
    }

    func activate(_ info: RunningAppInfo) { running(info)?.activate(options: []) }  // macOS 13-compatible

    /// Quit, wait for exit (up to 10 s), relaunch.
    func restart(_ info: RunningAppInfo) {
        guard let app = running(info), let url = app.bundleURL else { return }
        app.terminate()
        Task { @MainActor in
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard app.isTerminated else { return }
            // Completion-handler form: inside a Task the plain call resolves to the async/throwing overload.
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
    }

    func quitAll(except keep: Set<String> = []) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !keep.contains(app.bundleIdentifier ?? "") else { continue }
            app.terminate()
        }
    }

    // MARK: Screen time (spec §2.3)

    private func activated(bundleId: String?, name: String?) {
        let now = Date()
        closeInterval(at: now)
        guard let bundleId else { current = nil; return }
        current = (bundleId, name, now)
        usage.recordActivation(bundleId)
        isIdle = false
    }

    private func closeInterval(at end: Date) {
        guard let c = current, !isIdle else { return }
        usage.record(c.bundleId, name: c.name, from: c.since, to: end)
        current = (c.bundleId, c.name, end)
    }

    private func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= idleThreshold, !isIdle {
            closeInterval(at: Date().addingTimeInterval(-idle))
            isIdle = true
        } else if idle < idleThreshold, isIdle {
            resumeFromIdle()
        } else if !isIdle {
            closeInterval(at: Date())   // checkpoint every 30 s so a crash loses little
        }
        saveUsage()
    }

    private func resumeFromIdle() {
        isIdle = false
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier {
            current = (id, front.localizedName, Date())
        }
    }

    func setCategory(_ bundleId: String, _ category: UsageCategory) {
        usage.categories[bundleId] = category
        saveUsage()
    }

    func resetUsage() {
        usage = UsageLog()
        saveUsage()
    }

    private func saveUsage() {
        usage.prune()
        try? store.save(usage)
    }

    func displayName(_ bundleId: String) -> String { usage.names[bundleId] ?? bundleId }

    func icon(_ bundleId: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Views

struct AppsView: View {
    @EnvironmentObject private var apps: AppsManager
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                Text("Running").tag(0)
                Text("Screen Time").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if tab == 0 { RunningAppsList() } else { ScreenTimeView() }
        }
        .padding(28)
        .navigationTitle("Apps")
        .onAppear { apps.startSampling() }
        .onDisappear { apps.stopSampling() }
        .alert("Force quit \(apps.pendingForceQuit?.name ?? "")?",
               isPresented: Binding(get: { apps.pendingForceQuit != nil }, set: { if !$0 { apps.pendingForceQuit = nil } })) {
            Button("Force Quit", role: .destructive) {
                if let a = apps.pendingForceQuit { apps.forceQuit(a) }
                apps.pendingForceQuit = nil
            }
            Button("Cancel", role: .cancel) { apps.pendingForceQuit = nil }
        } message: {
            Text("Unsaved changes in this app will be lost. Try Quit first.")
        }
    }
}

struct RunningAppsList: View {
    @EnvironmentObject private var apps: AppsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(apps.apps.count) apps running").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Picker("Sort", selection: $apps.sort) {
                    ForEach(AppsManager.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                .onChange(of: apps.sort) { _ in apps.refresh() }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(apps.apps) { app in
                        RunningAppRow(app: app)
                        if app.id != apps.apps.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
            }
            .glassCard()
            Text("CPU is a share of one core (100% = one core busy). Memory is the app's footprint, as in Activity Monitor.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct RunningAppRow: View {
    @EnvironmentObject private var apps: AppsManager
    let app: RunningAppInfo
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 13)).foregroundStyle(app.isHidden ? Theme.secondary : Theme.primary)
                    if app.isActive { Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Frontmost app") }
                    if app.isHidden { Text("hidden").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                }
                Text(app.launchDate.map { "running " + MetricFormat.duration(Date().timeIntervalSince($0)) } ?? (app.bundleId ?? ""))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(app.cpu.map { MetricFormat.percent($0) } ?? "—")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .trailing)
                .help("CPU")
            Text(app.memoryBytes.map { MetricFormat.bytes(Double($0)) } ?? "—")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 72, alignment: .trailing)
                .help("Memory footprint")
            HStack(spacing: 0) {
                GlassIconButton(systemImage: app.isHidden ? "eye" : "eye.slash", help: app.isHidden ? "Show" : "Hide") { apps.toggleHidden(app) }
                GlassIconButton(systemImage: "arrow.clockwise", help: "Restart (quit and reopen)") { apps.restart(app) }
                GlassIconButton(systemImage: "xmark.circle", help: "Quit") { apps.quit(app) }
                GlassIconButton(systemImage: "exclamationmark.octagon", help: "Force Quit…") { apps.pendingForceQuit = app }
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { apps.activate(app) }
        .help("Double-click to switch to \(app.name)")
    }
}

struct ScreenTimeView: View {
    @EnvironmentObject private var apps: AppsManager

    var body: some View {
        let today = Date()
        let top = apps.usage.top(on: today, limit: 12)
        let total = apps.usage.total(on: today)
        let cats = apps.usage.byCategory(on: today)
        let week = apps.usage.dailyTotals(endingOn: today, count: 7)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        MetricValue(title: "Today", value: total > 0 ? MetricFormat.duration(total) : nil,
                                    detail: "active time in apps")
                        CategoryBar(cats: cats, total: total)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()

                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Last 7 days")
                        Chart(week, id: \.day) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", d.seconds / 3600))
                                .foregroundStyle(Theme.accent.opacity(0.8))
                                .cornerRadius(3)
                        }
                        .chartYAxis { AxisMarks { v in AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h").font(.system(size: 9)) } } } }
                        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                        .frame(height: 90)
                    }
                    .padding(16).frame(maxWidth: .infinity).glassCard()
                }

                VStack(spacing: 0) {
                    if top.isEmpty {
                        Text("Usage appears here as you switch between apps. Idle time (5+ min without input) isn't counted.")
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(16)
                    }
                    ForEach(top, id: \.bundleId) { entry in
                        UsageRow(bundleId: entry.bundleId, seconds: entry.seconds, maxSeconds: top.first?.seconds ?? 1)
                    }
                }
                .glassCard()
                HStack {
                    Text("Stored only on this Mac for \(apps.usage.retentionDays) days. Right-click an app to mark it productive or distracting.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("Reset") { apps.resetUsage() }.controlSize(.small)
                }
            }
        }
    }
}

private struct CategoryBar: View {
    let cats: [UsageCategory: Double]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(UsageCategory.allCases, id: \.self) { c in
                        let share = total > 0 ? (cats[c] ?? 0) / total : 0
                        if share > 0 {
                            RoundedRectangle(cornerRadius: 3).fill(color(c)).frame(width: max(2, g.size.width * share))
                        }
                    }
                }
            }
            .frame(height: 8)
            .softFill(Theme.fill, cornerRadius: 4)
            HStack(spacing: 12) {
                ForEach(UsageCategory.allCases, id: \.self) { c in
                    HStack(spacing: 4) {
                        Circle().fill(color(c)).frame(width: 6, height: 6)
                        Text("\(c.rawValue.capitalized) \(MetricFormat.duration(cats[c] ?? 0))")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    private func color(_ c: UsageCategory) -> Color {
        switch c {
        case .productive: return .green.opacity(0.8)
        case .neutral: return Theme.accent.opacity(0.7)
        case .distracting: return Theme.warning
        }
    }
}

private struct UsageRow: View {
    @EnvironmentObject private var apps: AppsManager
    let bundleId: String
    let seconds: Double
    let maxSeconds: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: apps.icon(bundleId)).resizable().frame(width: 22, height: 22)
            Text(apps.displayName(bundleId)).font(.system(size: 12)).foregroundStyle(Theme.primary).frame(width: 160, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.55))
                    .frame(width: max(3, g.size.width * seconds / max(maxSeconds, 1)), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Text(MetricFormat.duration(seconds)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                .frame(width: 60, alignment: .trailing)
            if let cat = apps.usage.categories[bundleId] {
                Text(cat.rawValue).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contextMenu {
            ForEach(UsageCategory.allCases, id: \.self) { c in
                Button("Mark \(c.rawValue.capitalized)") { apps.setCategory(bundleId, c) }
            }
        }
        .help("\(apps.displayName(bundleId)): \(MetricFormat.duration(seconds)) today, opened \(apps.usage.activations[bundleId] ?? 0)× in total")
    }
}
