import InboxCore
import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel

    private var selected: [InboxItem] {
        model.items.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        if selected.count == 1, let item = selected.first {
            detail(item)
        } else if selected.count > 1 {
            VStack(spacing: 12) {
                Text("\(selected.count) selected").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.primary)
                HStack {
                    Button("Mark Read") { model.setRead(model.selection, true) }
                    Button("Pin") { model.setPinned(model.selection, true) }
                    Button("Archive") { model.setArchived(model.selection, true) }
                    Menu("Snooze") { SnoozeMenuItems(model: model, ids: model.selection) }.fixedSize()
                    Menu("Export") {
                        ForEach(InboxExporter.Format.allCases) { f in
                            Button(f.title + "…") { model.export(f) }
                        }
                    }
                    .fixedSize()
                    .help("Export just these \(selected.count) messages")
                }
            }
            .padding(24)
            .glassCard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableLabel(title: "Select a message", systemImage: "text.bubble")
        }
    }

    private func detail(_ item: InboxItem) -> some View {
        let thread = model.groupThreads ? model.conversation(for: item) : [item]
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Avatar(title: item.title, platform: item.platform, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack(spacing: 8) {
                    PlatformBadge(platform: item.platform)
                    Text(item.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    if thread.count > 1 { Text("· \(thread.count) messages") }
                    if item.isPriority, let reason = model.rules.match(item) {
                        Label(reason.label, systemImage: "star.fill").foregroundStyle(Theme.priority)
                    }
                    if let until = item.snoozedUntil {
                        Label("Until \(until.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)

                if thread.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(thread) { message in
                            MessageBubble(item: message, showSender: message.title != item.title || message.subtitle != item.subtitle)
                        }
                    }
                } else {
                    Text(item.body)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .glassCard()
                }
                NoteEditor(item: item)
                if item.origin == .notificationCenter {
                    Text("Captured from a macOS notification. The full message may be longer in \(item.platform.displayName).")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.setRead([item.id], !item.isRead) } label: {
                    Label(item.isRead ? "Mark Unread" : "Mark Read", systemImage: item.isRead ? "envelope.badge" : "envelope.open")
                }
                .help(item.isRead ? "Mark as unread (u)" : "Mark as read (u)")
                Button { model.setPinned([item.id], !item.isPinned) } label: {
                    Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                }
                .help(item.isPinned ? "Unpin (p)" : "Pin: keeps it at hand and stops it being auto-deleted (p)")
                if item.snoozedUntil != nil {
                    Button { model.unsnooze([item.id]) } label: { Label("Unsnooze", systemImage: "clock.arrow.circlepath") }
                        .help("Return to the inbox now")
                } else {
                    Menu { SnoozeMenuItems(model: model, ids: [item.id]) } label: { Label("Snooze", systemImage: "clock") }
                        .help("Hide until later; it comes back unread (s = tomorrow morning, z = 1 hour)")
                }
                Button { model.setArchived([item.id], !item.isArchived) } label: {
                    Label(item.isArchived ? "Move to Inbox" : "Archive", systemImage: "archivebox")
                }
                .help(item.isArchived ? "Move back to the inbox (e)" : "Archive (e)")
                Button { model.open(item) } label: {
                    Label("Open in \(item.platform.displayName)", systemImage: "arrow.up.forward.app")
                }
                .help("Switch to \(item.platform.displayName) (o or ↩)")
            }
        }
    }
}

/// One message inside a conversation view.
struct MessageBubble: View {
    let item: InboxItem
    let showSender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.isPriority {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.priority)
                }
                if showSender {
                    Text([item.title, item.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text(item.receivedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .help(item.receivedAt.formatted(date: .complete, time: .standard))
            }
            Text(item.body)
                .font(.system(size: 13))
                .foregroundStyle(item.isRead ? Theme.primary.opacity(0.75) : Theme.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }
}

/// Private note on a message; saved when editing ends.
struct NoteEditor: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Private note")
                Spacer()
                Button("Add to Tasks") { model.sendToTasks(item) }.controlSize(.small)
                Button("Add to Reminders") { model.sendToReminders(item) }.controlSize(.small)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(8)
                .softFill(Theme.fill, cornerRadius: 8)
                .focused($focused)
                .onChange(of: focused) { f in if !f { model.setNote(item.id, text) } }
            Text("Only on this Mac. Saved when you click away.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .onAppear { text = item.note ?? "" }
        .onChange(of: item.id) { _ in text = item.note ?? "" }
        .onDisappear { if text != (item.note ?? "") { model.setNote(item.id, text) } }
    }
}
