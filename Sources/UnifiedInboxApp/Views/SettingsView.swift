import InboxCore
import NexusCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presence: AppPresenceMonitor
    @AppStorage("retentionDays") private var retentionDays = 30
    @AppStorage("pollSeconds") private var pollSeconds = 2.0
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            sources.tabItem { Label("Sources", systemImage: "antenna.radiowaves.left.and.right") }
            AlertsSettings().tabItem { Label("Alerts", systemImage: "star") }
            RulesSettingsView().tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            NexusSettings().tabItem { Label("Nexus", systemImage: "square.grid.2x2") }
            PermissionsView().tabItem { Label("Privacy", systemImage: "lock.shield") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: General

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
            Picker("Keep messages for", selection: $retentionDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Forever").tag(0)
            }
            Text("Pinned messages are never removed.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Group messages by conversation", isOn: $model.groupThreads)
                .help("One row per chat/thread instead of one per message (⇧⌘G)")
            Toggle("Quick look hotkey: ⌃⌥Space", isOn: $model.quickLookHotKey)
                .help("Opens a search panel over any app")
            Toggle("Privacy mode", isOn: $model.privacyMode)
            Text("Hides message text in the menu bar, quick look list and priority banners (e.g. when screen sharing).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Sources

    private var sources: some View {
        Form {
            Section("Apps to collect") {
                ForEach(Platform.allCases) { p in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { model.enabledPlatforms.contains(p) },
                            set: { on in
                                if on { model.enabledPlatforms.insert(p) } else { model.enabledPlatforms.remove(p) }
                            }
                        )) {
                            Label(p.displayName, systemImage: p.symbolName)
                        }
                        Spacer()
                        if model.enabledPlatforms.contains(p), let state = presence.presence[p] {
                            presenceBadge(state)
                            if state != .notInstalled {
                                Toggle("Keep running", isOn: Binding(
                                    get: { presence.keepAlive.contains(p) },
                                    set: { on in if on { presence.keepAlive.insert(p) } else { presence.keepAlive.remove(p) } }
                                ))
                                .toggleStyle(.checkbox)
                                .help("Open \(p.displayName) hidden at startup and reopen it if it quits, so its notifications keep arriving")
                            }
                        }
                    }
                }
                Text("An app that isn't running can't post notifications, so its messages can't be captured. \"Keep running\" opens it hidden in the background and reopens it if it quits (at most 3 times in 10 minutes).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify me when a source app is closed", isOn: $presence.warnWhenClosed)
            }
            Section("Notification Center capture") {
                LabeledContent("Status") { statusText }
                HStack {
                    Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                    Button("Check Again") { model.refresh() }
                }
                Stepper("Poll every \(Int(pollSeconds)) s (restart to apply)", value: $pollSeconds, in: 1...30)
            }
            Section("Microsoft 365 (Graph)") {
                Text("Coming in Phase 2: full email/chat content and read-state sync for Outlook and Teams.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func presenceBadge(_ state: AppPresence) -> some View {
        switch state {
        case .running: Label("Running", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
        case .notRunning: Label("Closed", systemImage: "moon.zzz.fill").foregroundStyle(.orange).font(.caption)
        case .notInstalled: Text("Not installed").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch model.captureStatus {
        case .running: Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle: Text("Idle").foregroundStyle(.secondary)
        case .needsSetup: Label("Needs permission", systemImage: "lock.fill").foregroundStyle(.orange)
        case .failed: Label("Unavailable", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section("Inbox window (single keys)") {
                ForEach(KeyboardTriage.help, id: \.key) { row in
                    LabeledContent(row.action) { Text(row.key).font(.system(.body, design: .monospaced)) }
                }
            }
            Section("Menu") {
                LabeledContent("Refresh") { Text("⌘R").font(.system(.body, design: .monospaced)) }
                LabeledContent("Mark all as read") { Text("⇧⌘K").font(.system(.body, design: .monospaced)) }
                LabeledContent("Search") { Text("⌘F").font(.system(.body, design: .monospaced)) }
                LabeledContent("Group by conversation") { Text("⇧⌘G").font(.system(.body, design: .monospaced)) }
                LabeledContent("Quick look (from any app)") { Text("⌃⌥Space").font(.system(.body, design: .monospaced)) }
            }
        }
        .formStyle(.grouped)
    }
}

/// VIP senders and keyword alerts. Edits are saved as you type and applied with "Apply".
struct AlertsSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var dirty = false

    var body: some View {
        Form {
            Section {
                TextField("e.g. Martin Nicholson, Mom, CEO", text: $model.vipText, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: model.vipText) { _ in dirty = true }
            } header: {
                Text("VIP senders")
            } footer: {
                Text("Matched against the sender or chat name. Comma or new line separated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("e.g. urgent, invoice*, server down", text: $model.keywordText, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: model.keywordText) { _ in dirty = true }
            } header: {
                Text("Keywords")
            } footer: {
                Text("Whole words or phrases in the title or message. End with * to match prefixes (invoice* → invoices).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show a banner and play a sound for priority messages", isOn: $model.priorityAlerts)
                HStack {
                    Spacer()
                    Button("Apply to All Messages") {
                        model.applyRules()
                        dirty = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Launcher, monitoring and widget preferences.
struct NexusSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var launcher: LauncherModel

    var body: some View {
        Form {
            Section("Launcher") {
                Toggle("Launcher hotkey: ⌥Space", isOn: $model.launcherHotKey)
                    .help("Opens the launcher panel over any app")
                Picker("Sort items", selection: Binding(get: { launcher.sort }, set: { launcher.sort = $0 })) {
                    ForEach(LauncherSort.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("\(launcher.config.items.count) items, \(launcher.pinned.count) pinned")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan Applications") { launcher.rescan() }
                }
            }
            Section("System monitoring") {
                Toggle("Pause monitoring", isOn: $monitor.isPaused)
                Text("Samples CPU, memory and network every 2 s while a dashboard, widget or the menu is visible, every 15 s otherwise. Battery about every 30 s, storage about every 60 s. Everything stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SystemAlertsSection()
            Section("Widgets") {
                Button(model.widgets.anyVisible ? "Hide All Widgets" : "Show All Widgets") {
                    model.widgets.showAll(!model.widgets.anyVisible)
                }
                .disabled(model.widgets.widgets.isEmpty)
                Text("Hover a widget for options; drag to move, drag an edge to resize. Positions are restored per display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Opt-in threshold alerts (task 13). Debounced: a condition must last, fires once, then waits for the cooldown.
struct SystemAlertsSection: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private func toggle(_ kind: ThresholdKind) -> Binding<Bool> {
        Binding(get: { monitor.thresholds.enabled.contains(kind) },
                set: { on in if on { monitor.thresholds.enabled.insert(kind) } else { monitor.thresholds.enabled.remove(kind) } })
    }

    var body: some View {
        Section {
            Toggle("High CPU", isOn: toggle(.cpu))
            if monitor.thresholds.enabled.contains(.cpu) {
                Stepper("Above \(Int(monitor.thresholds.cpuLimit * 100))%", value: $monitor.thresholds.cpuLimit, in: 0.5...0.99, step: 0.05)
                Stepper("For \(Int(monitor.thresholds.cpuSustainSeconds)) s", value: $monitor.thresholds.cpuSustainSeconds, in: 10...600, step: 10)
            }
            Toggle("Memory pressure", isOn: toggle(.memory))
            if monitor.thresholds.enabled.contains(.memory) {
                Toggle("Only when critical", isOn: $monitor.thresholds.memoryCriticalOnly)
            }
            Toggle("Low battery", isOn: toggle(.battery))
            if monitor.thresholds.enabled.contains(.battery) {
                Stepper("At \(Int(monitor.thresholds.batteryLimit * 100))% or less (on battery)", value: $monitor.thresholds.batteryLimit, in: 0.05...0.5, step: 0.05)
            }
            Toggle("Low disk space", isOn: toggle(.disk))
            if monitor.thresholds.enabled.contains(.disk) {
                Stepper("Under \(MetricFormat.bytes(Double(monitor.thresholds.diskFreeLimitBytes))) free",
                        value: $monitor.thresholds.diskFreeLimitBytes, in: 1_000_000_000...200_000_000_000, step: 5_000_000_000)
            }
            Stepper("Repeat at most every \(Int(monitor.thresholds.cooldownMinutes)) min", value: $monitor.thresholds.cooldownMinutes, in: 5...240, step: 5)
        } header: {
            Text("System alerts")
        } footer: {
            Text("Posts a notification when a limit is crossed. Each alert fires once per breach and repeats only after the condition clears and the cooldown passes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
