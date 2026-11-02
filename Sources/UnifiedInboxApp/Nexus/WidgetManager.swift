import AppKit
import Combine
import InboxCore
import NexusCore
import SwiftUI

/// Owns the floating desktop widget windows (spec §5.5).
/// One NSPanel per widget; frames persist and are restored per display (spec §5.7 algorithm).
@MainActor
final class WidgetManager: ObservableObject {
    @Published private(set) var widgets: [WidgetInstance] = []
    @Published var editMode = false

    private let store = JSONFileStore<WidgetConfig>(url: JSONFileStore<WidgetConfig>.defaultURL("widgets"))
    private var panels: [UUID: NSPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var saveWork: DispatchWorkItem?
    private weak var model: AppModel?
    private let monitor: SystemMonitor

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        widgets = store.load()?.widgets ?? []
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restoreAllFrames() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Called once the app model exists (widgets need it for the inbox widget and environment).
    func attach(model: AppModel) {
        self.model = model
        for w in widgets where w.isVisible { showPanel(for: w) }
    }

    // MARK: Public API

    func add(_ kind: WidgetKind) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = WidgetLayout.placement(for: kind, existing: widgets.map(\.frame), in: bounds)
        let w = WidgetInstance(kind: kind, frame: frame, displayID: screen.flatMap(Self.displayID))
        widgets.append(w)
        showPanel(for: w)
        save()
    }

    func remove(_ id: UUID) {
        panels[id]?.orderOut(nil)
        panels[id] = nil
        widgets.removeAll { $0.id == id }
        save()
    }

    func duplicate(_ id: UUID) {
        guard let w = widgets.first(where: { $0.id == id }) else { return }
        var copy = w
        copy.id = UUID()
        copy.frame = w.frame.offsetBy(dx: 24, dy: -24)
        widgets.append(copy)
        showPanel(for: copy)
        save()
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        update(id) { $0.isVisible = visible }
        guard let w = widgets.first(where: { $0.id == id }) else { return }
        if visible { showPanel(for: w) } else { panels[id]?.orderOut(nil) }
    }

    func setAlwaysOnTop(_ id: UUID, _ value: Bool) {
        update(id) { $0.alwaysOnTop = value }
        panels[id]?.level = value ? .floating : .normal
    }

    func setOpacity(_ id: UUID, _ value: Double) {
        update(id) { $0.appearance.opacity = value }
    }

    func setShowHistory(_ id: UUID, _ value: Bool) {
        update(id) { $0.appearance.showHistory = value }
    }

    func showAll(_ visible: Bool) {
        for w in widgets { setVisible(w.id, visible) }
    }

    var anyVisible: Bool { widgets.contains(where: \.isVisible) }

    // MARK: Windows

    private func showPanel(for w: WidgetInstance) {
        if let existing = panels[w.id] {
            existing.orderFront(nil)
            return
        }
        guard let model else { return }
        let restored = WidgetLayout.restore(w, displays: Self.displays())
        let panel = WidgetPanel(contentRect: restored.frame,
                                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = w.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.minSize = WidgetKind.minimumSize
        panel.appearance = NSAppearance(named: .darkAqua)
        let id = w.id
        panel.contentView = NSHostingView(rootView: WidgetHost(id: id)
            .environmentObject(self)
            .environmentObject(monitor)
            .environmentObject(model)
            .environmentObject(model.presence))
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak panel] _ in
                Task { @MainActor in
                    guard let self, let panel else { return }
                    self.frameChanged(id, panel)
                }
            })
        }
        panels[id] = panel
        if restored.frame != w.frame || restored.displayID != w.displayID {
            update(id) { $0.frame = restored.frame; $0.displayID = restored.displayID }
        }
        panel.orderFront(nil)
    }

    private func frameChanged(_ id: UUID, _ panel: NSPanel) {
        let displayID = panel.screen.flatMap(Self.displayID)
        update(id) { $0.frame = panel.frame; $0.displayID = displayID }
    }

    /// Displays changed: re-run the restore algorithm so nothing is stranded off-screen.
    private func restoreAllFrames() {
        let displays = Self.displays()
        for w in widgets {
            let r = WidgetLayout.restore(w, displays: displays)
            panels[w.id]?.setFrame(r.frame, display: true)
            update(w.id) { $0.frame = r.frame; $0.displayID = r.displayID }
        }
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout WidgetInstance) -> Void) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        change(&widgets[i])
        save()
    }

    /// Debounced so dragging doesn't write to disk on every move event.
    private func save() {
        saveWork?.cancel()
        let config = WidgetConfig(widgets: widgets)
        let store = self.store
        let work = DispatchWorkItem { try? store.save(config) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func displays() -> [DisplayInfo] {
        let primary = NSScreen.screens.first
        return NSScreen.screens.compactMap { s in
            displayID(s).map { DisplayInfo(id: $0, visibleFrame: s.visibleFrame, isPrimary: s == primary) }
        }
    }
}

/// Borderless panels can't become key by default; allow it so context menus and resizing work.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
