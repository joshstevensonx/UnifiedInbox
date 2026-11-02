import AppKit
import InboxCore
import NexusCore

/// An action reachable from the ⌥Space palette (spec §7.1 "Command Palette").
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String = ""
    let symbol: String
    var keywords: [String] = []
    let run: @MainActor () -> Void
}

/// One row in the palette: a command, an alias hit, or a launcher item.
enum PaletteResult: Identifiable {
    case command(PaletteCommand)
    case alias(CommandAlias, argument: String?)
    case item(LauncherItem)

    var id: String {
        switch self {
        case .command(let c): return "cmd:" + c.id
        case .alias(let a, _): return "alias:" + a.id.uuidString
        case .item(let i): return "item:" + i.id.uuidString
        }
    }
}

extension AppModel {
    /// Every built-in command. Kept here so the palette, menu bar and docs share one list.
    func paletteCommands() -> [PaletteCommand] {
        var c: [PaletteCommand] = []

        // Navigation
        for s in AppSection.allCases {
            c.append(PaletteCommand(id: "go.\(s.rawValue)", title: "Go to \(s.title)", symbol: s.symbolName,
                                    keywords: ["open", "show", s.rawValue]) { [weak self] in
                self?.section = s; self?.openInbox()
            })
        }
        c.append(PaletteCommand(id: "inbox.unread", title: "Show Unread Messages", symbol: "circle.fill",
                                keywords: ["inbox", "mail", "messages"]) { [weak self] in self?.selectInbox(.unread) })
        c.append(PaletteCommand(id: "inbox.priority", title: "Show Priority Messages", symbol: "star.fill",
                                keywords: ["vip", "important"]) { [weak self] in self?.selectInbox(.priority) })
        c.append(PaletteCommand(id: "inbox.search", title: "Search Inbox", subtitle: "⌃⌥Space", symbol: "magnifyingglass",
                                keywords: ["find", "messages"]) { [weak self] in self?.showQuickLook() })
        c.append(PaletteCommand(id: "inbox.markAllRead", title: "Mark All Messages Read", symbol: "checkmark",
                                keywords: ["clear", "inbox"]) { [weak self] in
            self?.filter = .all; self?.markAllRead()
        })

        // Capture (spec §6.1, §3.5)
        c.append(PaletteCommand(id: "capture.region", title: "Screenshot Region", subtitle: "to clipboard", symbol: "rectangle.dashed",
                                keywords: ["capture", "screenshot", "snip"]) { [weak self] in self?.capture.screenshot(.region) })
        c.append(PaletteCommand(id: "capture.window", title: "Screenshot Window", symbol: "macwindow",
                                keywords: ["capture", "screenshot"]) { [weak self] in self?.capture.screenshot(.window) })
        c.append(PaletteCommand(id: "capture.full", title: "Screenshot Full Screen", symbol: "display",
                                keywords: ["capture", "screenshot"]) { [weak self] in self?.capture.screenshot(.fullScreen) })
        c.append(PaletteCommand(id: "capture.delayed", title: "Screenshot in 5 Seconds", symbol: "timer",
                                keywords: ["capture", "delay", "screenshot"]) { [weak self] in self?.capture.screenshot(.delayed(5)) })
        c.append(PaletteCommand(id: "capture.ocr", title: "Capture Text from Screen (OCR)", subtitle: "select a region, text is copied",
                                symbol: "text.viewfinder", keywords: ["ocr", "extract", "read", "copy text"]) { [weak self] in
            self?.capture.captureText()
        })

        // Clipboard (spec §14.3)
        c.append(PaletteCommand(id: "clipboard.show", title: "Clipboard History", subtitle: "⌃⌥V", symbol: "doc.on.clipboard",
                                keywords: ["paste", "copy", "history"]) { [weak self] in self?.clipboard.togglePanel() })
        c.append(PaletteCommand(id: "clipboard.clear", title: "Clear Clipboard History", subtitle: "keeps pinned items",
                                symbol: "trash", keywords: ["clipboard", "delete"]) { [weak self] in self?.clipboard.clearUnpinned() })

        // Media (spec §1.1)
        c.append(PaletteCommand(id: "media.playpause", title: "Play / Pause", subtitle: media.nowPlaying?.title ?? "Music or Spotify",
                                symbol: "playpause.fill", keywords: ["music", "spotify", "media", "pause", "play"]) { [weak self] in
            self?.media.playPause()
        })
        c.append(PaletteCommand(id: "media.next", title: "Next Track", symbol: "forward.fill",
                                keywords: ["music", "spotify", "skip"]) { [weak self] in self?.media.next() })
        c.append(PaletteCommand(id: "media.previous", title: "Previous Track", symbol: "backward.fill",
                                keywords: ["music", "spotify", "back"]) { [weak self] in self?.media.previous() })

        // Focus (spec §11.3)
        let pomo = focus.timer
        if pomo.phase == .idle {
            c.append(PaletteCommand(id: "focus.start", title: "Start Focus Session", subtitle: "\(Int(focus.config.pomodoro.focusMinutes)) min Pomodoro",
                                    symbol: "timer", keywords: ["pomodoro", "focus", "deep work"]) { [weak self] in self?.focus.start() })
        } else {
            c.append(PaletteCommand(id: "focus.toggle", title: pomo.isPaused ? "Resume Focus Timer" : "Pause Focus Timer",
                                    symbol: pomo.isPaused ? "play.fill" : "pause.fill", keywords: ["pomodoro", "focus"]) { [weak self] in
                self?.focus.togglePause()
            })
            c.append(PaletteCommand(id: "focus.stop", title: "Stop Focus Timer", symbol: "stop.fill",
                                    keywords: ["pomodoro", "focus", "end"]) { [weak self] in self?.focus.stop() })
        }
        c.append(PaletteCommand(id: "focus.newTask", title: "New Task…", subtitle: "e.g. Call Martin tomorrow !high #nexora",
                                symbol: "plus.circle", keywords: ["todo", "task", "add"]) { [weak self] in
            self?.section = .focus; self?.openInbox(); self?.focus.requestQuickAdd = true
        })

        // Widgets
        for kind in WidgetKind.allCases {
            c.append(PaletteCommand(id: "widget.add.\(kind.rawValue)", title: "Add \(kind.title) Widget", symbol: kind.symbolName,
                                    keywords: ["widget", "desktop", "floating"]) { [weak self] in self?.widgets.add(kind) })
        }
        c.append(PaletteCommand(id: "widget.toggleAll", title: widgets.anyVisible ? "Hide All Widgets" : "Show All Widgets",
                                symbol: "rectangle.on.rectangle", keywords: ["widgets"]) { [weak self] in
            guard let self else { return }
            self.widgets.showAll(!self.widgets.anyVisible)
        })

        // System
        c.append(PaletteCommand(id: "system.pauseMonitoring", title: monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring",
                                symbol: "waveform.path.ecg", keywords: ["cpu", "metrics"]) { [weak self] in
            self?.monitor.isPaused.toggle()
        })
        c.append(PaletteCommand(id: "system.privacy", title: privacyMode ? "Turn Off Privacy Mode" : "Turn On Privacy Mode",
                                symbol: "eye.slash", keywords: ["hide", "screen share"]) { [weak self] in self?.privacyMode.toggle() })
        c.append(PaletteCommand(id: "system.fullDisk", title: "Open Full Disk Access Settings", symbol: "lock.shield",
                                keywords: ["permission", "privacy"]) { [weak self] in self?.openFullDiskAccessSettings() })
        c.append(PaletteCommand(id: "app.settings", title: "Settings…", subtitle: "⌘,", symbol: "gearshape",
                                keywords: ["preferences", "options"]) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        c.append(PaletteCommand(id: "app.quit", title: "Quit Unified Inbox", symbol: "power", keywords: ["exit", "close"]) {
            NSApp.terminate(nil)
        })
        return c
    }

    /// Runs a palette result (used by the panel and the Launcher page).
    func perform(_ result: PaletteResult) {
        switch result {
        case .command(let c):
            c.run()
        case .item(let i):
            launcher.launch(i)
        case .alias(let a, let arg):
            switch a.target {
            case .url(let u):
                if let url = URL(string: AliasConfig.expand(u, argument: arg)) { NSWorkspace.shared.open(url) }
            case .app(let idOrPath):
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: idOrPath) ?? URL(fileURLWithPath: idOrPath)
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
            case .command(let id):
                paletteCommands().first { $0.id == id }?.run()
            }
        }
    }

    /// Ranked palette results: alias hit first, then commands and launcher items by score.
    /// Prefix the query with ">" to search commands only.
    func paletteResults(for rawQuery: String) -> [PaletteResult] {
        var query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return launcher.results.map { .item($0) } }
        let commandsOnly = query.hasPrefix(">")
        if commandsOnly { query = String(query.dropFirst()).trimmingCharacters(in: .whitespaces) }

        var scored: [(PaletteResult, Int)] = []
        if !commandsOnly, let hit = launcher.aliases.resolve(query) {
            scored.append((.alias(hit.alias, argument: hit.argument), 5000))
        }
        for cmd in paletteCommands() {
            if query.isEmpty { scored.append((.command(cmd), 0)); continue }
            if let s = PaletteRanking.score(title: cmd.title, keywords: cmd.keywords, query: query) {
                scored.append((.command(cmd), s - 10))   // apps win exact ties
            }
        }
        if !commandsOnly {
            for item in launcher.config.items {
                if let s = LauncherSearch.score(item.title, query: query) {
                    scored.append((.item(item), s + (item.isPinned ? 8 : 0) + min(item.useCount, 20)))
                }
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
    }
}
