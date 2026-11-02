import NexusCore
import SwiftUI

/// Launcher page: search, pinned, groups, recent and all apps; add folders, apps and URLs.
struct LauncherView: View {
    @EnvironmentObject private var launcher: LauncherModel
    @EnvironmentObject private var model: AppModel
    @State private var showingAddURL = false
    @State private var showingAddAlias = false
    @State private var showingAddGroup = false
    @State private var newGroupName = ""

    private let grid = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !launcher.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    section("Results", launcher.results)
                } else {
                    section("Pinned", launcher.pinned, empty: "Right-click any app below and choose Pin.")
                    ForEach(launcher.groups) { group in
                        section(group.name, launcher.items(in: group), group: group,
                                empty: "Right-click an app and choose Move to Group.")
                    }
                    if !launcher.recent.isEmpty { section("Recent", launcher.recent) }
                    aliasSection
                    section("All Apps & Items", launcher.allSorted)
                }
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Launcher")
        .sheet(isPresented: $showingAddURL) { AddURLSheet() }
        .sheet(isPresented: $showingAddAlias) { AddAliasSheet() }
        .alert("New Group", isPresented: $showingAddGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") { launcher.addGroup(named: newGroupName); newGroupName = "" }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search apps, folders and links", text: $launcher.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassCard(cornerRadius: 10)
            .frame(maxWidth: 360)

            Picker("Sort", selection: Binding(get: { launcher.sort }, set: { launcher.sort = $0 })) {
                ForEach(LauncherSort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 150)
            .help("Order of items in groups and All Apps")

            Menu {
                Button("Application…") { launcher.addApp() }
                Button("Folder…") { launcher.addFolder() }
                Button("Link…") { showingAddURL = true }
                Button("Alias…") { showingAddAlias = true }
                Divider()
                Button("Group…") { showingAddGroup = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            .help("Add an app, folder, web link or group")

            Spacer()
            if launcher.isScanning { ProgressView().controlSize(.small) }
            Button { launcher.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Rescan /Applications for new or moved apps")
            Button("Open Launcher Panel") { model.showLauncher() }
                .help("Spotlight-style launcher from anywhere (⌥Space)")
        }
    }

    private var aliasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Aliases")
                Text("type these in ⌥Space").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button { showingAddAlias = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add an alias, e.g. g → https://google.com/search?q={query}")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(launcher.aliases.aliases) { a in
                    HStack(spacing: 8) {
                        Text(a.alias)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.priority)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .softFill(Theme.fill, cornerRadius: 5)
                        Text(a.title).font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
                        Spacer()
                        GlassIconButton(systemImage: "xmark", help: "Remove alias") { launcher.removeAlias(a) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassCard(cornerRadius: 9)
                    .help(aliasHelp(a))
                }
            }
        }
    }

    private func aliasHelp(_ a: CommandAlias) -> String {
        switch a.target {
        case .url(let u): return "\(a.alias) → \(u)" + (u.contains("{query}") ? "\nType “\(a.alias) something” to search" : "")
        case .app(let x): return "\(a.alias) → open \(x)"
        case .command(let x): return "\(a.alias) → command \(x)"
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LauncherItem], group: LauncherGroup? = nil, empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: title)
                Text("\(items.count)").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Spacer()
                if let group {
                    Menu {
                        Button("Delete Group", role: .destructive) { launcher.deleteGroup(group) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            if items.isEmpty, let empty {
                Text(empty).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            } else {
                LazyVGrid(columns: grid, alignment: .leading, spacing: 10) {
                    ForEach(items) { LauncherTile(item: $0) }
                }
            }
        }
    }
}

/// App / folder / URL tile with hover state and context menu.
struct LauncherTile: View {
    @EnvironmentObject private var launcher: LauncherModel
    let item: LauncherItem
    var compact = false
    @State private var hovering = false

    var body: some View {
        let missing = launcher.isMissing(item)
        VStack(spacing: 6) {
            Image(nsImage: launcher.icon(for: item))
                .resizable()
                .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
                .opacity(missing ? 0.4 : 1)
                .overlay(alignment: .topTrailing) {
                    if item.isPinned && !compact {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.secondary).offset(x: 4, y: -2)
                    }
                }
            Text(item.title)
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(missing ? Theme.tertiary : Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: compact ? 64 : 92, height: compact ? 66 : 86)
        .softFill(hovering ? Theme.fillHover : .clear, cornerRadius: 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { launcher.launch(item) }
        .help(tooltip(missing))
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") { launcher.togglePin(item) }
            if !launcher.groups.isEmpty {
                Menu("Move to Group") {
                    Button("None") { launcher.move(item, to: nil) }
                    ForEach(launcher.groups) { g in Button(g.name) { launcher.move(item, to: g) } }
                }
            }
            if item.kind != .url {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target)])
                }
            }
            if !item.isDiscovered {
                Divider()
                Button("Remove from Launcher", role: .destructive) { launcher.remove(item) }
            }
        }
    }

    private func tooltip(_ missing: Bool) -> String {
        var lines = [item.title, item.kind == .url ? item.target : (item.target as NSString).abbreviatingWithTildeInPath]
        if missing { lines.append("Not found: it may have been moved or deleted") }
        if item.useCount > 0 { lines.append("Opened \(item.useCount)×" + (item.lastUsed.map { ", last \($0.formatted(.relative(presentation: .named)))" } ?? "")) }
        lines.append("Click to open · right-click for options")
        return lines.joined(separator: "\n")
    }
}

struct AddURLSheet: View {
    @EnvironmentObject private var launcher: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link").font(.headline)
            TextField("Name (optional)", text: $title)
            TextField("https://…", text: $url)
            if invalid { Text("That doesn't look like a valid link.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if launcher.addURL(title: title, urlString: url) { dismiss() } else { invalid = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct AddAliasSheet: View {
    @EnvironmentObject private var launcher: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var title = ""
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Alias").font(.headline)
            TextField("Alias (one word, e.g. g)", text: $alias)
            TextField("Name (optional)", text: $title)
            TextField("Link, use {query} for search terms", text: $url)
            Text("Example: g → https://www.google.com/search?q={query}, then type “g swift charts”.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let e = launcher.addAlias(alias, title: title, url: url) { error = e } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(alias.isEmpty || url.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
