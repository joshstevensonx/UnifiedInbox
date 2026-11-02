import AppKit
import Combine
import NexusCore
import UniformTypeIdentifiers

/// Searchable launcher for apps, folders and URLs (spec §5.2). Independent of the Dock; never modifies it.
@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var config: LauncherConfig
    @Published var query = ""
    @Published private(set) var isScanning = false
    @Published private(set) var aliases: AliasConfig

    private let aliasStore = JSONFileStore<AliasConfig>(url: JSONFileStore<AliasConfig>.defaultURL("aliases"))

    private let store = JSONFileStore<LauncherConfig>(url: JSONFileStore<LauncherConfig>.defaultURL("launcher"))
    private var iconCache: [String: NSImage] = [:]

    /// Standard application locations.
    nonisolated static let searchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    init() {
        config = store.load() ?? LauncherConfig()
        aliases = aliasStore.load() ?? AliasConfig()
        rescan()
    }

    // MARK: Derived lists

    var sort: LauncherSort {
        get { config.sort }
        set { config.sort = newValue; save() }
    }

    var pinned: [LauncherItem] { LauncherSearch.sorted(config.items.filter(\.isPinned), by: .manual) }

    var recent: [LauncherItem] {
        Array(LauncherSearch.sorted(config.items.filter { $0.lastUsed != nil }, by: .recent).prefix(8))
    }

    func items(in group: LauncherGroup?) -> [LauncherItem] {
        LauncherSearch.sorted(config.items.filter { $0.groupId == group?.id }, by: config.sort)
    }

    var allSorted: [LauncherItem] { LauncherSearch.sorted(config.items, by: config.sort) }

    var results: [LauncherItem] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? (pinned + recent.filter { !$0.isPinned }).uniqued()
            : LauncherSearch.search(config.items, query: query, limit: 30)
    }

    var groups: [LauncherGroup] { config.groups.sorted { $0.sortOrder < $1.sortOrder } }

    func isMissing(_ item: LauncherItem) -> Bool {
        item.kind != .url && !FileManager.default.fileExists(atPath: item.target)
    }

    func icon(for item: LauncherItem) -> NSImage {
        if let cached = iconCache[item.target] { return cached }
        let image: NSImage
        switch item.kind {
        case .url:
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: item.title) ?? NSImage()
        case .app, .folder:
            image = NSWorkspace.shared.icon(forFile: item.target)
        }
        image.size = NSSize(width: 64, height: 64)
        iconCache[item.target] = image
        return image
    }

    // MARK: Discovery

    /// Scans standard folders off the main thread and merges with saved pins / usage.
    func rescan() {
        isScanning = true
        Task.detached(priority: .utility) {
            let found = Self.discoverApps()
            await MainActor.run {
                self.config.mergeDiscovered(found)
                self.isScanning = false
                self.save()
            }
        }
    }

    nonisolated static func discoverApps() -> [LauncherItem] {
        var seen = Set<String>()
        var items: [LauncherItem] = []
        let fm = FileManager.default
        for root in searchRoots {
            guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let key = bundle?.bundleIdentifier ?? url.path
                guard seen.insert(key).inserted else { continue }
                let title = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                items.append(LauncherItem(kind: .app, title: title, target: url.path,
                                          bundleId: bundle?.bundleIdentifier, isDiscovered: true))
            }
        }
        return items
    }

    // MARK: Actions

    func launch(_ item: LauncherItem) {
        switch item.kind {
        case .app:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.target), configuration: config) { _, _ in }
        case .folder:
            var stale = false
            if let data = item.bookmarkData,
               let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open(url)
                url.stopAccessingSecurityScopedResource()
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.target))
            }
        case .url:
            if let url = URL(string: item.target) { NSWorkspace.shared.open(url) }
        }
        config.recordLaunch(item.id)
        save()
    }

    func togglePin(_ item: LauncherItem) {
        // Compute first: reading config.items inside update's inout closure would be overlapping access.
        let nextOrder = (config.items.filter(\.isPinned).map(\.sortOrder).max() ?? 0) + 1
        update(item.id) {
            $0.isPinned.toggle()
            $0.sortOrder = nextOrder
        }
    }

    func move(_ item: LauncherItem, to group: LauncherGroup?) {
        update(item.id) { $0.groupId = group?.id }
    }

    /// Reorders pinned items (drag and drop in the pinned grid).
    func movePinned(from source: IndexSet, to destination: Int) {
        var list = pinned
        list.move(fromOffsets: source, toOffset: destination)
        for (i, item) in list.enumerated() { update(item.id) { $0.sortOrder = i } }
    }

    func remove(_ item: LauncherItem) {
        config.items.removeAll { $0.id == item.id }
        save()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Launcher"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            config.items.append(LauncherItem(kind: .folder, title: url.lastPathComponent, target: url.path,
                                             isPinned: true, bookmarkData: bookmark))
        }
        save()
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Launcher"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let item = LauncherItem(kind: .app, title: url.deletingPathExtension().lastPathComponent, target: url.path,
                                    bundleId: bundle?.bundleIdentifier, isPinned: true)
            if let i = config.items.firstIndex(where: { $0.mergeKey == item.mergeKey }) {
                config.items[i].isPinned = true
            } else {
                config.items.append(item)
            }
        }
        save()
    }

    /// Returns false if the URL isn't valid.
    @discardableResult
    func addURL(title: String, urlString: String) -> Bool {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host != nil || url.scheme != "https" else { return false }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host ?? s) : title
        config.items.append(LauncherItem(kind: .url, title: name, target: url.absoluteString, isPinned: true))
        save()
        return true
    }

    // MARK: Aliases (spec §1.4)

    /// Returns an error message, or nil on success.
    func addAlias(_ alias: String, title: String, url: String) -> String? {
        let key = alias.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, !key.contains(" ") else { return "Aliases are a single word, e.g. yt" }
        guard !aliases.aliases.contains(where: { $0.alias == key }) else { return "“\(key)” is already used" }
        var target = url.trimmingCharacters(in: .whitespaces)
        if !target.contains("://") { target = "https://" + target }
        guard URL(string: target.replacingOccurrences(of: "{query}", with: "x")) != nil else { return "That link isn't valid" }
        aliases.aliases.append(CommandAlias(alias: key, target: .url(target),
                                            title: title.isEmpty ? (URL(string: target)?.host ?? key) : title))
        try? aliasStore.save(aliases)
        return nil
    }

    func removeAlias(_ alias: CommandAlias) {
        aliases.aliases.removeAll { $0.id == alias.id }
        try? aliasStore.save(aliases)
    }

    // MARK: Groups

    func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        config.groups.append(LauncherGroup(name: trimmed, sortOrder: (config.groups.map(\.sortOrder).max() ?? 0) + 1))
        save()
    }

    func renameGroup(_ group: LauncherGroup, to name: String) {
        guard let i = config.groups.firstIndex(where: { $0.id == group.id }) else { return }
        config.groups[i].name = name
        save()
    }

    func deleteGroup(_ group: LauncherGroup) {
        config.groups.removeAll { $0.id == group.id }
        for i in config.items.indices where config.items[i].groupId == group.id { config.items[i].groupId = nil }
        save()
    }

    // MARK: Persistence

    private func update(_ id: UUID, _ change: (inout LauncherItem) -> Void) {
        guard let i = config.items.firstIndex(where: { $0.id == id }) else { return }
        change(&config.items[i])
        save()
    }

    private func save() {
        try? store.save(config)
    }
}

private extension Array where Element == LauncherItem {
    func uniqued() -> [LauncherItem] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.id).inserted }
    }
}
