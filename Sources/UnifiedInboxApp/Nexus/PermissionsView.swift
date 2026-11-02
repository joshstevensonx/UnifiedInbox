import AppKit
import ApplicationServices
import CoreGraphics
import InboxCore
import SwiftUI
import UserNotifications

/// Transparent permission dashboard (spec §8.2, §13.2): what the app holds, why, and where to change it.
struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notifications: String = "Checking…"
    @State private var musicAutomation: PermissionState = .unknown
    @State private var spotifyAutomation: PermissionState = .unknown
    @State private var screenRecording: PermissionState = .unknown
    @State private var accessibility: PermissionState = .unknown

    enum PermissionState: Equatable {
        case granted, denied, notAsked, notNeeded, unknown

        var label: String {
            switch self {
            case .granted: return "Allowed"
            case .denied: return "Denied"
            case .notAsked: return "Not asked yet"
            case .notNeeded: return "Not used"
            case .unknown: return "Unknown"
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green.opacity(0.85)
            case .denied: return .red
            case .notAsked: return Theme.warning
            case .notNeeded, .unknown: return Theme.tertiary
            }
        }
    }

    var body: some View {
        Form {
            Section {
                row("Full Disk Access", why: "Reads the Notification Center database to collect Teams, Outlook and WhatsApp messages.",
                    state: model.captureStatus == .running ? .granted : .denied, anchor: "Privacy_AllFiles")
                row("Notifications", why: "Priority alerts, task reminders, focus timer and closed-app warnings.",
                    stateText: notifications, anchor: nil, url: "x-apple.systempreferences:com.apple.preference.notifications")
                row("Screen Recording", why: "Screenshots and Copy Text (OCR). Asked the first time you capture.",
                    state: screenRecording, anchor: "Privacy_ScreenCapture")
                row("Automation: Music", why: "Now Playing and play/pause/skip for Music.", state: musicAutomation, anchor: "Privacy_Automation")
                row("Automation: Spotify", why: "Now Playing and play/pause/skip for Spotify.", state: spotifyAutomation, anchor: "Privacy_Automation")
                row("Accessibility", why: "Window tiling, restoring workspace window positions, and text snippets (seeing what you type in other apps to expand abbreviations; never in password fields).",
                    state: accessibility, anchor: "Privacy_Accessibility")
            } header: {
                HStack {
                    Text("Permissions")
                    Spacer()
                    Button("Refresh") { refresh() }.controlSize(.small)
                }
            }

            Section("Your data") {
                LabeledContent("Network") { Text("None by default. No telemetry, analytics or tracking.").foregroundStyle(.secondary) }
                LabeledContent("Stored at") {
                    HStack {
                        Text("~/Library/Application Support/UnifiedInbox").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: InboxStore.defaultPath()).deletingLastPathComponent()])
                        }
                        .controlSize(.small)
                    }
                }
                Text("Messages (SQLite), launcher, widgets, clipboard, screen time and tasks are separate local files. Delete the folder to reset everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CommandLineSection()
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func row(_ title: String, why: String, state: PermissionState? = nil, stateText: String? = nil,
                     anchor: String?, url: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(stateText ?? state?.label ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state?.color ?? Theme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .softFill(Theme.fill, cornerRadius: 6)
            Button("Open") {
                let target = url ?? "x-apple.systempreferences:com.apple.preference.security?\(anchor ?? "")"
                if let u = URL(string: target) { NSWorkspace.shared.open(u) }
            }
            .controlSize(.small)
            .help("Open the matching pane in System Settings")
        }
    }

    private func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        accessibility = AXIsProcessTrusted() ? .granted : .notAsked
        musicAutomation = Self.automation("com.apple.Music")
        spotifyAutomation = Self.automation("com.spotify.client")
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            notifications = "Only in the built .app"
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let text: String
            switch s.authorizationStatus {
            case .authorized, .provisional: text = "Allowed"
            case .denied: text = "Denied"
            case .notDetermined: text = "Not asked yet"
            default: text = "Limited"
            }
            DispatchQueue.main.async { notifications = text }
        }
    }

    /// Checks Apple Events consent without prompting (public API).
    private static func automation(_ bundleId: String) -> PermissionState {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }
}

/// `inboxctl` and the MCP server: read the inbox from Terminal or a local AI assistant.
struct CommandLineSection: View {
    @State private var copied: String?

    private var toolPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/inboxctl").path
    }

    private var installCommand: String {
        "mkdir -p ~/.local/bin && ln -sf \"\(toolPath)\" ~/.local/bin/inboxctl"
    }

    private var mcpConfig: String {
        """
        {
          "mcpServers": {
            "unified-inbox": { "command": "\(toolPath)", "args": ["mcp"] }
          }
        }
        """
    }

    var body: some View {
        Section {
            LabeledContent("Tool") {
                Text(toolPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Copy Install Command") { copy(installCommand, "install") }
                    .help("Links inboxctl into ~/.local/bin (add it to your PATH if needed)")
                Button("Copy MCP Config") { copy(mcpConfig, "mcp") }
                    .help("For an MCP client's config file, e.g. Claude Desktop's claude_desktop_config.json")
                if let copied { Text("Copied \(copied == "mcp" ? "MCP config" : "command")").font(.caption).foregroundStyle(.secondary) }
            }
            if !FileManager.default.isExecutableFile(atPath: toolPath) {
                Text("Not found in this build. Build with ./scripts/build-app.sh to include it.").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Command line & AI assistants")
        } footer: {
            Text("inboxctl lists, searches and exports messages from the local database (inboxctl help). \"inboxctl mcp\" lets a local AI assistant search your inbox over stdin/stdout: read-only unless you add --allow-writes. Nothing is sent anywhere by the app; what the assistant does with results depends on that assistant.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}
