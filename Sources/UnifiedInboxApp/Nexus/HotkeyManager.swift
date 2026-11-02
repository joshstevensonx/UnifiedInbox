import AppKit
import Carbon.HIToolbox
import Combine
import NexusCore
import SwiftUI

/// One place for every global shortcut: defaults, user rebinding, conflicts, and keys another app owns.
@MainActor
final class HotkeyManager: ObservableObject {
    struct Action: Identifiable {
        let id: String
        let title: String
        let group: String
        let defaultBinding: HotkeyBinding
        let run: @MainActor () -> Void
    }

    @Published private(set) var actions: [Action] = []
    @Published private(set) var config: HotkeyConfig
    /// Actions whose shortcut couldn't be registered (usually another app owns it).
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var recordingId: String?

    /// Groups switched off by the older per-feature toggles (quick look, launcher, tiling).
    private var disabledGroups: Set<String> = []
    private var registered: [String: GlobalHotKey] = [:]
    private var recorder: Any?
    private let store = JSONFileStore<HotkeyConfig>(url: JSONFileStore<HotkeyConfig>.defaultURL("hotkeys"))

    init() {
        config = JSONFileStore<HotkeyConfig>(url: JSONFileStore<HotkeyConfig>.defaultURL("hotkeys")).load() ?? HotkeyConfig()
    }

    func register(_ new: [Action]) {
        let ids = Set(new.map(\.id))
        actions.removeAll { ids.contains($0.id) }
        actions += new
        apply()
    }

    func binding(_ id: String) -> HotkeyBinding {
        guard let a = actions.first(where: { $0.id == id }) else { return HotkeyBinding(combo: nil, enabled: false) }
        return config.binding(for: id, default: a.defaultBinding)
    }

    func display(_ id: String) -> String { binding(id).combo?.display ?? "" }

    var effective: [String: HotkeyBinding] {
        Dictionary(uniqueKeysWithValues: actions.map { a in
            var b = binding(a.id)
            if disabledGroups.contains(a.group) { b.enabled = false }
            return (a.id, b)
        })
    }

    var conflicts: [KeyCombo: [String]] { HotkeyConfig.conflicts(effective) }

    func isConflicting(_ id: String) -> Bool { conflicts.values.contains { $0.contains(id) } }

    func setGroupEnabled(_ group: String, _ on: Bool) {
        if on { disabledGroups.remove(group) } else { disabledGroups.insert(group) }
        apply()
    }

    func set(_ id: String, combo: KeyCombo?) {
        guard let a = actions.first(where: { $0.id == id }) else { return }
        var b = binding(id)
        b.combo = combo
        b.enabled = combo != nil
        config.set(id, b, default: a.defaultBinding)
        save()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let a = actions.first(where: { $0.id == id }) else { return }
        var b = binding(id)
        b.enabled = on
        config.set(id, b, default: a.defaultBinding)
        save()
    }

    func reset(_ id: String) {
        config.overrides[id] = nil
        save()
    }

    func resetAll() {
        config.overrides = [:]
        save()
    }

    private func save() {
        try? store.save(config)
        apply()
    }

    /// (Re)registers every enabled, non-conflicting shortcut. The first action (by list order) keeps a shared combo.
    func apply() {
        registered = [:]
        var taken = Set<KeyCombo>()
        var failures = Set<String>()
        guard recordingId == nil else { failed = []; return }   // paused while recording a new combo
        let eff = effective
        for a in actions {
            guard let b = eff[a.id], b.enabled, let combo = b.combo, !taken.contains(combo) else { continue }
            taken.insert(combo)
            let run = a.run
            if let hk = GlobalHotKey(keyCode: combo.keyCode, modifiers: combo.modifiers.rawValue, action: {
                Task { @MainActor in run() }
            }) {
                registered[a.id] = hk
            } else {
                failures.insert(a.id)
            }
        }
        failed = failures
    }

    // MARK: Recording

    /// Captures the next key press as the new combo. ⎋ cancels, ⌫ clears the shortcut.
    func startRecording(_ id: String) {
        stopRecording()
        recordingId = id
        apply()   // unregisters everything so the combo reaches us
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let rid = self.recordingId else { return event }
            let code = UInt32(event.keyCode)
            let mods = Self.modifiers(event.modifierFlags)
            if code == UInt32(kVK_Escape), mods.isEmpty {
                self.stopRecording()
            } else if code == UInt32(kVK_Delete), mods.isEmpty {
                self.stopRecording()
                self.set(rid, combo: nil)
            } else if !KeyNames.modifierKeyCodes.contains(code) {
                let combo = KeyCombo(keyCode: code, modifiers: mods)
                if combo.isValidGlobal {
                    self.stopRecording()
                    self.set(rid, combo: combo)
                } else {
                    NSSound.beep()   // needs ⌃, ⌥ or ⌘
                }
            }
            return nil
        }
    }

    func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        if recordingId != nil {
            recordingId = nil
            apply()
        }
    }

    static func modifiers(_ f: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var m: HotkeyModifiers = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }
}

// MARK: - Default actions

extension AppModel {
    private static func combo(_ key: Int, _ mods: HotkeyModifiers) -> HotkeyBinding {
        HotkeyBinding(combo: KeyCombo(keyCode: UInt32(key), modifiers: mods))
    }

    private static let unassigned = HotkeyBinding(combo: nil, enabled: false)

    /// Every global shortcut the app offers. Defaults match the shortcuts shipped before the registry.
    func registerHotkeys() {
        typealias A = HotkeyManager.Action
        var list: [A] = [
            A(id: "quickLook", title: "Quick look (search inbox)", group: "quickLook",
              defaultBinding: Self.combo(kVK_Space, [.control, .option])) { [weak self] in self?.showQuickLook() },
            A(id: "launcher", title: "Launcher and command palette", group: "launcher",
              defaultBinding: Self.combo(kVK_Space, [.option])) { [weak self] in self?.showLauncher() },
            A(id: "clipboard", title: "Clipboard history", group: "clipboard",
              defaultBinding: Self.combo(kVK_ANSI_V, [.control, .option])) { [weak self] in self?.clipboard.togglePanel() },
        ]
        for (layout, key, _) in WindowManager.defaultBindings {
            list.append(A(id: "tile.\(layout.rawValue)", title: "Window: \(layout.title)", group: "tiling",
                          defaultBinding: Self.combo(Int(key), [.control, .option])) { [weak self] in self?.windows.tile(layout) })
        }
        for layout in TileLayout.allCases where !WindowManager.defaultBindings.contains(where: { $0.0 == layout }) {
            list.append(A(id: "tile.\(layout.rawValue)", title: "Window: \(layout.title)", group: "tiling",
                          defaultBinding: Self.unassigned) { [weak self] in self?.windows.tile(layout) })
        }
        list += [
            A(id: "window.nextScreen", title: "Window: Move to Next Display", group: "tiling",
              defaultBinding: Self.unassigned) { [weak self] in self?.windows.moveToNextScreen() },
            A(id: "notes.today", title: "Open today's note", group: "other", defaultBinding: Self.unassigned) { [weak self] in
                self?.notes.openToday(); self?.section = .notes; self?.openInbox()
            },
            A(id: "focus.toggle", title: "Start / stop focus session", group: "other", defaultBinding: Self.unassigned) { [weak self] in
                guard let self else { return }
                if self.focus.timer.phase == .idle { self.focus.start() } else { self.focus.stop() }
            },
            A(id: "capture.region", title: "Screenshot region", group: "other", defaultBinding: Self.unassigned) { [weak self] in
                self?.capture.screenshot(.region)
            },
            A(id: "capture.ocr", title: "Copy text from screen (OCR)", group: "other", defaultBinding: Self.unassigned) { [weak self] in
                self?.capture.captureText()
            },
            A(id: "app.lock", title: "Lock the app", group: "other", defaultBinding: Self.unassigned) { [weak self] in self?.lock.lock() },
            A(id: "media.playPause", title: "Play / pause music", group: "other", defaultBinding: Self.unassigned) { [weak self] in
                self?.media.playPause()
            },
        ]
        hotkeys.register(list)
        hotkeys.setGroupEnabled("quickLook", quickLookHotKey)
        hotkeys.setGroupEnabled("launcher", launcherHotKey)
        hotkeys.setGroupEnabled("tiling", tilingHotKeys)
    }
}

// MARK: - Settings UI

struct HotkeySettings: View {
    @EnvironmentObject private var hotkeys: HotkeyManager

    private var groups: [(String, String)] {
        [("quickLook", "Inbox"), ("launcher", "Launcher"), ("clipboard", "Clipboard"), ("tiling", "Windows"), ("other", "Other")]
    }

    var body: some View {
        Section {
            ForEach(groups, id: \.0) { group, title in
                let items = hotkeys.actions.filter { $0.group == group }
                if !items.isEmpty {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(items) { a in row(a) }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { hotkeys.resetAll() }
            }
        } header: {
            Text("Global shortcuts (work in any app)")
        } footer: {
            Text("Click a shortcut, then press the new keys (⌃, ⌥ or ⌘ plus a key). ⎋ cancels, ⌫ removes it. A ⚠︎ means another app already uses that combination.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ a: HotkeyManager.Action) -> some View {
        let b = hotkeys.binding(a.id)
        let recording = hotkeys.recordingId == a.id
        return HStack {
            Toggle(a.title, isOn: Binding(get: { b.enabled && b.combo != nil }, set: { hotkeys.setEnabled(a.id, $0) }))
                .disabled(b.combo == nil)
            Spacer()
            if hotkeys.failed.contains(a.id) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Couldn't register: another app already uses \(b.combo?.display ?? "this shortcut")")
            } else if hotkeys.isConflicting(a.id) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    .help("The same shortcut is assigned to another action; only the first one works")
            }
            Button {
                recording ? hotkeys.stopRecording() : hotkeys.startRecording(a.id)
            } label: {
                Text(recording ? "Press keys…" : (b.combo?.display ?? "Record"))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 90)
            }
            .help("Click, then press the new shortcut")
            if hotkeys.config.overrides[a.id] != nil {
                Button { hotkeys.reset(a.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to the default (\(a.defaultBinding.combo?.display ?? "none"))")
            }
        }
    }
}
