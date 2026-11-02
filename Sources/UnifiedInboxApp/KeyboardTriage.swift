import AppKit
import InboxCore
import UserNotifications

/// Gmail/Superhuman-style single-key shortcuts in the inbox window.
///
/// j / k   next / previous        e   archive (unarchive in Archived)
/// p       pin / unpin            u   read / unread
/// s       snooze → tomorrow      z   snooze → 1 hour
/// o / ↩   open in source app     ⎋   clear selection
///
/// Ignored while typing in any text field, when ⌘/⌃/⌥ are held, and outside the inbox window.
@MainActor
final class KeyboardTriage {
    private var monitor: Any?
    private weak var model: AppModel?

    static let help: [(key: String, action: String)] = [
        ("j / k", "Next / previous"),
        ("e", "Archive"),
        ("p", "Pin / unpin"),
        ("u", "Read / unread"),
        ("s", "Snooze until tomorrow morning"),
        ("z", "Snooze 1 hour"),
        ("o or ↩", "Open in source app"),
        ("⎋", "Clear selection"),
    ]

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil // consumed
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func isInboxWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else { return false }
        if window.identifier?.rawValue.lowercased().contains("inbox") == true { return true }
        return window.title == model?.filter.title || window.title == "Unified Inbox"
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, model.section == .inbox, isInboxWindow(NSApp.keyWindow) else { return false }
        // Never steal keys from the search field or any other text input.
        if NSApp.keyWindow?.firstResponder is NSText { return false }

        let ids = model.selection
        switch event.keyCode {
        case 36, 76: // return, keypad enter
            if let item = model.selectedItems.first { model.open(item); return true }
            return false
        case 53: // escape
            guard !ids.isEmpty else { return false }
            model.selection = []
            return true
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": model.moveSelection(by: 1)
        case "k": model.moveSelection(by: -1)
        case "e":
            guard !ids.isEmpty else { return false }
            model.setArchived(ids, model.filter != .archived)
        case "p":
            guard !ids.isEmpty else { return false }
            model.setPinned(ids, !model.selectedItems.allSatisfy(\.isPinned))
        case "u":
            guard !ids.isEmpty else { return false }
            model.setRead(ids, !model.selectedItems.allSatisfy(\.isRead))
        case "s":
            guard !ids.isEmpty else { return false }
            model.snooze(ids, .tomorrowMorning)
        case "z":
            guard !ids.isEmpty else { return false }
            model.snooze(ids, .oneHour)
        case "o":
            guard let item = model.selectedItems.first else { return false }
            model.open(item)
        default:
            return false
        }
        return true
    }
}

/// Banner + sound for VIP / keyword matches.
enum PriorityNotifier {
    /// UNUserNotificationCenter crashes when there's no app bundle (e.g. `swift run`), so check first.
    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestAuthorizationIfPossible() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func alert(item: InboxItem, reason: PriorityReason?, hideBody: Bool = false) {
        guard canUseUserNotifications else {
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "★ \(item.title)"
        content.subtitle = [item.platform.displayName, reason?.label].compactMap { $0 }.joined(separator: " · ")
        content.body = hideBody ? "New message" : item.body
        content.sound = .default
        content.threadIdentifier = "priority"
        let request = UNNotificationRequest(identifier: "priority-\(item.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
