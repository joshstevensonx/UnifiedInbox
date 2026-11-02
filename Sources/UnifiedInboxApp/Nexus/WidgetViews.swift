import InboxCore
import NexusCore
import SwiftUI

/// Root view inside each floating widget window.
struct WidgetHost: View {
    @EnvironmentObject private var manager: WidgetManager
    @EnvironmentObject private var monitor: SystemMonitor
    let id: UUID
    @State private var hovering = false

    var body: some View {
        if let w = manager.widgets.first(where: { $0.id == id }) {
            ZStack(alignment: .topTrailing) {
                WidgetContent(widget: w)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(GlassBackground(material: .hudWindow).opacity(w.appearance.opacity))
                    .background(Color.black.opacity(0.25 * w.appearance.opacity))
                    .clipShape(RoundedRectangle(cornerRadius: w.appearance.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: w.appearance.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.hairline))

                if hovering {
                    HStack(spacing: 0) {
                        Menu {
                            WidgetMenuItems(widget: w)
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                        .help("Widget options")
                        GlassIconButton(systemImage: "xmark", help: "Remove widget") { manager.remove(w.id) }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contextMenu { WidgetMenuItems(widget: w) }
            .preferredColorScheme(.dark)
            .onAppear { monitor.subscribe() }
            .onDisappear { monitor.unsubscribe() }
        }
    }
}

struct WidgetMenuItems: View {
    @EnvironmentObject private var manager: WidgetManager
    let widget: WidgetInstance

    var body: some View {
        Toggle("Always on Top", isOn: Binding(get: { widget.alwaysOnTop },
                                              set: { manager.setAlwaysOnTop(widget.id, $0) }))
        if [.cpu, .memory, .network].contains(widget.kind) {
            Toggle("Show History", isOn: Binding(get: { widget.appearance.showHistory },
                                                 set: { manager.setShowHistory(widget.id, $0) }))
        }
        Menu("Opacity") {
            ForEach([1.0, 0.85, 0.7, 0.5], id: \.self) { v in
                Button("\(Int(v * 100))%\(abs(widget.appearance.opacity - v) < 0.01 ? " ✓" : "")") {
                    manager.setOpacity(widget.id, v)
                }
            }
        }
        Divider()
        Button("Duplicate") { manager.duplicate(widget.id) }
        Button("Hide") { manager.setVisible(widget.id, false) }
        Button("Remove", role: .destructive) { manager.remove(widget.id) }
    }
}

/// The content for each widget kind. Also used for live previews in the gallery.
struct WidgetContent: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var model: AppModel
    let widget: WidgetInstance

    private var snap: SystemSnapshot { monitor.snapshot }
    private var history: Bool { widget.appearance.showHistory }

    var body: some View {
        switch widget.kind {
        case .cpu:
            VStack(alignment: .leading, spacing: 8) {
                MetricValue(title: "CPU", value: snap.cpuText,
                            detail: snap.cpu.map { "user \(MetricFormat.percent($0.user)) · sys \(MetricFormat.percent($0.system))" })
                if history { Sparkline(points: monitor.cpuHistory, maxValue: 1) }
            }
        case .memory:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    MetricValue(title: "Memory", value: snap.memoryText,
                                detail: snap.memory.map { "of \(MetricFormat.bytes(Double($0.totalBytes)))" })
                    Spacer()
                    if let p = snap.memory?.pressure {
                        Circle().fill(p.color).frame(width: 7, height: 7).help("Memory pressure: \(p.rawValue)")
                    }
                }
                if history { Sparkline(points: monitor.memoryHistory, maxValue: 1, color: .purple.opacity(0.8)) }
            }
        case .battery:
            HStack(spacing: 14) {
                RingGauge(value: snap.batteryLevel, color: (snap.batteryLevel ?? 1) < 0.2 ? .red : .green.opacity(0.85), lineWidth: 6)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: batteryIcon).font(.system(size: 13)).foregroundStyle(Theme.secondary))
                MetricValue(title: "Battery", value: snap.batteryText, detail: snap.batteryDetail)
            }
        case .network:
            VStack(alignment: .leading, spacing: 8) {
                MetricValue(title: "Network", value: snap.networkText, detail: snap.networkDetail, size: 22)
                if history {
                    ZStack {
                        Sparkline(points: monitor.downHistory, color: Theme.accent)
                        Sparkline(points: monitor.upHistory, color: .orange.opacity(0.8))
                            .opacity(0.8)
                    }
                }
            }
        case .storage:
            HStack(spacing: 14) {
                RingGauge(value: snap.storage?.usedFraction, color: (snap.storage?.usedFraction ?? 0) > 0.9 ? .red : Theme.accent, lineWidth: 6)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "internaldrive").font(.system(size: 13)).foregroundStyle(Theme.secondary))
                MetricValue(title: "Storage", value: snap.storageText, detail: snap.storageDetail)
            }
        case .clock:
            ClockFace()
        case .inbox:
            VStack(alignment: .leading, spacing: 8) {
                MetricValue(title: "Inbox", value: "\(model.totalUnread)", detail: model.priorityUnread > 0 ? "★ \(model.priorityUnread) priority" : "unread")
                HStack(spacing: 10) {
                    ForEach(model.visiblePlatforms.prefix(4)) { p in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.tint(p)).frame(width: 6, height: 6)
                            Text("\(model.unreadCounts[p] ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        .help(p.displayName)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openInbox() }
            .help("Double-click to open the inbox")
        }
    }

    private var batteryIcon: String {
        switch snap.battery {
        case .reading(let b) where b.isCharging: return "bolt.fill"
        case .noBattery: return "powerplug"
        default: return "battery.75percent"
        }
    }
}

/// Minimal digital clock; updates once a second via TimelineView (no custom timers).
struct ClockFace: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 40, weight: .thin, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
