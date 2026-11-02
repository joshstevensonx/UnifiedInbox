# CLAUDE.md: Unified Inbox + NEXUS

Read **HANDOFF.md** first. It has the current batch, the task list with status, the exact next step, and known pitfalls.

## Ground rules
- Native macOS app: Swift 5.9 package, SwiftUI + AppKit, macOS 13+, universal (arm64 + x86_64). No Electron, no backend, no telemetry.
- Only public Apple APIs. Don't add features that need an account, a paid service, or private frameworks (user's instruction).
- Local-first: data under `~/Library/Application Support/UnifiedInbox/`.
- Design: dark glass, minimal. Reuse `Sources/UnifiedInboxApp/Views/Theme.swift` components (`glassCard`, `GlassIconButton`, `Chip`, `SectionLabel`, `MetricValue`).
- Put pure logic in `InboxCore` / `NexusCore` with unit tests. Keep AppKit/SwiftUI in `UnifiedInboxApp`.

## Verify
- Linux / cloud session: `./scripts/linux-test.sh` (installs Swift if needed, syntax-checks all sources, runs the core tests). The macOS app target can't compile on Linux.
- Mac: `./scripts/build-app.sh` (the only real compile of the app). Ask the user to run it after each batch and paste any `error:` lines.

## Pitfalls (each one broke a real build)
- Don't read `self` in `init` before every stored property is set. Use local variables.
- Inside `Task {}`, call `NSWorkspace.openApplication(at:configuration:)` with a completion handler `{ _, _ in }`.
- Use `activate(options: [])`, not `activate()` (macOS 13).
- Static members of `@MainActor` types used off-main need `nonisolated static`.
- UserNotifications only work in the bundled .app. Use `UNUserNotificationCenterSafe`.
- Don't name variables `internal`. Don't write `if let (a, b) = …`.

## Docs to keep current
FEATURES.md (status), RUNNING.md (user guide), HANDOFF.md (next steps).
