// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnifiedInbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UnifiedInbox", targets: ["UnifiedInboxApp"]),
        .executable(name: "inboxctl", targets: ["inboxctl"]),
        .library(name: "InboxCore", targets: ["InboxCore"]),
        .library(name: "NexusCore", targets: ["NexusCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        // Platform-independent core: models, storage, capture sources.
        .target(
            name: "InboxCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // NEXUS: system metrics, launcher and widget models + calculations.
        // Pure logic is cross-platform (unit-tested); Darwin providers are macOS-only.
        .target(name: "NexusCore"),
        // SwiftUI / AppKit shell (macOS only).
        .executableTarget(
            name: "UnifiedInboxApp",
            dependencies: ["InboxCore", "NexusCore"]
        ),
        // Command-line tool + MCP server over the local database (bundled into the .app).
        .executableTarget(name: "inboxctl", dependencies: ["InboxCore"]),
        .testTarget(
            name: "InboxCoreTests",
            dependencies: ["InboxCore"]
        ),
        .testTarget(
            name: "NexusCoreTests",
            dependencies: ["NexusCore"]
        ),
    ]
)
