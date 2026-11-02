import AppKit
import Combine
import NexusCore
import SwiftUI

/// Large files, Downloads cleanup and duplicate finder. Scans run off the main thread;
/// nothing is removed without confirmation, and removal always goes to the Trash.
@MainActor
final class FileToolsModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case large = "Large Files", downloads = "Downloads", duplicates = "Duplicates"
        var id: String { rawValue }
    }

    @Published var tool: Tool = .large
    @Published var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var minSize: Int64 = 500_000_000
    @Published private(set) var scanning = false
    @Published private(set) var scanned = 0
    @Published private(set) var large: [FileEntry] = []
    @Published private(set) var downloads: [FileEntry] = []
    @Published private(set) var duplicates: [DuplicateGroup] = []
    @Published var selection: Set<String> = []
    @Published var confirmTrash = false
    @Published private(set) var message: String?

    let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    private var control: ScanControl?
    private var progressTimer: Timer?

    var downloadGroups: [CleanupGroup] { DownloadsCleanup.groups(downloads) }
    var suggestions: [FileEntry] { DownloadsCleanup.suggestions(downloads) }

    var selectedEntries: [FileEntry] {
        let all = large + downloads + duplicates.flatMap(\.files)
        var seen = Set<String>()
        return all.filter { selection.contains($0.path) && seen.insert($0.path).inserted }
    }

    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { folder = url; scan() }
    }

    func scan() {
        cancel()
        selection = []
        let control = ScanControl()
        self.control = control
        scanning = true
        scanned = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanned = control.visited }
        }
        let tool = self.tool, root = folder, downloadsRoot = downloadsFolder, minSize = self.minSize
        Task.detached(priority: .utility) {
            switch tool {
            case .large:
                let result = FileScanner.largest(FileScanner.files(under: root, control: control), minSize: minSize)
                await MainActor.run { self.finish(control) { self.large = result } }
            case .downloads:
                let result = FileScanner.children(of: downloadsRoot)
                await MainActor.run { self.finish(control) { self.downloads = result } }
            case .duplicates:
                let files = FileScanner.files(under: root, packagesAsFiles: true, control: control)
                let result = DuplicateFinder.find(files, minSize: 1_024, control: control)
                await MainActor.run { self.finish(control) { self.duplicates = result } }
            }
        }
    }

    private func finish(_ c: ScanControl, apply: () -> Void) {
        guard c === control else { return }   // a newer scan replaced this one
        if !c.isCancelled { apply() }
        scanned = c.visited
        scanning = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func cancel() {
        control?.cancel()
        scanning = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Selects every copy except the one to keep, in every duplicate group.
    func selectDuplicateExtras(keepNewest: Bool) {
        selection = Set(duplicates.flatMap { DuplicateFinder.filesToRemove($0, keepNewest: keepNewest) }.map(\.path))
    }

    func selectSuggestions() { selection = Set(suggestions.map(\.path)) }

    func reveal(_ f: FileEntry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }

    func open(_ f: FileEntry) { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }

    func trashSelected() {
        var moved = 0, failed = 0
        var freed: Int64 = 0
        for f in selectedEntries {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
                moved += 1; freed += f.size
            } catch { failed += 1 }
        }
        let gone = selection
        large.removeAll { gone.contains($0.path) }
        downloads.removeAll { gone.contains($0.path) }
        duplicates = duplicates.compactMap { g in
            var g = g
            g.files.removeAll { gone.contains($0.path) }
            return g.files.count > 1 ? g : nil
        }
        selection = []
        message = "Moved \(moved) item\(moved == 1 ? "" : "s") to the Trash (\(MetricFormat.bytes(Double(freed))))"
            + (failed > 0 ? ". \(failed) couldn't be moved." : ".")
    }
}

// MARK: - Views

struct FilesView: View {
    @EnvironmentObject private var files: FileToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("", selection: $files.tool) {
                    ForEach(FileToolsModel.Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                .onChange(of: files.tool) { _ in files.selection = [] }
                Spacer()
                if files.scanning {
                    ProgressView().controlSize(.small)
                    Text("\(files.scanned) items…").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                    Button("Stop") { files.cancel() }
                }
            }
            controls
            if let m = files.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            Group {
                switch files.tool {
                case .large: FileList(entries: files.large, empty: "Choose a folder and press Scan.")
                case .downloads: DownloadsPanel()
                case .duplicates: DuplicatesPanel()
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(28)
        .navigationTitle("Files")
        .confirmationDialog("Move \(files.selection.count) items (\(MetricFormat.bytes(Double(files.selectedSize)))) to the Trash?",
                            isPresented: $files.confirmTrash) {
            Button("Move to Trash", role: .destructive) { files.trashSelected() }
        } message: {
            Text("You can put them back from the Trash until you empty it.")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            switch files.tool {
            case .large, .duplicates:
                Button { files.chooseFolder() } label: { Label(files.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder") }
                if files.tool == .large {
                    Picker("At least", selection: $files.minSize) {
                        Text("50 MB").tag(Int64(50_000_000))
                        Text("100 MB").tag(Int64(100_000_000))
                        Text("500 MB").tag(Int64(500_000_000))
                        Text("1 GB").tag(Int64(1_000_000_000))
                        Text("5 GB").tag(Int64(5_000_000_000))
                    }
                    .frame(width: 160)
                }
                Button("Scan") { files.scan() }.keyboardShortcut(.defaultAction).disabled(files.scanning)
            case .downloads:
                Text(files.downloadsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                Button("Scan") { files.scan() }.keyboardShortcut(.defaultAction).disabled(files.scanning)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack {
            Text("Skips hidden files, Library, node_modules and .git. Nothing is deleted: items go to the Trash after you confirm.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Spacer()
            if !files.selection.isEmpty {
                Text("\(files.selection.count) selected · \(MetricFormat.bytes(Double(files.selectedSize)))")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                Button("Move to Trash…") { files.confirmTrash = true }
            }
        }
    }
}

/// Selectable rows with size, date, reveal / open.
struct FileList: View {
    @EnvironmentObject private var files: FileToolsModel
    let entries: [FileEntry]
    var empty = "Nothing here."

    var body: some View {
        if entries.isEmpty {
            Text(files.scanning ? "Scanning…" : empty).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).glassCard()
        } else {
            List {
                ForEach(entries) { FileRow(entry: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassCard()
        }
    }
}

struct FileRow: View {
    @EnvironmentObject private var files: FileToolsModel
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { files.selection.contains(entry.path) },
                                     set: { if $0 { files.selection.insert(entry.path) } else { files.selection.remove(entry.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
                Text((entry.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Text(MetricFormat.bytes(Double(entry.size)))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 70, alignment: .trailing)
            GlassIconButton(systemImage: "magnifyingglass", help: "Show in Finder") { files.reveal(entry) }
        }
        .contextMenu {
            Button("Open") { files.open(entry) }
            Button("Show in Finder") { files.reveal(entry) }
        }
    }
}

struct DownloadsPanel: View {
    @EnvironmentObject private var files: FileToolsModel
    @State private var category: FileCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !files.downloads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(nil, "All", "tray.full", files.downloads.reduce(0) { $0 + $1.size }, files.downloads.count)
                        ForEach(files.downloadGroups) { g in chip(g.category, g.category.title, g.category.symbolName, g.totalSize, g.files.count) }
                    }
                }
                HStack {
                    Text("Suggested: installers and archives older than a week, anything else older than 90 days (\(files.suggestions.count) items, \(MetricFormat.bytes(Double(files.suggestions.reduce(0) { $0 + $1.size }))))")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Select Suggested") { files.selectSuggestions() }.controlSize(.small).disabled(files.suggestions.isEmpty)
                }
            }
            FileList(entries: visible, empty: "Press Scan to look through your Downloads folder.")
        }
    }

    private var visible: [FileEntry] {
        guard let category else { return files.downloads.sorted { $0.size > $1.size } }
        return files.downloadGroups.first { $0.category == category }?.files ?? []
    }

    private func chip(_ c: FileCategory?, _ title: String, _ symbol: String, _ size: Int64, _ count: Int) -> some View {
        Button { category = c } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count) · \(MetricFormat.bytes(Double(size)))").foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .softFill(category == c ? Theme.fillSelected : Theme.fill)
        }
        .buttonStyle(.plain)
    }
}

struct DuplicatesPanel: View {
    @EnvironmentObject private var files: FileToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !files.duplicates.isEmpty {
                HStack {
                    let wasted = files.duplicates.reduce(0) { $0 + $1.wasted }
                    Text("\(files.duplicates.count) sets of identical files · \(MetricFormat.bytes(Double(wasted))) could be freed")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Select All but Oldest") { files.selectDuplicateExtras(keepNewest: false) }.controlSize(.small)
                    Button("Select All but Newest") { files.selectDuplicateExtras(keepNewest: true) }.controlSize(.small)
                }
            }
            if files.duplicates.isEmpty {
                Text(files.scanning ? "Comparing files…" : "Choose a folder and press Scan. Files are compared byte for byte, so only true copies are listed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).glassCard()
            } else {
                List {
                    ForEach(files.duplicates) { g in
                        Section {
                            ForEach(g.files) { FileRow(entry: $0) }
                        } header: {
                            Text("\(g.files.count) copies · \(MetricFormat.bytes(Double(g.size))) each")
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .glassCard()
            }
        }
    }
}
