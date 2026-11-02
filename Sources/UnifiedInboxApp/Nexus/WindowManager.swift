import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import NexusCore
import SwiftUI

// MARK: - Accessibility helpers (public AX API only)

enum AX {
    /// Whether this app may control other apps' windows. `prompt: true` shows the system dialog once.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        return (w as! AXUIElement)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func title(_ w: AXUIElement) -> String { attribute(w, kAXTitleAttribute) as? String ?? "" }

    static func isMinimized(_ w: AXUIElement) -> Bool { attribute(w, kAXMinimizedAttribute) as? Bool ?? false }

    /// Top-left-origin frame in global screen coordinates.
    static func frame(_ w: AXUIElement) -> WindowRect? {
        guard let p = attribute(w, kAXPositionAttribute), let s = attribute(w, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return WindowRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    static func setFrame(_ w: AXUIElement, _ r: WindowRect) {
        var point = CGPoint(x: r.x, y: r.y)
        var size = CGSize(width: r.width, height: r.height)
        guard let pv = AXValueCreate(.cgPoint, &point), let sv = AXValueCreate(.cgSize, &size) else { return }
        // Size → position → size: moving to another display can clamp the first resize.
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    }
}

// MARK: - Window manager: tiling + workspaces

@MainActor
final class WindowManager: ObservableObject {
    @Published private(set) var trusted = AX.isTrusted()
    @Published var config: WorkspaceConfig { didSet { save() } }
    @Published private(set) var lastMessage: String?
    /// Name of the app whose window the tiling buttons act on.
    @Published private(set) var targetAppName: String?

    private let store = JSONFileStore<WorkspaceConfig>(url: JSONFileStore<WorkspaceConfig>.defaultURL("workspaces"))
    private var lastExternalPID: pid_t?
    private var lastLayout: (pid: pid_t, layout: TileLayout, at: Date)?
    private var observers: [NSObjectProtocol] = []

    /// Default tiling shortcuts (⌃⌥ + key), registered and rebindable in `HotkeyManager`.
    static let defaultBindings: [(TileLayout, UInt32, String)] = [
        (.leftHalf, UInt32(kVK_LeftArrow), "⌃⌥←"),
        (.rightHalf, UInt32(kVK_RightArrow), "⌃⌥→"),
        (.topHalf, UInt32(kVK_UpArrow), "⌃⌥↑"),
        (.bottomHalf, UInt32(kVK_DownArrow), "⌃⌥↓"),
        (.maximize, UInt32(kVK_Return), "⌃⌥↩"),
        (.center, UInt32(kVK_ANSI_C), "⌃⌥C"),
    ]

    init() {
        config = JSONFileStore<WorkspaceConfig>(url: JSONFileStore<WorkspaceConfig>.defaultURL("workspaces")).load() ?? WorkspaceConfig()
        let me = ProcessInfo.processInfo.processIdentifier
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier, name = app?.localizedName
            Task { @MainActor in
                guard let self, let pid, pid != me else { return }
                self.lastExternalPID = pid
                self.targetAppName = name
            }
        })
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            lastExternalPID = front.processIdentifier
            targetAppName = front.localizedName
        }
    }

    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func refreshTrust() { trusted = AX.isTrusted() }

    func requestTrust() {
        trusted = AX.isTrusted(prompt: true)
        if !trusted { AX.openSettings() }
    }

    private func save() { try? store.save(config) }

    private func flash(_ text: String) {
        lastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.lastMessage == text { self?.lastMessage = nil }
        }
    }

    // MARK: Tiling

    /// The app to act on: the frontmost app, or the last other app when Unified Inbox itself is in front.
    private var targetPID: pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front.processIdentifier }
        return lastExternalPID
    }

    /// Screens' visible frames (no menu bar / Dock) in top-left-origin coordinates.
    static func visibleScreens() -> [WindowRect] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = Double(primary.frame.height)
        return screens.map {
            let f = $0.visibleFrame
            return TilingGeometry.flip(WindowRect(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryHeight: h)
        }
    }

    func tile(_ requested: TileLayout) {
        refreshTrust()
        guard trusted else { requestTrust(); return }
        guard let pid = targetPID, let window = AX.focusedWindow(pid: pid), let current = AX.frame(window) else {
            flash("No window to arrange. Click the window first.")
            return
        }
        // Pressing the same half again within 2 s cycles 1/2 → 1/3 → 2/3.
        var layout = requested
        if let last = lastLayout, last.pid == pid, Date().timeIntervalSince(last.at) < 2 {
            layout = TilingGeometry.cycled(requested, previous: last.layout)
        }
        let screens = Self.visibleScreens()
        guard !screens.isEmpty else { return }
        let screen = screens[TilingGeometry.screenIndex(for: current, screens: screens)]
        AX.setFrame(window, TilingGeometry.frame(for: layout, in: screen, current: current, gap: config.tileGap))
        lastLayout = (pid, layout, Date())
    }

    /// Moves the focused window to the next display, keeping its relative position.
    func moveToNextScreen() {
        refreshTrust()
        guard trusted else { requestTrust(); return }
        let screens = Self.visibleScreens()
        guard screens.count > 1, let pid = targetPID, let w = AX.focusedWindow(pid: pid), let f = AX.frame(w) else { return }
        let i = TilingGeometry.screenIndex(for: f, screens: screens)
        let from = screens[i], to = screens[(i + 1) % screens.count]
        let rx = (f.x - from.x) / max(from.width, 1), ry = (f.y - from.y) / max(from.height, 1)
        let width = min(f.width, to.width), height = min(f.height, to.height)
        AX.setFrame(w, WindowRect(x: (to.x + rx * to.width).rounded(), y: (to.y + ry * to.height).rounded(), width: width, height: height))
    }

    // MARK: Workspaces

    /// Snapshot of visible regular apps and (with Accessibility) their window frames.
    func captureWorkspace(named name: String) -> Workspace {
        refreshTrust()
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != me && $0.bundleIdentifier != nil
        }
        let saved: [WorkspaceApp] = apps.map { app in
            let windows: [SavedWindow] = trusted ? AX.windows(pid: app.processIdentifier).compactMap { w in
                guard !AX.isMinimized(w), let f = AX.frame(w) else { return nil }
                return SavedWindow(title: AX.title(w), frame: f)
            } : []
            return WorkspaceApp(bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? "App",
                                path: app.bundleURL?.path, windows: windows)
        }
        return Workspace(name: name, apps: saved.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    func saveCurrent(named name: String) {
        let ws = captureWorkspace(named: name)
        config.workspaces.append(ws)
        flash("Saved “\(name)”: \(ws.apps.count) apps, \(ws.windowCount) windows")
    }

    func update(_ ws: Workspace) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        var fresh = captureWorkspace(named: ws.name)
        fresh.id = ws.id
        fresh.hideOthers = ws.hideOthers
        fresh.createdAt = ws.createdAt
        config.workspaces[i] = fresh
        flash("Updated “\(ws.name)”")
    }

    func delete(_ ws: Workspace) { config.workspaces.removeAll { $0.id == ws.id } }

    func rename(_ ws: Workspace, to name: String) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == ws.id }), !name.isEmpty else { return }
        config.workspaces[i].name = name
    }

    func setHideOthers(_ ws: Workspace, _ on: Bool) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        config.workspaces[i].hideOthers = on
    }

    /// Opens the workspace's apps (in the background), then puts their windows back. Window frames
    /// are applied twice (after 1.5 s and 4 s) because freshly launched apps open windows late.
    func restore(_ ws: Workspace) {
        refreshTrust()
        let running = NSWorkspace.shared.runningApplications
        for app in ws.apps where !running.contains(where: { $0.bundleIdentifier == app.bundleId }) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId)
                ?? app.path.map { URL(fileURLWithPath: $0) }
            guard let url else { continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }
        for app in running where app.activationPolicy == .regular {
            let inWorkspace = ws.apps.contains { $0.bundleId == app.bundleIdentifier }
            if inWorkspace, app.isHidden { app.unhide() }
            if ws.hideOthers, !inWorkspace, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.hide() }
        }
        guard trusted else {
            flash("Opened apps. Allow Accessibility to restore window positions too.")
            return
        }
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.applyFrames(ws) }
        }
        flash("Switching to “\(ws.name)”…")
    }

    private func applyFrames(_ ws: Workspace) {
        let running = NSWorkspace.shared.runningApplications
        for app in ws.apps where !app.windows.isEmpty {
            guard let pid = running.first(where: { $0.bundleIdentifier == app.bundleId })?.processIdentifier else { continue }
            let windows = AX.windows(pid: pid).filter { !AX.isMinimized($0) }
            for (index, frame) in Workspace.match(saved: app.windows, currentTitles: windows.map(AX.title)) {
                AX.setFrame(windows[index], frame)
            }
        }
    }
}

// MARK: - Views

struct WindowsView: View {
    @EnvironmentObject private var windows: WindowManager
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Tiling").tag(0)
                    Text("Workspaces").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                if let msg = windows.lastMessage {
                    Text(msg).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if !windows.trusted {
                GlassBanner(systemImage: "hand.raised.fill", tint: Theme.warning,
                            message: "Window tiling and restoring window positions need Accessibility permission. Workspaces can still reopen apps without it.") {
                    Button("Allow…") { windows.requestTrust() }
                    Button("Check Again") { windows.refreshTrust() }
                }
            }
            if tab == 0 { TilingPanel() } else { WorkspacesPanel() }
            Spacer(minLength: 0)
        }
        .padding(28)
        .navigationTitle("Windows")
        .onAppear { windows.refreshTrust() }
    }
}

struct TilingPanel: View {
    @EnvironmentObject private var windows: WindowManager
    @EnvironmentObject private var hotkeys: HotkeyManager
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arranges the focused window of \(windows.targetAppName ?? "the last app you used"). Press a half again within 2 s to cycle ½ → ⅓ → ⅔.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(TileLayout.allCases) { layout in
                    Button { windows.tile(layout) } label: {
                        VStack(spacing: 8) {
                            TilePreview(layout: layout).frame(width: 72, height: 46)
                            Text(layout.title).font(.system(size: 11)).foregroundStyle(Theme.primary)
                            if !hotkeys.display("tile.\(layout.rawValue)").isEmpty {
                                Text(hotkeys.display("tile.\(layout.rawValue)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .glassCard(cornerRadius: Theme.smallRadius)
                    }
                    .buttonStyle(.plain)
                    .help("\(layout.title) for the focused window")
                }
            }
            HStack(spacing: 16) {
                Button("Move to Next Display") { windows.moveToNextScreen() }
                Stepper("Gap between windows: \(Int(windows.config.tileGap)) pt", value: $windows.config.tileGap, in: 0...40, step: 2)
                    .frame(maxWidth: 280)
            }
            .font(.system(size: 12))
        }
    }
}

/// Mini screen with the tile highlighted.
struct TilePreview: View {
    let layout: TileLayout

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.secondary, lineWidth: 1)
                let u = layout.unitRect ?? (0.25, 0.2, 0.5, 0.6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: max(geo.size.width * u.w - 4, 2), height: max(geo.size.height * u.h - 4, 2))
                    .offset(x: geo.size.width * u.x + 2, y: geo.size.height * u.y + 2)
            }
        }
    }
}

struct WorkspacesPanel: View {
    @EnvironmentObject private var windows: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Save the apps and window positions you have open now, then switch back to them in one click (also from ⌥Space).")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Save Current…") {
                    if let name = TextPrompt.ask(title: "Save workspace", message: "For example Coding, Writing or Calls.") {
                        windows.saveCurrent(named: name)
                    }
                }
            }
            if windows.config.workspaces.isEmpty {
                Text("No workspaces yet.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 100).glassCard()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(windows.config.workspaces) { ws in row(ws) }
                    }
                }
            }
        }
    }

    private func row(_ ws: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                Text("\(ws.apps.map(\.name).prefix(6).joined(separator: ", "))\(ws.apps.count > 6 ? "…" : "") · \(ws.windowCount) windows")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle("Hide others", isOn: Binding(get: { ws.hideOthers }, set: { windows.setHideOthers(ws, $0) }))
                .toggleStyle(.checkbox).font(.system(size: 11))
                .help("Hide apps that aren't part of this workspace when switching")
            Button("Switch") { windows.restore(ws) }
            Menu {
                Button("Update from Current Windows") { windows.update(ws) }
                Button("Rename…") {
                    if let name = TextPrompt.ask(title: "Rename workspace", message: "", initial: ws.name) { windows.rename(ws, to: name) }
                }
                Divider()
                Button("Delete", role: .destructive) { windows.delete(ws) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(12)
        .glassCard(cornerRadius: Theme.smallRadius)
    }
}

/// Small modal text prompt (NSAlert with a text field).
enum TextPrompt {
    @MainActor
    static func ask(title: String, message: String, initial: String = "", button: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension AppModel {
    func windowPaletteCommands() -> [PaletteCommand] {
        var c: [PaletteCommand] = []
        for layout in TileLayout.allCases {
            c.append(PaletteCommand(id: "window.\(layout.rawValue)", title: "Window: \(layout.title)", symbol: "rectangle.split.2x1",
                                    keywords: ["tile", "snap", "window", "arrange"]) { [weak self] in self?.windows.tile(layout) })
        }
        c.append(PaletteCommand(id: "window.nextScreen", title: "Window: Move to Next Display", symbol: "display.2",
                                keywords: ["monitor", "screen", "window"]) { [weak self] in self?.windows.moveToNextScreen() })
        for ws in windows.config.workspaces {
            c.append(PaletteCommand(id: "workspace.\(ws.id.uuidString)", title: "Switch to Workspace: \(ws.name)",
                                    subtitle: "\(ws.apps.count) apps", symbol: "rectangle.3.group",
                                    keywords: ["workspace", "layout", "space"]) { [weak self] in self?.windows.restore(ws) })
        }
        c.append(PaletteCommand(id: "workspace.save", title: "Save Current Workspace…", symbol: "plus.rectangle.on.rectangle",
                                keywords: ["workspace", "layout"]) { [weak self] in
            if let name = TextPrompt.ask(title: "Save workspace", message: "") { self?.windows.saveCurrent(named: name) }
        })
        return c
    }
}
