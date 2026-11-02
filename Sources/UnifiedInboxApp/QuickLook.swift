import AppKit
import Carbon.HIToolbox
import InboxCore
import SwiftUI

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
/// One shared event handler dispatches by hotkey id, so several hotkeys can coexist.
final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Defaults to ⌃⌥Space. Returns nil if another app already owns the combination.
    init?(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey), action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5549_4E42), id: id) // "UINB"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Self.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Floating Spotlight-style panel with search + latest unread, summoned from anywhere.
@MainActor
final class QuickLookController {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    /// The ⌃⌥Space shortcut is registered by `HotkeyManager` (id "quickLook").
    init(model: AppModel) {
        self.model = model
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { AppLock.shared.whenUnlocked { [weak self] in self?.show() } }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        // Centre on the screen that has the mouse, upper third (like Spotlight).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
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
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(
            rootView: QuickLookView(close: { [weak self] in self?.close() })
                .environmentObject(model)
                .environmentObject(model.presence))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        return panel
    }
}

struct QuickLookView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presence: AppPresenceMonitor
    let close: () -> Void
    @State private var query = ""
    @State private var results: [InboxItem] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.secondary)
                TextField("Search, or browse unread", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.primary)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { open(first) } }
                Text("⌃⌥Space")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .softFill(Theme.fill, cornerRadius: 5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ClosedAppsBanner(compact: true)
            if results.isEmpty {
                ContentUnavailableLabel(title: query.isEmpty ? "All caught up" : "No results",
                                        systemImage: query.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { item in
                            Button { open(item) } label: {
                                ItemRow(item: item, hideBody: model.privacyMode)
                            }
                            .buttonStyle(.plain)
                            .help(model.privacyMode ? "Open in \(item.platform.displayName)" : ItemRow.tooltip(for: item))
                        }
                    }
                    .padding(8)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Text(query.isEmpty ? "\(model.totalUnread) unread" : "\(results.count) results")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                Text("↩ open   ⎋ close").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Button("Open Inbox") {
                    close()
                    model.openInbox()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 460)
        .background(GlassBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { searchFocused = true; reload() }
        .onChange(of: query) { _ in reload() }
        .onReceive(model.$recentUnread) { _ in if query.isEmpty { reload() } }
        .onExitCommand { close() }
    }

    private func reload() {
        guard let store = model.store else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        results = (try? store.fetch(filter: q.isEmpty ? .unread : .all, search: q.isEmpty ? nil : q, limit: 25)) ?? []
    }

    private func open(_ item: InboxItem) {
        close()
        model.open(item)
    }
}
