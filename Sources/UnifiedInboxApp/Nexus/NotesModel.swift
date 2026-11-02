import AppKit
import Combine
import InboxCore
import NexusCore
import SwiftUI

/// Markdown notes stored as plain `.md` files (Application Support/UnifiedInbox/Notes).
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var selectedTitle: String?
    /// Text of the selected note; edits are saved after a short pause.
    @Published var draft: String = "" { didSet { if draft != savedDraft { scheduleSave() } } }
    @Published var query = ""
    @Published var mode: Mode = .edit
    @Published private(set) var error: String?

    enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit", preview = "Preview"
        var id: String { rawValue }
    }

    let folder = NoteFolder(folder: NoteFolder.defaultFolder())
    private var savedDraft = ""
    private var saveWork: DispatchWorkItem?

    init() { reload() }

    var selected: Note? { notes.first { $0.title == selectedTitle } }
    var filtered: [Note] { NoteSearch.search(query, in: notes) }
    var backlinks: [Note] { selectedTitle.map { NoteLinks.backlinks(to: $0, in: notes) } ?? [] }
    var mentions: [Note] { selectedTitle.map { NoteLinks.unlinkedMentions(of: $0, in: notes) } ?? [] }
    var allTags: [String] { Array(Set(notes.flatMap(\.tags))).sorted() }

    func reload() {
        flushSave()
        notes = folder.loadAll()
        if let t = selectedTitle, let n = notes.first(where: { $0.title == t }) {
            if n.body != draft { setDraft(n.body) }
        } else {
            select(notes.first?.title)
        }
    }

    func select(_ title: String?) {
        flushSave()
        selectedTitle = title
        setDraft(title.flatMap { t in notes.first { $0.title == t }?.body } ?? "")
    }

    private func setDraft(_ text: String) {
        savedDraft = text
        draft = text
    }

    /// Opens (creating if needed) a note by title. Used by [[links]].
    func open(_ title: String) {
        if let existing = notes.first(where: { $0.id == title.lowercased() }) {
            select(existing.title)
        } else {
            create(title: title, body: "# \(title)\n\n")
        }
        mode = .edit
    }

    func create(title: String, body: String = "") {
        var name = title
        var n = 2
        while notes.contains(where: { $0.id == name.lowercased() }) { name = "\(title) \(n)"; n += 1 }
        let note = Note(title: name, body: body.isEmpty ? "# \(name)\n\n" : body)
        do {
            try folder.save(note)
            notes.insert(note, at: 0)
            select(name)
        } catch {
            self.error = "Couldn't create note: \(error.localizedDescription)"
        }
    }

    func newNote() {
        create(title: "Untitled \(Date().formatted(.dateTime.month(.abbreviated).day().hour().minute()))".replacingOccurrences(of: ":", with: "."))
    }

    func openToday() {
        let title = DailyNotes.title(for: Date())
        if notes.contains(where: { $0.title == title }) { select(title) } else { create(title: title, body: DailyNotes.template(for: Date())) }
        mode = .edit
    }

    /// Adds a line under today's note (e.g. from an inbox message).
    func appendToToday(_ text: String) {
        openToday()
        draft += (draft.hasSuffix("\n") ? "" : "\n") + text + "\n"
        flushSave()
    }

    func rename(to newTitle: String) {
        guard let old = selectedTitle else { return }
        let new = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        flushSave()
        do {
            try folder.rename(old, to: new, notes: notes)
            selectedTitle = new
            notes = folder.loadAll()
        } catch {
            self.error = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    func delete(_ title: String) {
        do {
            try folder.delete(title: title)
            notes.removeAll { $0.title == title }
            if selectedTitle == title { select(notes.first?.title) }
        } catch {
            self.error = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    func toggleTask(line: Int) {
        draft = MarkdownParser.toggleTask(in: draft, line: line)
        flushSave()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder.folder)
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.flushSave() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard let title = selectedTitle, draft != savedDraft else { return }
        let note = Note(title: title, body: draft)
        do {
            try folder.save(note)
            savedDraft = draft
            if let i = notes.firstIndex(where: { $0.title == title }) { notes[i] = note }
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

struct NotesView: View {
    @EnvironmentObject private var notes: NotesModel

    var body: some View {
        HStack(spacing: 0) {
            NotesList().frame(width: 250)
            Divider().overlay(Theme.hairline)
            if notes.selectedTitle != nil {
                NoteEditor()
            } else {
                VStack(spacing: 10) {
                    Text("No note selected").foregroundStyle(Theme.secondary)
                    Button("Open Today's Note") { notes.openToday() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notes")
        .onAppear { notes.reload() }
        .onDisappear { notes.flushSave() }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "note" {
                notes.open(url.absoluteString.dropFirst("note:".count).removingPercentEncoding ?? "")
                return .handled
            }
            return .systemAction
        })
    }
}

struct NotesList: View {
    @EnvironmentObject private var notes: NotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Search or #tag", text: $notes.query).textFieldStyle(.roundedBorder)
                GlassIconButton(systemImage: "calendar", help: "Today's daily note") { notes.openToday() }
                GlassIconButton(systemImage: "square.and.pencil", help: "New note") { notes.newNote() }
            }
            List(selection: Binding(get: { notes.selectedTitle }, set: { notes.select($0) })) {
                ForEach(notes.filtered) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if n.isDaily { Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                            Text(n.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                        }
                        Text(n.preview).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(n.title as String?)
                    .contextMenu {
                        Button("Delete Note", role: .destructive) { notes.delete(n.title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            if !notes.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(notes.allTags.prefix(20), id: \.self) { tag in
                            Button("#\(tag)") { notes.query = "#\(tag)" }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            HStack {
                Text("\(notes.notes.count) notes").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Show Folder") { notes.revealFolder() }.buttonStyle(.link).font(.system(size: 11))
                    .help("Notes are plain Markdown files: edit them with any app")
            }
        }
        .padding(14)
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var notes: NotesModel
    @State private var titleField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Title", text: $titleField, onCommit: { notes.rename(to: titleField) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .help("Rename: links in other notes are updated too")
                Spacer()
                Picker("", selection: $notes.mode) {
                    ForEach(NotesModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if let err = notes.error {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
            Group {
                if notes.mode == .edit {
                    TextEditor(text: $notes.draft)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView { MarkdownPreview(text: notes.draft).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .padding(10)
            .glassCard()
            LinkedReferences()
        }
        .padding(20)
        .onAppear { titleField = notes.selectedTitle ?? "" }
        .onChange(of: notes.selectedTitle) { titleField = $0 ?? "" }
    }
}

/// Backlinks and unlinked mentions for the selected note.
struct LinkedReferences: View {
    @EnvironmentObject private var notes: NotesModel

    var body: some View {
        let back = notes.backlinks, mentions = notes.mentions
        if !back.isEmpty || !mentions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !back.isEmpty {
                    SectionLabel(text: "Linked from \(back.count)")
                    chips(back)
                }
                if !mentions.isEmpty {
                    SectionLabel(text: "Mentioned in \(mentions.count) (not linked)")
                    chips(mentions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chips(_ list: [Note]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(list) { n in
                    Button { notes.select(n.title) } label: {
                        Text(n.title).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4)
                            .softFill(Theme.fill, cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .help(n.preview)
                }
            }
        }
    }
}

/// Block-level Markdown rendering; inline styles and [[links]] via AttributedString.
struct MarkdownPreview: View {
    @EnvironmentObject private var notes: NotesModel
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .padding(4)
    }

    private func inline(_ s: String) -> Text {
        let md = MarkdownParser.linkify(s)
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: md, options: opts)) ?? AttributedString(s))
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            inline(t).font(.system(size: level == 1 ? 22 : level == 2 ? 17 : 14, weight: .semibold))
                .foregroundStyle(Theme.primary).padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let t):
            inline(t).font(.system(size: 13)).foregroundStyle(Theme.primary)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Theme.tertiary)
                inline(t).font(.system(size: 13)).foregroundStyle(Theme.primary)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(Theme.tertiary).monospacedDigit()
                inline(t).font(.system(size: 13)).foregroundStyle(Theme.primary)
            }
        case .task(let checked, let t, let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { notes.toggleTask(line: line) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Theme.accent : Theme.secondary)
                }
                .buttonStyle(.plain)
                inline(t).font(.system(size: 13)).foregroundStyle(checked ? Theme.tertiary : Theme.primary)
                    .strikethrough(checked)
            }
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 2)
                inline(t).font(.system(size: 13)).italic().foregroundStyle(Theme.secondary)
            }
        case .code(let c):
            Text(c).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.primary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .softFill(Theme.fill)
        case .rule:
            Divider().overlay(Theme.hairline)
        }
    }
}

extension AppModel {
    func notesPaletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(id: "notes.today", title: "Today's Note", subtitle: DailyNotes.title(for: Date()), symbol: "calendar",
                           keywords: ["daily", "journal", "notes"]) { [weak self] in
                self?.notes.openToday(); self?.section = .notes; self?.openInbox()
            },
            PaletteCommand(id: "notes.new", title: "New Note", symbol: "square.and.pencil", keywords: ["notes", "write", "markdown"]) { [weak self] in
                self?.notes.newNote(); self?.section = .notes; self?.openInbox()
            },
        ] + notes.notes.prefix(50).map { n in
            PaletteCommand(id: "notes.open.\(n.id)", title: "Note: \(n.title)", subtitle: n.preview, symbol: "doc.text",
                           keywords: ["note"] + n.tags) { [weak self] in
                self?.notes.select(n.title); self?.section = .notes; self?.openInbox()
            }
        }
    }

    /// Adds a message as a line in today's daily note.
    func sendToNotes(_ item: InboxItem) {
        let time = item.receivedAt.formatted(date: .omitted, time: .shortened)
        let text = item.body.replacingOccurrences(of: "\n", with: " ")
        notes.appendToToday("- \(time) \(item.platform.displayName) · **\(item.title)**: \(text)")
        flash("Added to today's note")
    }
}
