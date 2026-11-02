import Foundation

/// Health of a capture source, surfaced in Settings and onboarding.
public enum CaptureStatus: Equatable, Sendable {
    case idle
    case running
    /// Needs the user to do something (e.g. grant Full Disk Access, sign in).
    case needsSetup(String)
    case failed(String)
}

/// Anything that can produce inbox items. Sources are polled by `CaptureCoordinator`.
public protocol CaptureSource: AnyObject, Sendable {
    /// Stable identifier, also used as the kv-cursor namespace.
    var identifier: String { get }
    /// Platforms this source currently covers.
    var platforms: Set<Platform> { get }
    /// Seconds between polls.
    var pollInterval: TimeInterval { get }
    /// Fetch items newer than the source's own cursor (persisted via `store`).
    func poll(store: InboxStore) async throws -> [InboxItem]
}
