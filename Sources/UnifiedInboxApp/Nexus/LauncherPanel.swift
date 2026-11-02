import AppKit
import Carbon.HIToolbox
import NexusCore
import SwiftUI

/// Spotlight-style launcher panel (⌥Space). ↑/↓ to move, ↩ to launch, ⌘↩ to reveal in Finder, ⎋ to close.
@MainActor
final class LauncherPanelController: ObservableObject {
    @Published var selection = 0

    private weak var launcher: LauncherModel?
    /// Set by AppModel after init (needed for commands).
    weak var model: AppModel?

    var results: [PaletteResult] {
        guard let model, let launcher else { return [] }
        return model.paletteResults(for: launcher.query)
    }
    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(launcher: LauncherModel) {
        self.launcher = launcher
    }

    func setHotKeyEnabled(_ enabled: Bool) {
        if enabled, hotKey == nil {
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
                Task { @MainActor in self?.toggle() }
            }
            if hotKey == nil { NSLog("Launcher: ⌥Space is already used by another app") }
        } else if !enabled {
            hotKey = nil
        }
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { AppLock.shared.whenUnlocked { [weak self] in self?.show() } }
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func show() {
        guard let launcher else { return }
        launcher.query = ""
        selection = 0
        let panel = self.panel ?? makePanel(launcher: launcher)
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 4 - size.height))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Arrow keys / return while the panel is key (works on macOS 13, unlike onKeyPress).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isKeyWindow, let model else { return false }
        let results = self.results
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            selection = min(selection + 1, max(results.count - 1, 0))
        case kVK_UpArrow:
            selection = max(selection - 1, 0)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard results.indices.contains(selection) else { return true }
            let result = results[selection]
            close()
            if event.modifierFlags.contains(.command), case .item(let item) = result, item.kind != .url {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target)])
            } else {
                model.perform(result)
            }
        case kVK_Escape:
            close()
        default:
            return false
        }
        return true
    }

    private func makePanel(launcher: LauncherModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
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
        panel.contentView = NSHostingView(rootView: LauncherPanelView(close: { [weak self] in self?.close() })
            .environmentObject(launcher)
            .environmentObject(self))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        return panel
    }
}

struct LauncherPanelView: View {
    @EnvironmentObject private var launcher: LauncherModel
    @EnvironmentObject private var controller: LauncherPanelController
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = controller.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 16, weight: .light)).foregroundStyle(Theme.secondary)
                TextField("Apps, commands, aliases…  (type > for commands only)", text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.primary)
                    .focused($focused)
                Text("⌥Space").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2).softFill(Theme.fill, cornerRadius: 5)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            if results.isEmpty {
                ContentUnavailableLabel(title: launcher.query.isEmpty ? "Pin apps in Launcher to see them here" : "No matches",
                                        systemImage: launcher.query.isEmpty ? "pin" : "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if launcher.query.isEmpty {
                                SectionLabel(text: "Pinned & recent")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.top, 6)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                PaletteRow(result: result, selected: index == controller.selection)
                                    .id(result.id)
                                    .onTapGesture { close(); controller.model?.perform(result) }
                                    .onHover { if $0 { controller.selection = index } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: controller.selection) { i in
                        if results.indices.contains(i) { proxy.scrollTo(results[i].id) }
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Text("↑↓ select   ↩ run   ⌘↩ show in Finder   ⎋ close")
                Spacer()
                Text("\(launcher.config.items.count) items · \(launcher.aliases.aliases.count) aliases")
            }
            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 640, height: 440)
        .background(GlassBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onChange(of: launcher.query) { _ in controller.selection = 0 }
    }
}

/// One palette row: app/folder/link icon, command symbol, or alias.
struct PaletteRow: View {
    @EnvironmentObject private var launcher: LauncherModel
    let result: PaletteResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(kindLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .softFill(Theme.fill, cornerRadius: 4)
            if case .item(let item) = result, launcher.isMissing(item) {
                Text("Missing").font(.system(size: 10)).foregroundStyle(Theme.warning)
            }
            if selected { Text("↩").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .softFill(selected ? Theme.fillSelected : .clear, cornerRadius: 9)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch result {
        case .item(let item):
            Image(nsImage: launcher.icon(for: item)).resizable()
        case .command(let c):
            Image(systemName: c.symbol).font(.system(size: 14)).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28).softFill(Theme.fill, cornerRadius: 7)
        case .alias:
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 13)).foregroundStyle(Theme.priority)
                .frame(width: 28, height: 28).softFill(Theme.fill, cornerRadius: 7)
        }
    }

    private var title: String {
        switch result {
        case .item(let i): return i.title
        case .command(let c): return c.title
        case .alias(let a, let arg): return arg.map { "\(a.title): \($0)" } ?? a.title
        }
    }

    private var subtitle: String {
        switch result {
        case .item(let i): return i.kind == .url ? i.target : (i.target as NSString).abbreviatingWithTildeInPath
        case .command(let c): return c.subtitle
        case .alias(let a, _):
            switch a.target {
            case .url(let u): return "\(a.alias) → \(u)"
            case .app(let x): return "\(a.alias) → \(x)"
            case .command(let x): return "\(a.alias) → \(x)"
            }
        }
    }

    private var kindLabel: String {
        switch result {
        case .item(let i): return i.kind == .app ? "APP" : (i.kind == .folder ? "FOLDER" : "LINK")
        case .command: return "COMMAND"
        case .alias: return "ALIAS"
        }
    }
}
