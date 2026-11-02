import InboxCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.section == .inbox {
                inbox
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    page
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(GlassBackground(material: .underWindowBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .glassWindow()
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .overview: OverviewView()
        case .monitor: MonitorView()
        case .launcher: LauncherView()
        case .widgets: WidgetsGalleryView()
        case .apps: AppsView()
        case .clipboard: ClipboardView()
        case .focus: FocusView()
        case .windows: WindowsView()
        case .notes: NotesView()
        case .habits: HabitsView()
        case .files: FilesView()
        case .inbox: EmptyView()
        }
    }

    private var inbox: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            ItemListView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            ItemDetailView()
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .sheet(isPresented: $model.showExportRange) { ExportRangeSheet() }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $model.groupThreads) {
                    Label("Group by Conversation", systemImage: "rectangle.stack")
                }
                .help("Group by conversation (⇧⌘G): one row per chat or thread instead of one per message")

                Menu {
                    ForEach(InboxExporter.Format.allCases) { format in
                        Button(format.title + "…") { model.export(format) }
                    }
                    Divider()
                    Button("Date Range…") { model.showExportRange = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the selected messages (or the whole current view) as CSV, JSON or Markdown")

                Button { model.markAllRead() } label: { Label("Mark All Read", systemImage: "checkmark") }
                    .help("Mark everything in \(model.filter.title) as read (⇧⌘K)")
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Check for new notifications now (⌘R)")
            }
        }
    }
}

/// Shown when capture needs setup (most commonly: Full Disk Access).
struct CaptureStatusBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.captureStatus {
        case .needsSetup(let message), .failed(let message):
            GlassBanner(systemImage: "lock.fill", tint: Theme.warning, message: message) {
                Button("Open Settings") { model.openFullDiskAccessSettings() }
                    .help("Opens System Settings → Privacy & Security → Full Disk Access")
                Button("Check Again") { model.refresh() }
            }
        default:
            if let error = model.storeError {
                GlassBanner(systemImage: "exclamationmark.triangle.fill", tint: .red, message: error) { EmptyView() }
            }
        }
    }
}

/// Warns that closed source apps can't deliver notifications, with one-click fixes.
struct ClosedAppsBanner: View {
    @EnvironmentObject private var presence: AppPresenceMonitor
    let compact: Bool

    var body: some View {
        let closed = presence.closedApps
        if !closed.isEmpty {
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.warning)
                    Text("\(names(closed)) closed").font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Open") { presence.launchAllClosed() }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        .help("Launch \(names(closed)) hidden, without switching to them")
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            } else {
                GlassBanner(systemImage: "moon.zzz.fill", tint: Theme.warning, message: message(closed)) {
                    Button("Open in Background") { presence.launchAllClosed() }
                        .help("Launch \(names(closed)) hidden, without switching to them")
                    Button("Keep Running") { presence.keepAlive.formUnion(closed) }
                        .help("Always reopen \(names(closed)) in the background if they quit (change in Settings → Sources)")
                }
            }
        }
    }

    private func names(_ p: [Platform]) -> String {
        ListFormatter.localizedString(byJoining: p.map(\.displayName))
    }

    private func message(_ p: [Platform]) -> String {
        "\(names(p)) \(p.count == 1 ? "isn't" : "aren't") open, so new messages won't be captured."
    }
}

/// Export messages received in a date range (optionally one app).
struct ExportRangeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var platform: Platform?
    @State private var format: InboxExporter.Format = .csv

    var body: some View {
        Form {
            DatePicker("From", selection: $start, displayedComponents: .date)
            DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            Picker("App", selection: $platform) {
                Text("All apps").tag(Platform?.none)
                ForEach(model.visiblePlatforms) { Text($0.displayName).tag(Platform?.some($0)) }
            }
            Picker("Format", selection: $format) {
                ForEach(InboxExporter.Format.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    dismiss()
                    model.exportRange(from: start, to: end, platform: platform, format: format)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding()
    }
}
