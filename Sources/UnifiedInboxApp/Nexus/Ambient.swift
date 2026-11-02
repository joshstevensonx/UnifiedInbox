import AppKit
import Combine
import InboxCore
import NexusCore
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Appearance keys

enum AppearanceKeys {
    static let accentHex = "accentHex"
    static let density = "density"
    static let ambientStyle = "ambientStyle"
    static let hotCorner = "hotCorner"
    static let digestEnabled = "digestEnabled"
    static let digestTime = "digestTime"
    static let digestLastDay = "digestLastDay"
}

// MARK: - Hot corner → launcher

/// Polls the pointer position (no permission needed) while a corner is chosen.
@MainActor
final class HotCornerMonitor {
    private var detector = HotCornerDetector()
    private var timer: Timer?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        apply(ScreenCorner(rawValue: UserDefaults.standard.string(forKey: AppearanceKeys.hotCorner) ?? "") ?? .off)
    }

    func apply(_ corner: ScreenCorner) {
        detector.corner = corner
        timer?.invalidate()
        timer = nil
        guard corner != .off else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let p = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { WindowRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
        // Ignore while a mouse button is held (dragging windows into corners).
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if detector.update(x: p.x, y: p.y, screens: screens, now: Date()) { action() }
    }
}

// MARK: - Ambient clock

@MainActor
final class AmbientController {
    private var window: NSWindow?
    private var monitor: Any?

    func toggle(model: AppModel) {
        if window != nil { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let root = AmbientView(close: { [weak self] in self?.close() })
            .environmentObject(model)
            .environmentObject(model.monitor)
            .environmentObject(model.focus)
            .environmentObject(model.habits)
        w.contentView = NSHostingView(rootView: root)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(true)
        window = w
        model.monitor.subscribe()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            if e.type == .leftMouseDown || e.keyCode == 53 { self?.close(); return nil }
            return e
        }
        onClose = { model.monitor.unsubscribe() }
    }

    private var onClose: (() -> Void)?

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
        onClose?()
        onClose = nil
    }
}

struct AmbientView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var focus: FocusModel
    @EnvironmentObject private var habits: HabitsModel
    @AppStorage(AppearanceKeys.ambientStyle) private var style = "digital"
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            let minute = Calendar.current.component(.minute, from: now)
            // Slow drift (anti burn-in) and a gently shifting background hue.
            let drift = CGSize(width: Double((minute * 37) % 41) - 20, height: Double((minute * 53) % 31) - 15)
            let hue = Double(Calendar.current.component(.hour, from: now) * 60 + minute) / 1440
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.12), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 28) {
                    if style == "analog" {
                        AnalogClock(date: now).frame(width: 320, height: 320)
                    } else {
                        Text(now.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 150, weight: .ultraLight, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 40) {
                        stat("tray", model.totalUnread > 0 ? "\(model.totalUnread) unread" : "Inbox clear")
                        if let t = focus.menuBarText { stat("timer", t) }
                        if !habits.dueToday.isEmpty { stat("checkmark.seal", "\(habits.doneTodayCount)/\(habits.dueToday.count) habits") }
                        if let b = monitor.snapshot.batteryText { stat("battery.75", b) }
                        if let c = monitor.snapshot.cpuText { stat("cpu", "CPU \(c)") }
                    }
                }
                .offset(drift)
                .animation(.easeInOut(duration: 3), value: minute)
            }
        }
        .overlay(alignment: .bottom) {
            Text("Click or press esc to close").font(.system(size: 11)).foregroundStyle(.white.opacity(0.2)).padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 17, weight: .light)).foregroundStyle(.white.opacity(0.6))
    }
}

struct AnalogClock: View {
    let date: Date

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r + 1, y: c.y - r + 1, width: 2 * r - 2, height: 2 * r - 2)),
                       with: .color(.white.opacity(0.15)), lineWidth: 1)
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let p1 = CGPoint(x: c.x + sin(a) * r * 0.86, y: c.y - cos(a) * r * 0.86)
                let p2 = CGPoint(x: c.x + sin(a) * r * 0.94, y: c.y - cos(a) * r * 0.94)
                var tick = Path(); tick.move(to: p1); tick.addLine(to: p2)
                ctx.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 2)
            }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let sec = Double(comps.second ?? 0), min = Double(comps.minute ?? 0) + sec / 60
            let hr = Double((comps.hour ?? 0) % 12) + min / 60
            func hand(_ fraction: Double, _ length: Double, _ width: Double, _ color: Color) {
                let a = fraction * 2 * .pi
                var p = Path(); p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + sin(a) * r * length, y: c.y - cos(a) * r * length))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(hr / 12, 0.5, 6, .white.opacity(0.9))
            hand(min / 60, 0.75, 4, .white.opacity(0.8))
            hand(sec / 60, 0.85, 1.5, Theme.accent)
        }
    }
}

// MARK: - Daily digest

extension AppModel {
    func digest(for day: Date = Date()) -> (DailyDigest, [InboxItem]) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? day
        let items = (try? store?.fetch(from: start, to: end)) ?? []
        return (DailyDigest.make(items, day: day), items)
    }

    /// Called every minute: posts the digest notification once a day at the chosen time.
    func checkDigestSchedule(now: Date = Date()) {
        let d = UserDefaults.standard
        guard d.bool(forKey: AppearanceKeys.digestEnabled) else { return }
        let time = d.string(forKey: AppearanceKeys.digestTime) ?? "18:00"
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        guard (c.hour ?? 0, c.minute ?? 0) >= (parts[0], parts[1]) else { return }
        let today = UsageLog.dayKey(now)
        guard d.string(forKey: AppearanceKeys.digestLastDay) != today else { return }
        d.set(today, forKey: AppearanceKeys.digestLastDay)
        let (digest, _) = self.digest(for: now)
        let body = privacyMode ? "\(digest.total) messages, \(digest.unread) unread." : digest.headline
        UNUserNotificationCenterSafe.post(id: "daily-digest", title: "Your daily digest", body: body)
    }
}

/// On-device summary with Apple's FoundationModels framework (macOS 26+, Apple Intelligence on).
/// Returns nil when the framework or model isn't available; the extractive digest is shown either way.
enum OnDeviceSummary {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func summarize(_ prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: "You write short, factual summaries of the user's messages.")
            return try? await session.respond(to: prompt).content
        }
        #endif
        return nil
    }
}

struct DigestSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var notes: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var aiSummary: String?
    @State private var summarizing = false

    var body: some View {
        let result = model.digest(for: day)
        let digest = result.0, items = result.1
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GlassIconButton(systemImage: "chevron.left", help: "Previous day") { shift(-1) }
                Text(day.formatted(date: .complete, time: .omitted)).font(.system(size: 15, weight: .semibold))
                GlassIconButton(systemImage: "chevron.right", help: "Next day") { shift(1) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(digest.headline).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if OnDeviceSummary.isAvailable {
                HStack(alignment: .top) {
                    if let aiSummary {
                        Text(aiSummary).font(.system(size: 13)).textSelection(.enabled)
                    } else {
                        Button(summarizing ? "Summarising on this Mac…" : "Summarise with Apple Intelligence") {
                            summarizing = true
                            let prompt = digest.modelPrompt(items: items)
                            Task {
                                aiSummary = await OnDeviceSummary.summarize(prompt) ?? "The on-device model couldn't summarise this."
                                summarizing = false
                            }
                        }
                        .disabled(summarizing || digest.total == 0)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }
            ScrollView {
                // Same renderer as Notes; checkboxes shown as bullets so they can't toggle a note.
                MarkdownPreview(text: digest.markdown(hideText: model.privacyMode).replacingOccurrences(of: "- [ ] ", with: "- "))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).glassCard()
            HStack {
                Button("Save as Note") {
                    let title = "Digest \(UsageLog.dayKey(day))"
                    notes.create(title: title, body: digest.markdown() + (aiSummary.map { "\n## Summary\n\($0)\n" } ?? ""))
                    dismiss()
                    model.section = .notes
                }
                Button("Open Inbox") { dismiss(); model.selectInbox(.unread) }
                Spacer()
                Text("Made on this Mac. Nothing is sent anywhere.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .preferredColorScheme(.dark)
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        aiSummary = nil
    }
}

// MARK: - Settings

struct AppearanceSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppearanceKeys.accentHex) private var accentHex = AccentPalette.colors[0].hex
    @AppStorage(AppearanceKeys.density) private var density: UIDensity = .comfortable
    @AppStorage(AppearanceKeys.ambientStyle) private var ambientStyle = "digital"
    @AppStorage(AppearanceKeys.hotCorner) private var hotCorner: ScreenCorner = .off
    @AppStorage(AppearanceKeys.digestEnabled) private var digestEnabled = false
    @AppStorage(AppearanceKeys.digestTime) private var digestTime = "18:00"

    var body: some View {
        Form {
            Section("Look") {
                HStack {
                    Text("Accent")
                    Spacer()
                    ForEach(AccentPalette.colors, id: \.hex) { c in
                        Button { accentHex = c.hex } label: {
                            Circle().fill(Color(hex: c.hex)).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(accentHex == c.hex ? 0.9 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                    }
                }
                Picker("Message list density", selection: $density) {
                    ForEach(UIDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Hot corner opens the launcher", selection: $hotCorner) {
                    ForEach(ScreenCorner.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: hotCorner) { model.hotCorner?.apply($0) }
            } footer: {
                Text("Move the pointer into the corner and hold it there briefly. If macOS also uses that corner (System Settings → Desktop & Dock → Hot Corners), pick another one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ambient clock") {
                Picker("Style", selection: $ambientStyle) {
                    Text("Digital").tag("digital")
                    Text("Analog").tag("analog")
                }
                .pickerStyle(.segmented)
                Button("Show Ambient Clock") { model.toggleAmbient() }
            }
            Section {
                Toggle("Daily digest notification", isOn: $digestEnabled)
                if digestEnabled {
                    DatePicker("At", selection: Binding(
                        get: {
                            let p = digestTime.split(separator: ":").compactMap { Int($0) }
                            return Calendar.current.date(bySettingHour: p.first ?? 18, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
                        },
                        set: {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            digestTime = String(format: "%02d:%02d", c.hour ?? 18, c.minute ?? 0)
                        }), displayedComponents: .hourAndMinute)
                }
                Button("Show Today's Digest") { model.showDigest = true; model.openInbox() }
            } header: {
                Text("Daily digest")
            } footer: {
                Text(OnDeviceSummary.isAvailable
                     ? "Counts, priority messages and who is waiting for a reply. Apple Intelligence can add a short summary, on this Mac."
                     : "Counts, priority messages and who is waiting for a reply, worked out on this Mac. With Apple Intelligence (macOS 26) it can also write a short summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
