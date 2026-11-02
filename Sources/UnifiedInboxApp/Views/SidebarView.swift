import InboxCore
import SwiftUI

/// What a sidebar row points at: a NEXUS page or an inbox view.
enum SidebarItem: Hashable {
    case page(AppSection)
    case inbox(InboxFilter)
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presence: AppPresenceMonitor
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var focus: FocusModel

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: { model.section == .inbox ? .inbox(model.filter) : .page(model.section) },
            set: { item in
                switch item {
                case .page(let p): model.section = p
                case .inbox(let f): model.section = .inbox; model.filter = f
                case nil: break
                }
            }
        )) {
            Section {
                ForEach([AppSection.overview, .monitor, .launcher, .widgets], id: \.self) { page in
                    pageRow(page)
                }
            } header: {
                SectionLabel(text: "Nexus")
            }

            Section {
                ForEach([AppSection.focus, .notes, .windows, .files, .apps, .clipboard], id: \.self) { page in
                    pageRow(page)
                }
            } header: {
                SectionLabel(text: "Tools")
            }

            Section {
                row(.all, icon: "tray", count: model.totalUnread,
                    help: "Everything except archived and snoozed messages")
                row(.unread, icon: "circle", count: model.totalUnread,
                    help: "Messages you haven't opened yet")
                row(.priority, icon: "star", count: model.priorityUnread, highlight: true,
                    help: "Messages from VIP senders or containing your alert keywords (Settings → Alerts)")
                row(.pinned, icon: "pin", count: 0,
                    help: "Pinned messages: kept forever, even past the retention period")
                row(.snoozed, icon: "clock", count: model.snoozedCount,
                    help: "Hidden until their snooze time, then they come back unread")
            } header: {
                SectionLabel(text: "Inbox")
            }

            Section {
                ForEach(model.visiblePlatforms) { p in
                    platformRow(p)
                }
            } header: {
                SectionLabel(text: "Sources")
            }

            if !model.ruleSet.allLabels.isEmpty {
                Section {
                    ForEach(model.ruleSet.allLabels, id: \.self) { label in
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: model.ruleSet.labelColors[label] ?? "#8CB3FF"))
                                .frame(width: 7, height: 7).frame(width: 16)
                            Text(label).foregroundStyle(Theme.primary)
                            Spacer()
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 2)
                        .tag(SidebarItem.inbox(.label(label)))
                        .help("Messages labelled \(label). Labels come from rules or right-click → Label.")
                    }
                } header: {
                    SectionLabel(text: "Labels")
                }
            }

            if !model.ruleSet.savedSearches.isEmpty {
                Section {
                    ForEach(model.ruleSet.savedSearches) { s in
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 16)
                            Text(s.name).foregroundStyle(Theme.primary)
                            Spacer()
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { model.applySavedSearch(s) }
                        .help("Search “\(s.query)”" + (s.unreadOnly ? " in unread" : ""))
                        .contextMenu { Button("Delete Saved Search", role: .destructive) { model.deleteSavedSearch(s) } }
                    }
                } header: {
                    SectionLabel(text: "Saved searches")
                }
            }

            Section {
                row(.archived, icon: "archivebox", count: 0,
                    help: "Archived messages. Press e to move one back to the inbox")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func pageRow(_ page: AppSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: page.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(page.title).foregroundStyle(Theme.primary)
            Spacer()
            if page == .monitor, let cpu = monitor.snapshot.cpuText {
                Text(cpu).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            if page == .focus {
                if let running = focus.menuBarText {
                    Text(running).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.accent)
                } else if focus.overdueCount > 0 {
                    Text("\(focus.overdueCount)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.red.opacity(0.8))
                        .help("Overdue tasks")
                } else {
                    CountText(count: focus.openCount)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
        .tag(SidebarItem.page(page))
        .help(pageHelp(page))
    }

    private func pageHelp(_ page: AppSection) -> String {
        switch page {
        case .overview: return "Your Mac at a glance: live metrics, inbox, pinned apps and widgets"
        case .monitor: return "CPU, memory, network, battery and storage with 5-minute history"
        case .launcher: return "Search and launch apps, folders and links (⌥Space from anywhere)"
        case .widgets: return "Add floating desktop widgets: CPU, memory, battery, network, storage, clock, inbox"
        case .apps: return "Running apps (quit, force quit, restart, hide) and local screen-time tracking"
        case .clipboard: return "Clipboard history: search, pin and copy back (⌃⌥V from anywhere)"
        case .focus: return "Tasks and Pomodoro focus timer"
        case .notes: return "Markdown notes with [[links]], backlinks and daily notes"
        case .files: return "Find large files and duplicates, clean up Downloads"
        case .windows: return "Tile windows (⌃⌥ arrows) and save / switch workspaces"
        case .inbox: return "Unified inbox"
        }
    }

    private func row(_ filter: InboxFilter, icon: String, count: Int, highlight: Bool = false, help: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(highlight && count > 0 ? Theme.priority : Theme.secondary)
                .frame(width: 16)
            Text(filter.title).foregroundStyle(Theme.primary)
            Spacer()
            CountText(count: count, highlight: highlight)
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
        .tag(SidebarItem.inbox(filter))
        .help(help)
    }

    private func platformRow(_ p: Platform) -> some View {
        let state = presence.presence[p]
        let count = model.unreadCounts[p] ?? 0
        return HStack(spacing: 10) {
            Circle()
                .fill(Theme.tint(p).opacity(state == .notRunning ? 0.35 : 1))
                .frame(width: 7, height: 7)
                .frame(width: 16)
            Text(p.displayName).foregroundStyle(state == .notRunning ? Theme.secondary : Theme.primary)
            if state == .notRunning {
                Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(Theme.warning)
            }
            Spacer()
            CountText(count: count)
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
        .tag(SidebarItem.inbox(.platform(p)))
        .help(platformHelp(p, state))
        .contextMenu {
            if state == .notRunning {
                Button("Open \(p.displayName) in Background") { presence.launchInBackground(p) }
            }
            Toggle("Keep \(p.displayName) Running", isOn: Binding(
                get: { presence.keepAlive.contains(p) },
                set: { on in if on { presence.keepAlive.insert(p) } else { presence.keepAlive.remove(p) } }
            ))
        }
    }

    /// Capture status at a glance.
    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.captureStatus == .running ? Color.green.opacity(0.8) : Theme.warning)
                .frame(width: 6, height: 6)
            Text(model.captureStatus == .running ? "Listening" : "Needs setup")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Spacer()
            GlassIconButton(systemImage: "magnifyingglass", help: "Quick look (⌃⌥Space from any app)") {
                model.showQuickLook()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help(model.captureStatus == .running
              ? "Capturing notifications from Notification Center"
              : "Capture needs Full Disk Access. See the banner at the top")
    }

    private func platformHelp(_ p: Platform, _ state: AppPresence?) -> String {
        let unread = model.unreadCounts[p] ?? 0
        var s = "\(p.displayName): \(unread) unread"
        switch state {
        case .running: s += "\nApp is running, so new notifications are being captured."
        case .notRunning: s += "\nApp is closed, so new messages won't be captured. Right-click to open it or keep it running."
        case .notInstalled: s += "\nApp not installed."
        case nil: break
        }
        if presence.keepAlive.contains(p) { s += "\nKeep running: on" }
        return s
    }
}
