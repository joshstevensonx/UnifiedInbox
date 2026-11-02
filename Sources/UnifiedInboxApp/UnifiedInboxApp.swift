import AppKit
import InboxCore
import SwiftUI

@main
struct UnifiedInboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Unified Inbox", id: "inbox") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.presence)
                .environmentObject(model.monitor)
                .environmentObject(model.launcher)
                .environmentObject(model.widgets)
                .environmentObject(model.clipboard)
                .environmentObject(model.apps)
                .environmentObject(model.media)
                .environmentObject(model.capture)
                .environmentObject(model.focus)
                .environmentObject(model.windows)
                .frame(minWidth: 820, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Mark All as Read") { model.markAllRead() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Quick Look (⌃⌥Space)") { model.showQuickLook() }
                Button("Launcher (⌥Space)") { model.showLauncher() }
                Button("Clipboard History (⌃⌥V)") { model.clipboard.togglePanel() }
                Divider()
                Menu("Export") {
                    ForEach(InboxExporter.Format.allCases) { format in
                        Button(format.title + "…") { model.export(format) }
                    }
                }
            }
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, s in
                    // ⌘1…⌘9 for the first nine pages; the rest are reachable from the sidebar and palette.
                    if index < 9 {
                        Button(s.title) { model.section = s; model.openInbox() }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(s.title) { model.section = s; model.openInbox() }
                    }
                }
            }
            CommandMenu("Tools") {
                Button("Screenshot Region") { model.capture.screenshot(.region) }
                    .keyboardShortcut("4", modifiers: [.command, .shift, .option])
                Button("Screenshot Window") { model.capture.screenshot(.window) }
                Button("Copy Text from Screen (OCR)") { model.capture.captureText() }
                    .keyboardShortcut("2", modifiers: [.command, .shift, .option])
                Divider()
                Button(model.focus.timer.phase == .idle ? "Start Focus Session" : "Stop Focus Session") {
                    if model.focus.timer.phase == .idle { model.focus.start() } else { model.focus.stop() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Play / Pause Music") { model.media.playPause() }
                Button("Next Track") { model.media.next() }
            }
            CommandGroup(after: .sidebar) {
                Toggle("Group by Conversation", isOn: $model.groupThreads)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Toggle("Privacy Mode", isOn: $model.privacyMode)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.presence)
                .environmentObject(model.monitor)
                .environmentObject(model.media)
                .environmentObject(model.focus)
        } label: {
            MenuBarLabel().environmentObject(model).environmentObject(model.focus)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.presence)
                .environmentObject(model.monitor)
                .environmentObject(model.launcher)
                .environmentObject(model.clipboard)
        }
    }
}

/// Menu-bar icon + stats ("★2 · 12"). It is always rendered, so it also hands SwiftUI's
/// `openWindow` to the model for opening the inbox from the quick-look panel and notifications.
struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var focus: FocusModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            if let timer = focus.menuBarText {
                Text(timer).monospacedDigit()
            }
            Image(systemName: model.totalUnread > 0 ? "tray.full.fill" : "tray")
            if model.priorityUnread > 0 {
                Text("★\(model.priorityUnread) · \(model.totalUnread)")
            } else if model.totalUnread > 0 {
                Text("\(model.totalUnread)")
            }
        }
        .onAppear { model.openInboxAction = { openWindow(id: "inbox") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark glass everywhere, including context menus and system panels.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// Keep capturing in the background after the main window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
