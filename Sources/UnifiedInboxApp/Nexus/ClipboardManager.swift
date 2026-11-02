import AppKit
import Carbon.HIToolbox
import NexusCore
import SwiftUI

/// Local clipboard history (spec §14.3, §6.5). Polls the pasteboard's change count twice a second
/// (the only public way on macOS), skips anything password managers mark as concealed, and keeps
/// everything on this Mac.
@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var history: ClipHistory
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "clipboardEnabled"); restartTimer() }
    }
    @Published var query = ""
    @Published var kindFilter: ClipKind?
    @Published var selection = 0
    /// Short-lived confirmation ("Copied") shown in the UI.
    @Published var toast: String?

    private let store = JSONFileStore<ClipHistory>(url: JSONFileStore<ClipHistory>.defaultURL("clipboard"))
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoreChangeCount: Int?
    private var hotKey: GlobalHotKey?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        history = store.load() ?? ClipHistory(limit: 200)
        isEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
        restartTimer()
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
    }

    var results: [ClipEntry] { history.search(query, kind: kindFilter) }

    // MARK: Capture

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if pb.changeCount == ignoreChangeCount { return }   // our own write
        let types = (pb.types ?? []).map(\.rawValue)
        if types.contains(where: { ClipClassifier.concealedTypes.contains($0) }) { return }

        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        var entry: ClipEntry?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            entry = ClipEntry(kind: .path, text: urls.map(\.path).joined(separator: "\n"), sourceApp: source)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry = ClipEntry(kind: ClipClassifier.classify(s), text: String(s.prefix(20_000)), sourceApp: source)
        } else if let image = NSImage(pasteboard: pb), let png = Self.thumbnailPNG(image) {
            entry = ClipEntry(kind: .image, text: "Image \(Int(image.size.width))×\(Int(image.size.height))",
                              imagePNG: png, sourceApp: source)
        }
        guard let entry else { return }
        history.add(entry)
        save()
    }

    /// Keeps stored images small (bounded storage): longest side 480 px.
    static func thumbnailPNG(_ image: NSImage) -> Data? {
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Actions

    func copy(_ entry: ClipEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .image:
            if let data = entry.imagePNG { pb.setData(data, forType: .png) }
        case .path:
            let urls = entry.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
            pb.setString(entry.text, forType: .string)
        default:
            pb.setString(entry.text, forType: .string)
        }
        ignoreChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        history.add(ClipEntry(id: entry.id, kind: entry.kind, text: entry.text, imagePNG: entry.imagePNG,
                              sourceApp: entry.sourceApp, isPinned: entry.isPinned))
        save()
        flash("Copied: press ⌘V to paste")
    }

    func togglePin(_ entry: ClipEntry) { history.togglePin(entry.id); save() }
    func remove(_ entry: ClipEntry) { history.remove(entry.id); save() }
    func clearUnpinned() { history.clearUnpinned(); save(); flash("Cleared (pinned items kept)") }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    private func save() { try? store.save(history) }

    // MARK: ⌃⌥V panel

    func togglePanel() {
        if let panel, panel.isVisible { closePanel(); return }
        if AppLock.shared.isLocked { AppLock.shared.unlock { [weak self] in self?.togglePanel() }; return }
        query = ""; kindFilter = nil; selection = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height / 4 - panel.frame.height))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handleKey(event) else { return event }
                return nil
            }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isKeyWindow else { return false }
        let items = results
        switch Int(event.keyCode) {
        case kVK_DownArrow: selection = min(selection + 1, max(items.count - 1, 0))
        case kVK_UpArrow: selection = max(selection - 1, 0)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if items.indices.contains(selection) { copy(items[selection]); closePanel() }
        case kVK_Escape: closePanel()
        default: return false
        }
        return true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: ClipboardPanelView().environmentObject(self))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        return panel
    }
}

// MARK: - Views

struct ClipboardPanelView: View {
    @EnvironmentObject private var clipboard: ClipboardManager
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 16, weight: .light)).foregroundStyle(Theme.secondary)
                TextField("Search clipboard history", text: $clipboard.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .light))
                    .focused($focused)
                Text("⌃⌥V").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2).softFill(Theme.fill, cornerRadius: 5)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            ClipKindChips().padding(.horizontal, 14).padding(.bottom, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ClipboardList(compact: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Text(clipboard.toast ?? "↑↓ select   ↩ copy   ⎋ close")
                Spacer()
                Text("\(clipboard.history.entries.count) items")
            }
            .font(.system(size: 10)).foregroundStyle(clipboard.toast == nil ? Theme.tertiary : Theme.accent)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 560, height: 460)
        .background(GlassBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onChange(of: clipboard.query) { _ in clipboard.selection = 0 }
    }
}

struct ClipKindChips: View {
    @EnvironmentObject private var clipboard: ClipboardManager

    var body: some View {
        HStack(spacing: 6) {
            Chip(title: "All", systemImage: "square.stack", isOn: clipboard.kindFilter == nil) { clipboard.kindFilter = nil }
            ForEach(ClipKind.allCases, id: \.self) { k in
                Chip(title: k.rawValue.capitalized, systemImage: k.symbolName, isOn: clipboard.kindFilter == k) {
                    clipboard.kindFilter = clipboard.kindFilter == k ? nil : k
                }
            }
            Spacer()
        }
    }
}

struct ClipboardList: View {
    @EnvironmentObject private var clipboard: ClipboardManager
    var compact = false

    var body: some View {
        let items = clipboard.results
        if items.isEmpty {
            ContentUnavailableLabel(title: clipboard.isEnabled ? "Nothing copied yet" : "Clipboard history is off",
                                    systemImage: "doc.on.clipboard")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            ClipRow(entry: entry, selected: compact && index == clipboard.selection)
                                .id(entry.id)
                                .onTapGesture { clipboard.copy(entry) }
                                .onHover { if $0 && compact { clipboard.selection = index } }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: clipboard.selection) { i in
                    if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                }
            }
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject private var clipboard: ClipboardManager
    let entry: ClipEntry
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            preview.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12, design: entry.kind == .path || entry.kind == .color ? .monospaced : .default))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3)
                Text([entry.sourceApp, entry.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            if hovering {
                GlassIconButton(systemImage: entry.isPinned ? "pin.slash" : "pin", help: entry.isPinned ? "Unpin" : "Pin (kept forever)") {
                    clipboard.togglePin(entry)
                }
                GlassIconButton(systemImage: "trash", help: "Delete") { clipboard.remove(entry) }
            } else if entry.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .softFill(selected || hovering ? Theme.fillSelected : .clear, cornerRadius: 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Click to copy\n\n" + String(entry.text.prefix(500)))
        .contextMenu {
            Button("Copy") { clipboard.copy(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(entry) }
            if entry.kind == .url, let url = URL(string: entry.text) { Button("Open Link") { NSWorkspace.shared.open(url) } }
            if entry.kind == .path {
                Button("Show in Finder") {
                    let urls = entry.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { clipboard.remove(entry) }
        }
    }

    @ViewBuilder private var preview: some View {
        switch entry.kind {
        case .image:
            if let data = entry.imagePNG, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                kindIcon
            }
        case .color:
            if let c = ClipClassifier.rgba(entry.text) {
                RoundedRectangle(cornerRadius: 7).fill(Color(red: c.0, green: c.1, blue: c.2, opacity: c.3))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
            } else {
                kindIcon
            }
        default:
            kindIcon
        }
    }

    private var kindIcon: some View {
        Image(systemName: entry.kind.symbolName).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .frame(width: 30, height: 30).softFill(Theme.fill, cornerRadius: 7)
    }
}

/// Full-page clipboard history in the main window.
struct ClipboardView: View {
    @EnvironmentObject private var clipboard: ClipboardManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Search clipboard history", text: $clipboard.query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassCard(cornerRadius: 10)
                .frame(maxWidth: 360)
                Spacer()
                if let toast = clipboard.toast { Text(toast).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                Toggle("Record clipboard", isOn: $clipboard.isEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Turn off to stop recording new copies. Password-manager copies are never recorded.")
                Button("Clear") { clipboard.clearUnpinned() }
                    .help("Remove everything except pinned items")
            }
            ClipKindChips()
            ClipboardList()
                .glassCard()
            Text("Stored only on this Mac. Copies marked concealed by password managers are skipped. Open anywhere with ⌃⌥V.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .padding(28)
        .navigationTitle("Clipboard")
    }
}
