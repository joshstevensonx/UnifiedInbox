import InboxCore
import NexusCore
import SwiftUI

/// Overview: Mac identity, live metric cards, performance chart, inbox summary, widgets and quick actions.
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var widgets: WidgetManager
    @EnvironmentObject private var launcher: LauncherModel
    @EnvironmentObject private var focus: FocusModel

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        let s = monitor.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity

                LazyVGrid(columns: columns, spacing: 14) {
                    MetricCard(title: "CPU", value: s.cpuText,
                               detail: "\(monitor.identity.cpuCount) cores",
                               history: monitor.cpuHistory, historyMax: 1)
                    MetricCard(title: "Memory", value: s.memoryText, detail: s.memoryDetail,
                               history: monitor.memoryHistory, historyMax: 1, tint: .purple.opacity(0.8))
                    MetricCard(title: "Battery", value: s.batteryText, detail: s.batteryDetail) {
                        RingGauge(value: s.batteryLevel, color: .green.opacity(0.85)).frame(width: 34, height: 34)
                    }
                    MetricCard(title: "Network", value: s.networkText, detail: s.networkDetail,
                               history: monitor.downHistory)
                    MetricCard(title: "Storage", value: s.storageText, detail: s.storageDetail) {
                        RingGauge(value: s.storage?.usedFraction).frame(width: 34, height: 34)
                    }
                    MetricCard(title: "Inbox", value: "\(model.totalUnread)",
                               detail: model.priorityUnread > 0 ? "★ \(model.priorityUnread) priority unread" : "unread messages") {
                        Image(systemName: "tray").foregroundStyle(Theme.secondary)
                    }
                    .onTapGesture { model.selectInbox(.unread) }
                    .help("Open unread messages")
                }

                quickActions

                HStack(alignment: .top, spacing: 14) {
                    NowPlayingCard().glassCard().frame(maxWidth: .infinity)
                    focusCard.frame(maxWidth: 320)
                }

                CaptureCard()

                HStack(alignment: .top, spacing: 14) {
                    pinnedApps
                    activeWidgets
                }
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Overview")
        .onAppear { monitor.subscribe() }
        .onDisappear { monitor.unsubscribe() }
    }

    private var identity: some View {
        let id = monitor.identity
        return HStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(Theme.secondary)
                .frame(width: 56, height: 56)
                .glassCard(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("\(id.chip) · \(MetricFormat.bytes(Double(id.physicalMemory))) · \(id.osVersion)")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text("Model \(id.model)\(monitor.snapshot.uptime.map { " · up " + MetricFormat.duration($0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(monitor.isPaused ? Theme.warning : Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text(monitor.isPaused ? "Monitoring paused" : "Live · every \(Int(monitor.interval)) s")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .help(monitor.isPaused ? "Resume from the menu bar or System Monitor" : "Sampling runs off the main thread and slows down when nothing is watching")
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickAction(title: "Launcher", systemImage: "square.grid.2x2", hint: "⌥Space") { model.showLauncher() }
            QuickAction(title: "Search inbox", systemImage: "magnifyingglass", hint: "⌃⌥Space") { model.showQuickLook() }
            QuickAction(title: "Clipboard", systemImage: "doc.on.clipboard", hint: "⌃⌥V") { model.clipboard.togglePanel() }
            QuickAction(title: "Add widget", systemImage: "plus.square.on.square", hint: nil) { model.section = .widgets }
            QuickAction(title: widgets.anyVisible ? "Hide widgets" : "Show widgets",
                        systemImage: widgets.anyVisible ? "eye.slash" : "eye", hint: nil) {
                widgets.showAll(!widgets.anyVisible)
            }
        }
    }

    private var focusCard: some View {
        HStack(spacing: 14) {
            RingGauge(value: focus.timer.phase == .idle ? nil : focus.timer.progress(now: focus.now), lineWidth: 4)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "timer").font(.system(size: 12)).foregroundStyle(Theme.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(focus.menuBarText ?? "\(Int(focus.focusMinutesToday)) min focused today")
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.primary)
                Text("\(focus.openCount) open tasks" + (focus.overdueCount > 0 ? " · \(focus.overdueCount) overdue" : ""))
                    .font(.system(size: 10)).foregroundStyle(focus.overdueCount > 0 ? .red.opacity(0.8) : Theme.tertiary)
            }
            Spacer()
            GlassIconButton(systemImage: focus.timer.phase == .idle ? "play.fill" : (focus.timer.isPaused ? "play.fill" : "pause.fill"),
                            help: focus.timer.phase == .idle ? "Start a focus session" : "Pause / resume") {
                if focus.timer.phase == .idle { focus.start() } else { focus.togglePause() }
            }
        }
        .padding(14)
        .glassCard()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.section = .focus }
        .help("Double-click to open Focus")
    }

    private var pinnedApps: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Pinned apps")
            if launcher.pinned.isEmpty {
                Text("Pin apps in Launcher to keep them here.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(launcher.pinned.prefix(12)) { item in
                        LauncherTile(item: item, compact: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private var activeWidgets: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Active widgets")
            if widgets.widgets.isEmpty {
                Text("No widgets yet.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else {
                ForEach(widgets.widgets) { w in
                    HStack {
                        Image(systemName: w.kind.symbolName).frame(width: 18).foregroundStyle(Theme.secondary)
                        Text(w.kind.title).font(.system(size: 12)).foregroundStyle(Theme.primary)
                        Spacer()
                        Toggle("", isOn: Binding(get: { w.isVisible }, set: { widgets.setVisible(w.id, $0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            .help(w.isVisible ? "Hide this widget" : "Show this widget")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 280, alignment: .topLeading)
        .glassCard()
    }
}

struct QuickAction: View {
    let title: String
    let systemImage: String
    let hint: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(.system(size: 12, weight: .medium))
                if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
            }
            .foregroundStyle(hovering ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
