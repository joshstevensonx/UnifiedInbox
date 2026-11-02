import Foundation

/// A communication app the inbox aggregates.
public enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case teams
    case outlook
    case whatsapp
    case slack
    case messages
    case mail
    case discord
    case telegram
    case signal

    public var id: String { rawValue }

    /// The three apps enabled on first launch; others are opt-in in Settings.
    public static let defaultEnabled: Set<Platform> = [.teams, .outlook, .whatsapp]

    public var displayName: String {
        switch self {
        case .teams: return "Microsoft Teams"
        case .outlook: return "Outlook"
        case .whatsapp: return "WhatsApp"
        case .slack: return "Slack"
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .discord: return "Discord"
        case .telegram: return "Telegram"
        case .signal: return "Signal"
        }
    }

    /// SF Symbol used in the UI.
    public var symbolName: String {
        switch self {
        case .teams: return "person.3.fill"
        case .outlook: return "envelope.fill"
        case .whatsapp: return "message.fill"
        case .slack: return "number"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .mail: return "envelope.open.fill"
        case .discord: return "gamecontroller.fill"
        case .telegram: return "paperplane.fill"
        case .signal: return "lock.shield.fill"
        }
    }

    /// Brand-ish accent colour as RGB 0–1 (kept here so the core stays UI-free).
    public var accentRGB: (Double, Double, Double) {
        switch self {
        case .teams: return (0.36, 0.37, 0.78)
        case .outlook: return (0.00, 0.47, 0.83)
        case .whatsapp: return (0.15, 0.68, 0.38)
        case .slack: return (0.29, 0.08, 0.30)
        case .messages: return (0.20, 0.78, 0.35)
        case .mail: return (0.10, 0.55, 0.95)
        case .discord: return (0.35, 0.40, 0.95)
        case .telegram: return (0.16, 0.63, 0.87)
        case .signal: return (0.23, 0.46, 0.94)
        }
    }

    /// Bundle identifiers whose macOS notifications map to this platform.
    public var bundleIdentifiers: [String] {
        switch self {
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .outlook: return ["com.microsoft.Outlook"]
        case .whatsapp: return ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp"]
        case .slack: return ["com.tinyspeck.slackmacgap"]
        case .messages: return ["com.apple.MobileSMS", "com.apple.iChat"]
        case .mail: return ["com.apple.mail"]
        case .discord: return ["com.hnc.Discord"]
        case .telegram: return ["ru.keepcoder.Telegram", "org.telegram.desktop"]
        case .signal: return ["org.whispersystems.signal-desktop"]
        }
    }

    /// Web client to open when the desktop app isn't installed.
    public var webURL: URL? {
        switch self {
        case .teams: return URL(string: "https://teams.microsoft.com")
        case .outlook: return URL(string: "https://outlook.office.com/mail/")
        case .whatsapp: return URL(string: "https://web.whatsapp.com")
        case .slack: return URL(string: "https://app.slack.com")
        case .discord: return URL(string: "https://discord.com/app")
        case .telegram: return URL(string: "https://web.telegram.org")
        case .messages, .mail, .signal: return nil
        }
    }

    /// Preferred bundle id to launch when the user clicks "Open in app".
    public var launchBundleIdentifier: String { bundleIdentifiers[0] }

    /// Resolve a platform from a notification's source bundle id (case-insensitive).
    public static func from(bundleIdentifier: String) -> Platform? {
        let id = bundleIdentifier.lowercased()
        return allCases.first { p in p.bundleIdentifiers.contains { $0.lowercased() == id } }
    }

    // MARK: Persistence of the enabled set (comma-separated raw values)

    public static func decodeSet(_ s: String?) -> Set<Platform> {
        guard let s, !s.isEmpty else { return defaultEnabled }
        return Set(s.split(separator: ",").compactMap { Platform(rawValue: String($0)) })
    }

    public static func encodeSet(_ set: Set<Platform>) -> String {
        allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}
