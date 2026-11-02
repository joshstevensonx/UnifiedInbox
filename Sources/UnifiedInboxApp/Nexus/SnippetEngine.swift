import AppKit
import Carbon.HIToolbox
import Combine
import NexusCore
import SwiftUI

/// Watches typing in other apps (global key monitor, needs Accessibility) and replaces abbreviations
/// with their expansion: deletes the abbreviation with backspaces, pastes the text, restores the clipboard.
/// Never runs in password fields (secure keyboard entry) or excluded apps.
@MainActor
final class SnippetEngine: ObservableObject {
    @Published var config: SnippetConfig { didSet { try? store.save(config) } }
    @Published private(set) var running = false
    @Published private(set) var lastExpansion: String?

    private let store = JSONFileStore<SnippetConfig>(url: JSONFileStore<SnippetConfig>.defaultURL("snippets"))
    private var matcher = SnippetMatcher()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var appObserver: NSObjectProtocol?
    private var expanding = false

    init() {
        config = JSONFileStore<SnippetConfig>(url: JSONFileStore<SnippetConfig>.defaultURL("snippets")).load() ?? SnippetConfig()
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.matcher.reset() }
        }
        restart()
    }

    func setEnabled(_ on: Bool) {
        if on, !AX.isTrusted() { _ = AX.isTrusted(prompt: true) }
        config.enabled = on
        restart()
    }

    func restart() {
        stop()
        guard config.enabled, AX.isTrusted() else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.matcher.reset()
        }
        running = true
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        running = false
        matcher.reset()
    }

    // MARK: Snippet list

    func add() { config.snippets.insert(Snippet(abbreviation: ";new", expansion: ""), at: 0) }

    func delete(_ s: Snippet) { config.snippets.removeAll { $0.id == s.id } }

    // MARK: Typing

    private func handle(_ event: NSEvent) {
        guard !expanding else { return }
        if IsSecureEventInputEnabled() { matcher.reset(); return }   // password fields
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, config.excludedApps.contains(bundle) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { matcher.reset(); return }
        switch Int(event.keyCode) {
        case kVK_Delete:
            matcher.backspace(); return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Tab, kVK_Escape,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            matcher.reset(); return
        default: break
        }
        guard let chars = event.characters, !chars.isEmpty else { return }
        for ch in chars {
            if let snippet = matcher.type(ch, snippets: config.snippets) {
                expand(snippet)
                return
            }
        }
    }

    private func expand(_ snippet: Snippet) {
        expanding = true
        let pb = NSPasteboard.general
        let saved = Self.savePasteboard(pb)
        let (text, caretFromEnd) = SnippetExpander.expand(snippet.expansion, clipboard: pb.string(forType: .string))

        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<snippet.abbreviation.count { Self.tap(UInt16(kVK_Delete), source: source) }

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers (ours included) ignore transient content.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        Self.tap(UInt16(kVK_ANSI_V), flags: .maskCommand, source: source)
        for _ in 0..<min(caretFromEnd, 500) { Self.tap(UInt16(kVK_LeftArrow), source: source) }

        if let i = config.snippets.firstIndex(where: { $0.id == snippet.id }) { config.snippets[i].useCount += 1 }
        lastExpansion = snippet.abbreviation
        // Give the target app time to paste before putting the user's clipboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Self.restorePasteboard(pb, saved)
            self?.expanding = false
            self?.matcher.reset()
        }
    }

    private static func tap(_ key: UInt16, flags: CGEventFlags = [], source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - View

struct SnippetsView: View {
    @EnvironmentObject private var snippets: SnippetEngine
    @State private var query = ""
    @State private var excludedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Expand snippets while typing in any app", isOn: Binding(get: { snippets.config.enabled }, set: { snippets.setEnabled($0) }))
                    .toggleStyle(.switch)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { snippets.add() } label: { Label("New Snippet", systemImage: "plus") }
            }
            if snippets.config.enabled && !snippets.running {
                GlassBanner(systemImage: "hand.raised.fill", tint: Theme.warning,
                            message: "Snippets need Accessibility permission to see typing in other apps and insert text.") {
                    Button("Allow…") { _ = AX.isTrusted(prompt: true); AX.openSettings() }
                    Button("Check Again") { snippets.restart() }
                }
            }
            ForEach(snippets.config.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($snippets.config.snippets) { $s in
                        if query.isEmpty || s.abbreviation.localizedCaseInsensitiveContains(query) || s.expansion.localizedCaseInsensitiveContains(query) {
                            HStack(alignment: .top, spacing: 10) {
                                Toggle("", isOn: $s.enabled).labelsHidden().toggleStyle(.checkbox)
                                TextField("Abbreviation", text: $s.abbreviation)
                                    .font(.system(size: 12, design: .monospaced)).frame(width: 110)
                                TextField("Expansion", text: $s.expansion, axis: .vertical)
                                    .font(.system(size: 12)).lineLimit(1...6)
                                Text("\(s.useCount)×").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                                    .help("Times expanded")
                                Button { snippets.delete(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                            .textFieldStyle(.roundedBorder)
                            .padding(10)
                            .glassCard(cornerRadius: Theme.smallRadius)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholders: {date} {time} {datetime} {isodate} {weekday} {clipboard} {cursor} (where the caret ends up). Never expands in password fields.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                HStack {
                    Text("Don't expand in:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    TextField("bundle ids, comma separated (e.g. com.apple.Terminal)", text: $excludedText, onCommit: saveExcluded)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
            }
        }
        .padding(28)
        .navigationTitle("Snippets")
        .onAppear { excludedText = snippets.config.excludedApps.joined(separator: ", ") }
        .onDisappear(perform: saveExcluded)
    }

    private func saveExcluded() {
        snippets.config.excludedApps = excludedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
