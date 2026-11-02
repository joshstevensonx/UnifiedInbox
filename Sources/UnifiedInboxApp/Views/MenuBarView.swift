import InboxCore
import NexusCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var focus: FocusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: total + per-app dots
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(model.totalUnread)")
                    .font(.system(size: 26, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Text("unread").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                if model.priorityUnread > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 9))
                        Text("\(model.priorityUnread)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(Theme.priority)
                    .help("Priority unread")
                }
                ForEach(model.visiblePlatforms) { p in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.tint(p)).frame(width: 6, height: 6)
                        Text("\(model.unreadCounts[p] ?? 0)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                    .help("\(p.displayName): \(model.unreadCounts[p] ?? 0) unread")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            systemStrip

            NowPlayingCard(compact: true)
                .softFill(Theme.fill, cornerRadius: 10)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if let timer = focus.menuBarText {
                HStack(spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(Theme.accent)
                    Text("\(focus.timer.phase.title) \(timer)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.primary)
                    Spacer()
                    GlassIconButton(systemImage: focus.timer.isPaused ? "play.fill" : "pause.fill", help: "Pause / resume") { focus.togglePause() }
                    GlassIconButton(systemImage: "stop.fill", help: "Stop focus session") { focus.stop() }
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }

            ClosedAppsBanner(compact: true)

            if model.recentUnread.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light))
                    Text("All caught up").font(.system(size: 12))
                }
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.recentUnread) { item in
                        Button { model.open(item) } label: {
                            ItemRow(item: item, hideBody: model.privacyMode)
                        }
                        .buttonStyle(.plain)
                        .help(model.privacyMode ? "Open in \(item.platform.displayName)" : ItemRow.tooltip(for: item))
                    }
                }
                .padding(.horizontal, 6)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 6)

            HStack(spacing: 2) {
                Button("Open Inbox") { model.openInbox() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Spacer()
                GlassIconButton(systemImage: "square.grid.2x2", help: "Launcher (⌥Space)") { model.showLauncher() }
                GlassIconButton(systemImage: "checkmark", help: "Mark all as read") { model.markAllRead() }
                GlassIconButton(systemImage: "magnifyingglass", help: "Quick look & search (⌃⌥Space from anywhere)") {
                    model.showQuickLook()
                }
                SettingsLink14()
                GlassIconButton(systemImage: "power", help: "Quit Unified Inbox") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { monitor.subscribe() }
        .onDisappear { monitor.unsubscribe() }
        .background(GlassBackground(material: .hudWindow).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

extension MenuBarView {
    /// Compact live CPU / memory / battery / network row (spec §5.9).
    var systemStrip: some View {
        let s = monitor.snapshot
        return HStack(spacing: 0) {
            stat("cpu", s.cpuText, "CPU load")
            stat("memorychip", s.memory.map { MetricFormat.percent($0.usedFraction) }, s.memoryDetail ?? "Memory")
            stat(s.battery == .noBattery ? "powerplug" : "battery.75percent", s.batteryText, s.batteryDetail ?? "Battery")
            stat("arrow.down", s.network.map { MetricFormat.rate($0.downBytesPerSecond) }, s.networkDetail ?? "Network")
            Spacer(minLength: 0)
            GlassIconButton(systemImage: monitor.isPaused ? "play.fill" : "pause.fill",
                            help: monitor.isPaused ? "Resume monitoring" : "Pause monitoring") {
                monitor.isPaused.toggle()
            }
            GlassIconButton(systemImage: "gauge.with.dots.needle.33percent", help: "Open System Monitor") {
                model.section = .monitor
                model.openInbox()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .softFill(Theme.fill, cornerRadius: 10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func stat(_ icon: String, _ value: String?, _ help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            Text(value ?? "—").font(.system(size: 11).monospacedDigit()).foregroundStyle(value == nil ? Theme.tertiary : Theme.secondary)
        }
        .frame(minWidth: 62, alignment: .leading)
        .help(value == nil ? "\(help): unavailable" : help)
    }
}

/// Opens Settings on macOS 13 and 14+.
struct SettingsLink14: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Settings")
        } else {
            GlassIconButton(systemImage: "gearshape", help: "Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
