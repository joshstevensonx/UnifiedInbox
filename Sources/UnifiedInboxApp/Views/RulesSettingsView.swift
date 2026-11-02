import InboxCore
import SwiftUI

/// Settings → Rules: message rules, quiet hours, auto-archive, labels.
struct RulesSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: InboxRule?

    var body: some View {
        Form {
            Section {
                if model.ruleSet.rules.isEmpty {
                    Text("No rules yet. Example: if From contains “Martin”, label “Nexora” and mark priority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.ruleSet.rules) { rule in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { v in update(rule.id) { $0.isEnabled = v } }
                        )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text((rule.matchAll ? "All of: " : "Any of: ") + rule.conditions.map(\.label).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("→ " + rule.actions.map(\.label).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = rule }.controlSize(.small)
                        Button(role: .destructive) {
                            model.ruleSet.rules.removeAll { $0.id == rule.id }
                            model.saveRuleSet()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Rule…") { editing = InboxRule(name: "New rule", conditions: [.senderContains("")], actions: [.label("")]) }
                    Spacer()
                    Button("Apply Rules to Existing Messages") { model.saveRuleSet(applyToExisting: true) }
                        .help("Adds labels and flags to messages already in the inbox. Nothing is removed.")
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules run on every new message, in order. Muted messages are still captured, just without a banner or sound.")
            }

            Section("Quiet hours") {
                Toggle("Silence alerts during quiet hours", isOn: quiet(\.isEnabled))
                HStack {
                    Picker("From", selection: quiet(\.startMinute)) { timeOptions }
                    Picker("Until", selection: quiet(\.endMinute)) { timeOptions }
                }
                .disabled(!model.ruleSet.quietHours.isEnabled)
                HStack(spacing: 6) {
                    Text("Days").foregroundStyle(.secondary)
                    ForEach(1...7, id: \.self) { day in
                        let on = model.ruleSet.quietHours.weekdays.contains(day)
                        Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                            if on { model.ruleSet.quietHours.weekdays.remove(day) } else { model.ruleSet.quietHours.weekdays.insert(day) }
                            model.saveRuleSet()
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? Theme.accent : nil)
                        .controlSize(.small)
                    }
                    Text(model.ruleSet.quietHours.weekdays.isEmpty ? "every day" : "").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!model.ruleSet.quietHours.isEnabled)
                Text("Applies to all apps. Messages keep arriving in the inbox; only banners and sounds stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Clean-up") {
                Picker("Auto-archive read messages", selection: Binding(
                    get: { model.ruleSet.autoArchiveReadAfterHours ?? 0 },
                    set: { v in model.ruleSet.autoArchiveReadAfterHours = v == 0 ? nil : v; model.saveRuleSet() }
                )) {
                    Text("Never").tag(0)
                    Text("After 1 day").tag(24)
                    Text("After 3 days").tag(72)
                    Text("After 1 week").tag(168)
                }
                Text("Pinned messages are never auto-archived.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Labels") {
                if model.ruleSet.allLabels.isEmpty {
                    Text("Labels appear here when a rule adds one or you label a message (right-click → Label).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.ruleSet.allLabels, id: \.self) { label in
                    HStack {
                        Circle().fill(labelColor(label)).frame(width: 8, height: 8)
                        Text(label)
                        Spacer()
                        Menu("Colour") {
                            ForEach(AppModel.labelPalette, id: \.self) { hex in
                                Button { model.ruleSet.labelColors[label] = hex; model.saveRuleSet() } label: {
                                    Text(hex)
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                if let i = model.ruleSet.rules.firstIndex(where: { $0.id == saved.id }) {
                    model.ruleSet.rules[i] = saved
                } else {
                    model.ruleSet.rules.append(saved)
                }
                model.saveRuleSet()
            }
        }
    }

    private func labelColor(_ label: String) -> Color { Color(hex: model.ruleSet.labelColors[label] ?? "#8CB3FF") }

    private func update(_ id: UUID, _ change: (inout InboxRule) -> Void) {
        guard let i = model.ruleSet.rules.firstIndex(where: { $0.id == id }) else { return }
        change(&model.ruleSet.rules[i])
        model.saveRuleSet()
    }

    private func quiet<T>(_ kp: WritableKeyPath<QuietHours, T>) -> Binding<T> {
        Binding(get: { model.ruleSet.quietHours[keyPath: kp] },
                set: { model.ruleSet.quietHours[keyPath: kp] = $0; model.saveRuleSet() })
    }

    @ViewBuilder private var timeOptions: some View {
        ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { m in
            Text(String(format: "%02d:%02d", m / 60, m % 60)).tag(m)
        }
    }
}

/// Add / edit one rule.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: InboxRule
    let onSave: (InboxRule) -> Void

    enum CondKind: String, CaseIterable, Identifiable { case sender = "From contains", text = "Text contains", subject = "Subject/chat contains", app = "App is"; var id: String { rawValue } }
    enum ActKind: String, CaseIterable, Identifiable { case label = "Add label", priority = "Mark priority", pin = "Pin", read = "Mark read", archive = "Archive", mute = "Don't alert"; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Rule name", text: $rule.name).font(.headline)
            Picker("Match", selection: $rule.matchAll) {
                Text("All conditions").tag(true)
                Text("Any condition").tag(false)
            }
            .pickerStyle(.segmented)

            Text("If").font(.caption).foregroundStyle(.secondary)
            ForEach(rule.conditions.indices, id: \.self) { i in
                HStack {
                    Picker("", selection: Binding(get: { kind(rule.conditions[i]) }, set: { rule.conditions[i] = make($0, from: rule.conditions[i]) })) {
                        ForEach(CondKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                    conditionValue(i)
                    Button { rule.conditions.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(rule.conditions.count == 1)
                }
            }
            Button("Add Condition") { rule.conditions.append(.senderContains("")) }.controlSize(.small)

            Text("Then").font(.caption).foregroundStyle(.secondary)
            ForEach(rule.actions.indices, id: \.self) { i in
                HStack {
                    Picker("", selection: Binding(get: { actKind(rule.actions[i]) }, set: { rule.actions[i] = makeAction($0, from: rule.actions[i]) })) {
                        ForEach(ActKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                    if case .label(let l) = rule.actions[i] {
                        TextField("Label, e.g. Nexora", text: Binding(get: { l }, set: { rule.actions[i] = .label($0) }))
                    }
                    Spacer()
                    Button { rule.actions.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(rule.actions.count == 1)
                }
            }
            Button("Add Action") { rule.actions.append(.priority) }.controlSize(.small)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(cleaned); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.conditions.isEmpty || cleaned.actions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Drops empty text conditions / labels.
    private var cleaned: InboxRule {
        var r = rule
        r.conditions = r.conditions.filter {
            switch $0 {
            case .senderContains(let s), .textContains(let s), .subtitleContains(let s): return !s.trimmingCharacters(in: .whitespaces).isEmpty
            case .platformIs: return true
            }
        }
        r.actions = r.actions.filter { if case .label(let l) = $0 { return !l.trimmingCharacters(in: .whitespaces).isEmpty }; return true }
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = "Rule" }
        return r
    }

    @ViewBuilder private func conditionValue(_ i: Int) -> some View {
        switch rule.conditions[i] {
        case .platformIs(let p):
            Picker("", selection: Binding(get: { p }, set: { rule.conditions[i] = .platformIs($0) })) {
                ForEach(Platform.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
        case .senderContains(let s), .textContains(let s), .subtitleContains(let s):
            TextField("text", text: Binding(get: { s }, set: { rule.conditions[i] = make(kind(rule.conditions[i]), text: $0) }))
        }
    }

    private func kind(_ c: InboxRule.Condition) -> CondKind {
        switch c {
        case .senderContains: return .sender
        case .textContains: return .text
        case .subtitleContains: return .subject
        case .platformIs: return .app
        }
    }

    private func text(_ c: InboxRule.Condition) -> String {
        switch c {
        case .senderContains(let s), .textContains(let s), .subtitleContains(let s): return s
        case .platformIs: return ""
        }
    }

    private func make(_ k: CondKind, from old: InboxRule.Condition) -> InboxRule.Condition { make(k, text: text(old)) }

    private func make(_ k: CondKind, text: String) -> InboxRule.Condition {
        switch k {
        case .sender: return .senderContains(text)
        case .text: return .textContains(text)
        case .subject: return .subtitleContains(text)
        case .app: return .platformIs(.teams)
        }
    }

    private func actKind(_ a: InboxRule.Action) -> ActKind {
        switch a {
        case .label: return .label
        case .priority: return .priority
        case .pin: return .pin
        case .markRead: return .read
        case .archive: return .archive
        case .mute: return .mute
        }
    }

    private func makeAction(_ k: ActKind, from old: InboxRule.Action) -> InboxRule.Action {
        switch k {
        case .label: if case .label(let l) = old { return .label(l) }; return .label("")
        case .priority: return .priority
        case .pin: return .pin
        case .read: return .markRead
        case .archive: return .archive
        case .mute: return .mute
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color (falls back to the accent).
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { self = Theme.accent; return }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
