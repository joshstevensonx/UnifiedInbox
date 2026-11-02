import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies Microsoft Graph access tokens. Phase 2 wires this to MSAL (delegated auth,
/// scopes `Mail.Read Chat.Read offline_access`) with tokens kept in the Keychain.
public protocol GraphTokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// Optional richer source for Outlook (mail) and Teams (chats) via Microsoft Graph.
/// When enabled for a platform, the coordinator turns that platform off in the
/// Notification Center source so items aren't duplicated.
public final class GraphSource: CaptureSource, @unchecked Sendable {
    public let identifier = "graph"
    public let platforms: Set<Platform>
    public let pollInterval: TimeInterval
    private let tokens: GraphTokenProvider
    private let session: URLSession
    private let base = URL(string: "https://graph.microsoft.com/v1.0")!

    public init(platforms: Set<Platform> = [.outlook, .teams],
                tokens: GraphTokenProvider,
                pollInterval: TimeInterval = 60,
                session: URLSession = .shared) {
        self.platforms = platforms.intersection([.outlook, .teams])
        self.tokens = tokens
        self.pollInterval = pollInterval
        self.session = session
    }

    public func poll(store: InboxStore) async throws -> [InboxItem] {
        var items: [InboxItem] = []
        if platforms.contains(.outlook) { items += try await pollMail(store: store) }
        if platforms.contains(.teams) { items += try await pollChats() }
        return items
    }

    // MARK: Outlook

    private struct MailPage: Decodable {
        struct Message: Decodable {
            struct Recipient: Decodable { struct Addr: Decodable { let name: String?; let address: String? }; let emailAddress: Addr }
            let id: String
            let subject: String?
            let bodyPreview: String?
            let receivedDateTime: Date
            let conversationId: String?
            let from: Recipient?
        }
        let value: [Message]
    }

    private func pollMail(store: InboxStore) async throws -> [InboxItem] {
        let key = "graph.mail.since"
        let since = try store.value(for: key) ?? ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        var comps = URLComponents(url: base.appendingPathComponent("me/mailFolders/inbox/messages"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "$select", value: "id,subject,bodyPreview,receivedDateTime,conversationId,from"),
            .init(name: "$filter", value: "receivedDateTime gt \(since)"),
            .init(name: "$orderby", value: "receivedDateTime desc"),
            .init(name: "$top", value: "50"),
        ]
        let page: MailPage = try await get(comps.url!)
        let items = page.value.map { m in
            InboxItem(
                id: "graph:mail:\(m.id)", platform: .outlook, origin: .graph,
                sourceBundleId: Platform.outlook.launchBundleIdentifier,
                title: m.from?.emailAddress.name ?? m.from?.emailAddress.address ?? "Outlook",
                subtitle: m.subject, body: m.bodyPreview ?? "",
                threadId: m.conversationId, receivedAt: m.receivedDateTime
            )
        }
        if let newest = page.value.map(\.receivedDateTime).max() {
            try store.setValue(ISO8601DateFormatter().string(from: newest), for: key)
        }
        return items
    }

    // MARK: Teams

    private struct ChatPage: Decodable {
        struct Chat: Decodable {
            struct Preview: Decodable {
                struct Body: Decodable { let content: String? }
                struct From: Decodable { struct User: Decodable { let displayName: String? }; let user: User? }
                let id: String
                let createdDateTime: Date
                let body: Body?
                let from: From?
            }
            let id: String
            let topic: String?
            let lastMessagePreview: Preview?
        }
        let value: [Chat]
    }

    private func pollChats() async throws -> [InboxItem] {
        var comps = URLComponents(url: base.appendingPathComponent("me/chats"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "$expand", value: "lastMessagePreview"), .init(name: "$top", value: "50")]
        let page: ChatPage = try await get(comps.url!)
        return page.value.compactMap { chat in
            guard let msg = chat.lastMessagePreview else { return nil }
            return InboxItem(
                id: "graph:chat:\(msg.id)", platform: .teams, origin: .graph,
                sourceBundleId: Platform.teams.launchBundleIdentifier,
                title: msg.from?.user?.displayName ?? "Teams",
                subtitle: chat.topic, body: Self.stripHTML(msg.body?.content ?? ""),
                threadId: chat.id, receivedAt: msg.createdDateTime
            )
        }
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(s)"))
        }
        return try decoder.decode(T.self, from: data)
    }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
