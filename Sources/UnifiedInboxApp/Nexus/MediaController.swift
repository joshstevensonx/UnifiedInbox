import AppKit
import Combine
import SwiftUI

/// Now Playing + transport for Music and Spotify (spec §1.1).
///
/// Uses AppleScript only (public, sandbox-compatible with the Apple Events entitlement); the private
/// MediaRemote framework is deliberately not used. macOS asks once for Automation permission per player.
/// Scripts only target players that are already running, so nothing gets launched by polling.
@MainActor
final class MediaController: ObservableObject {
    struct NowPlaying: Equatable {
        var player: Player
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var position: Double?
        var duration: Double?
    }

    enum Player: String, CaseIterable {
        case music = "Music", spotify = "Spotify"
        var bundleId: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var symbol: String { self == .music ? "music.note" : "music.note.list" }
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var subscribers = 0
    private let queue = DispatchQueue(label: "nexus.media", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    init() {
        // Spotify and Music both broadcast state changes; refresh immediately when they do.
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    /// Poll every 3 s only while a view showing media is visible.
    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { timer?.invalidate(); timer = nil }
    }

    private var runningPlayers: [Player] {
        Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty }
    }

    /// The player to control: whichever is playing, else the current Now Playing player, else any running one.
    private var target: Player? {
        if let np = nowPlaying, np.isPlaying { return np.player }
        return nowPlaying?.player ?? runningPlayers.first
    }

    func refresh() {
        let players = runningPlayers
        guard !players.isEmpty else { nowPlaying = nil; return }
        queue.async { [weak self] in
            var best: NowPlaying?
            for p in players {
                guard let np = Self.query(p) else { continue }
                if np.isPlaying { best = np; break }
                if best == nil { best = np }
            }
            Task { @MainActor in self?.nowPlaying = best }
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func openPlayer() {
        guard let p = target, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    private func send(_ command: String) {
        guard let p = target else {
            lastError = "Open Music or Spotify first"
            return
        }
        queue.async { [weak self] in
            let error = Self.run("tell application \"\(p.rawValue)\" to \(command)")
            Task { @MainActor in
                self?.lastError = error
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.refresh()
            }
        }
    }

    // MARK: AppleScript (runs on `queue`)

    nonisolated private static func query(_ p: Player) -> NowPlaying? {
        let script = """
        tell application "\(p.rawValue)"
            if player state is stopped then return "STOPPED"
            set t to current track
            set d to duration of t
            return (name of t) & "|~|" & (artist of t) & "|~|" & (album of t) & "|~|" & (player state as string) & "|~|" & (player position as string) & "|~|" & (d as string)
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, out != "STOPPED" else { return nil }
        let f = out.components(separatedBy: "|~|")
        guard f.count >= 6 else { return nil }
        var duration = Double(f[5].replacingOccurrences(of: ",", with: "."))
        if p == .spotify { duration = duration.map { $0 / 1000 } } // Spotify reports milliseconds
        return NowPlaying(player: p, title: f[0], artist: f[1], album: f[2], isPlaying: f[3] == "playing",
                          position: Double(f[4].replacingOccurrences(of: ",", with: ".")), duration: duration)
    }

    /// Returns an error message, or nil.
    nonisolated private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        guard let err else { return nil }
        if (err[NSAppleScript.errorNumber] as? Int) == -1743 {
            return "Allow Unified Inbox to control your music player in System Settings → Privacy & Security → Automation"
        }
        return err[NSAppleScript.errorMessage] as? String
    }
}

/// Compact Now Playing card (Overview, menu bar).
struct NowPlayingCard: View {
    @EnvironmentObject private var media: MediaController
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: media.nowPlaying?.player.symbol ?? "music.note")
                .font(.system(size: compact ? 13 : 16))
                .foregroundStyle(Theme.secondary)
                .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                .softFill(Theme.fill, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                if let np = media.nowPlaying {
                    Text(np.title).font(.system(size: compact ? 12 : 13, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text([np.artist, np.player.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    if !compact, let pos = np.position, let dur = np.duration, dur > 0 {
                        ProgressView(value: min(pos, dur), total: dur).progressViewStyle(.linear).tint(Theme.accent).controlSize(.mini)
                    }
                } else {
                    Text("Nothing playing").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(media.lastError ?? "Music or Spotify").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                GlassIconButton(systemImage: "backward.fill", help: "Previous track") { media.previous() }
                GlassIconButton(systemImage: media.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                                help: media.nowPlaying?.isPlaying == true ? "Pause" : "Play") { media.playPause() }
                GlassIconButton(systemImage: "forward.fill", help: "Next track") { media.next() }
            }
        }
        .padding(compact ? 10 : 14)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { media.openPlayer() }
        .help(media.nowPlaying.map { "\($0.title) by \($0.artist), \($0.album). Double-click to open \($0.player.rawValue)" } ?? "Control Music or Spotify")
        .onAppear { media.subscribe() }
        .onDisappear { media.unsubscribe() }
    }
}
