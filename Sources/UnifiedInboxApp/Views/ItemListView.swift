import InboxCore
import SwiftUI

struct ItemListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Status cards live inside the column, so they never overlap the sidebar or list.
            VStack(spacing: 8) {
                CaptureStatusBanner()
                ClosedAppsBanner(compact: false)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            listHeader

            if model.items.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    if model.groupThreads {
                        ForEach(DayBucket.sections(model.groups, date: { $0.latest.receivedAt }), id: \.bucket) { section in
                            Section {
                                ForEach(section.rows) { group in row(group.latest, group: group) }
                            } header: {
                                SectionLabel(text: section.bucket.title)
                            }
                        }
                    } else {
                        ForEach(DayBucket.sections(model.items, date: { $0.receivedAt }), id: \.bucket) { section in
                            Section {
                                ForEach(section.rows) { item in row(item, group: nil) }
                            } header: {
                                SectionLabel(text: section.bucket.title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 56)
                .onDeleteCommand { model.setArchived(model.selection, model.filter != .archived) }
            }
        }
        .navigationTitle(model.filter.title)
        .onChange(of: model.selection) { ids in
            // Opening a single row in the detail pane marks it (or its conversation) read.
            if ids.count == 1 { model.setRead(ids, true) }
        }
    }

    /// Title, count and quick view chips.
    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.filter.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(model.toast ?? countText)
                .font(.system(size: 11))
                .foregroundStyle(model.toast == nil ? Theme.tertiary : Theme.accent)
            Spacer()
            Chip(title: "Unread", systemImage: "circle.fill", isOn: model.filter == .unread) {
                model.filter = model.filter == .unread ? .all : .unread
            }
            .help("Show only unread messages")
            Chip(title: "Threads", systemImage: "rectangle.stack", isOn: model.groupThreads) {
                model.groupThreads.toggle()
            }
            .help("Group by conversation (⇧⌘G)")
            if !model.searchText.isEmpty {
                Chip(title: "Save", systemImage: "bookmark", isOn: false) {
                    model.saveCurrentSearch(named: model.searchText)
                }
                .help("Save this search to the sidebar")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var countText: String {
        if model.groupThreads {
            let n = model.groups.count
            return "\(n) conversation\(n == 1 ? "" : "s")"
        }
        let n = model.items.count
        return "\(n) message\(n == 1 ? "" : "s")"
    }

    @ViewBuilder private var emptyState: some View {
        if model.captureStatus != .running && model.searchText.isEmpty {
            SetupCard()
        } else {
            ContentUnavailableLabel(
                title: model.searchText.isEmpty ? "Nothing here" : "No results",
                systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass"
            )
        }
    }

    private func row(_ item: InboxItem, group: InboxGroup?) -> some View {
        ItemRow(item: item, group: group, hideBody: false, showsHoverActions: true)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            .tag(item.id)
            .help(ItemRow.tooltip(for: item, group: group))
            .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: InboxItem) -> some View {
        let ids: Set<String> = model.selection.contains(item.id) ? model.selection : [item.id]
        Button(item.isRead ? "Mark as Unread" : "Mark as Read") { model.setRead(ids, !item.isRead) }
        Button(item.isPinned ? "Unpin" : "Pin") { model.setPinned(ids, !item.isPinned) }
        Button(item.isArchived ? "Move to Inbox" : "Archive") { model.setArchived(ids, !item.isArchived) }
        if item.snoozedUntil != nil {
            Button("Unsnooze") { model.unsnooze(ids) }
        } else {
            Menu("Snooze") { SnoozeMenuItems(model: model, ids: ids) }
        }
        Menu("Label") {
            ForEach(model.ruleSet.allLabels, id: \.self) { l in
                Button((item.labels.contains(l) ? "✓ " : "") + l) { model.setLabel(ids, l, on: !item.labels.contains(l)) }
            }
            if !model.ruleSet.allLabels.isEmpty { Divider() }
            Button("New Label…") { model.promptNewLabel(for: ids) }
        }
        Menu("Remind Me") {
            SnoozeMenuItems(model: model, ids: ids)
        }
        .help("Hides the message and notifies you when it comes back")
        Button("Add to Tasks") { model.sendToTasks(item) }
        Button("Add to Apple Reminders") { model.sendToReminders(item) }
        Divider()
        Button("Copy Message") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString([item.title, item.subtitle, item.body].compactMap { $0 }.joined(separator: "\n"), forType: .string)
        }
        Button("Open in \(item.platform.displayName)") { model.open(item) }
    }
}

struct ItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem
    var group: InboxGroup? = nil
    var hideBody = false
    var showsHoverActions = false
    @State private var hovering = false

    /// Full details shown on hover (native tooltip).
    static func tooltip(for item: InboxItem, group: InboxGroup? = nil) -> String {
        var lines: [String] = []
        lines.append("\(item.title) · \(item.platform.displayName)")
        if let s = item.subtitle { lines.append(s) }
        lines.append(item.receivedAt.formatted(date: .abbreviated, time: .shortened)
                     + " (" + item.receivedAt.formatted(.relative(presentation: .named)) + ")")
        if let group, group.count > 1 {
            lines.append("\(group.count) messages in this conversation, \(group.unreadCount) unread")
        }
        var flags: [String] = []
        if item.isPriority { flags.append("★ Priority") }
        if item.isPinned { flags.append("Pinned") }
        if let until = item.snoozedUntil { flags.append("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))") }
        if !flags.isEmpty { lines.append(flags.joined(separator: " · ")) }
        lines.append("")
        lines.append(item.body.count > 600 ? String(item.body.prefix(600)) + "…" : item.body)
        return lines.joined(separator: "\n")
    }

    private var unread: Bool { group.map { $0.unreadCount > 0 } ?? !item.isRead }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(title: item.title, platform: item.platform)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .foregroundStyle(unread ? Theme.primary : Theme.secondary)
                        .lineLimit(1)
                    if let group, group.count > 1 {
                        Text("\(group.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .softFill(Theme.fillSelected, cornerRadius: 5)
                            .help("\(group.count) messages, \(group.unreadCount) unread")
                    }
                    Spacer(minLength: 4)
                    if hovering && showsHoverActions {
                        HoverActions(item: item)
                    } else {
                        statusIcons
                        Text(item.receivedAt, format: .relative(presentation: .named))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .help(item.receivedAt.formatted(date: .complete, time: .standard))
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(unread ? Theme.primary.opacity(0.8) : Theme.secondary)
                        .lineLimit(1)
                }
                if !item.labels.isEmpty || item.note != nil {
                    HStack(spacing: 4) {
                        ForEach(item.labels, id: \.self) { l in
                            Text(l)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(hex: model.ruleSet.labelColors[l] ?? "#8CB3FF"))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .softFill(Theme.fill, cornerRadius: 4)
                        }
                        if let note = item.note {
                            Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                                .help("Note: \(note)")
                        }
                    }
                }
                Text(hideBody ? "Message hidden" : item.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .softFill(hovering && showsHoverActions ? Theme.fillHover : .clear, cornerRadius: Theme.radius - 2)
        .overlay(alignment: .leading) {
            // Thin unread rail instead of a dot.
            if unread {
                Capsule().fill(Theme.accent).frame(width: 3, height: 18).offset(x: -1).help("Unread")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var statusIcons: some View {
        if group?.isPriority ?? item.isPriority {
            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.priority)
                .help(model.rules.match(item)?.label ?? "Priority")
        }
        if let until = item.snoozedUntil {
            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(Theme.warning)
                .help("Snoozed: returns as unread \(until.formatted(date: .complete, time: .shortened))")
        }
        if item.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary).help("Pinned")
        }
    }
}

/// Quick actions that replace the timestamp while the pointer is over a row.
struct HoverActions: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem

    var body: some View {
        HStack(spacing: 0) {
            GlassIconButton(systemImage: item.isRead ? "envelope.badge" : "envelope.open",
                            help: item.isRead ? "Mark as unread (u)" : "Mark as read (u)") {
                model.setRead([item.id], !item.isRead)
            }
            GlassIconButton(systemImage: item.isPinned ? "pin.slash" : "pin",
                            help: item.isPinned ? "Unpin (p)" : "Pin (p)") {
                model.setPinned([item.id], !item.isPinned)
            }
            Menu {
                SnoozeMenuItems(model: model, ids: [item.id])
            } label: {
                Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("Snooze (s = tomorrow morning, z = 1 hour)")
            GlassIconButton(systemImage: "archivebox", help: item.isArchived ? "Move to inbox (e)" : "Archive (e)") {
                model.setArchived([item.id], !item.isArchived)
            }
            GlassIconButton(systemImage: "arrow.up.right", help: "Open in \(item.platform.displayName) (o)") {
                model.open(item)
            }
        }
        .padding(.horizontal, 2)
        .glassCard(cornerRadius: 8)
    }
}

/// Kept for places that still want a plain platform marker (e.g. detail header).
struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.tint(platform)).frame(width: 6, height: 6)
            Text(platform.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .softFill(Theme.fill, cornerRadius: 6)
    }
}

/// macOS 13-compatible stand-in for ContentUnavailableView (macOS 14+).
struct ContentUnavailableLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Snooze presets, shared by context menus and the detail toolbar.
struct SnoozeMenuItems: View {
    // Passed explicitly: menus don't always inherit environment objects.
    @ObservedObject var model: AppModel
    let ids: Set<String>

    var body: some View {
        ForEach(SnoozeOption.allCases) { option in
            Button("\(option.title) — \(option.wakeDate(from: Date()).formatted(date: .abbreviated, time: .shortened))") {
                model.snooze(ids, option)
            }
        }
    }
}

/// Small toggle pill used in list headers.
struct Chip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 8))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .softFill(isOn ? Theme.fillSelected : Theme.fill, cornerRadius: 7)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isOn ? Theme.accent.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// First-run guide shown when capture isn't working yet and there's nothing to show.
struct SetupCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up message capture").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
            step(1, "Turn on notifications with previews for Teams, Outlook and WhatsApp",
                 detail: "System Settings → Notifications → each app → Show previews: Always")
            step(2, "Grant Full Disk Access to Unified Inbox",
                 detail: "Needed to read the Notification Center database (macOS 15+)")
            step(3, "Click Check Again, then send yourself a test message")
            HStack {
                Button("Open Full Disk Access") { model.openFullDiskAccessSettings() }
                Button("Check Again") { model.refresh() }
            }
            .controlSize(.small)
        }
        .padding(18)
        .glassCard()
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func step(_ n: Int, _ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.fillSelected))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.primary)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            }
        }
    }
}
