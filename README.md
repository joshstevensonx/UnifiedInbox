# Unified Inbox (macOS)

A local-first menu-bar + window app that collects Microsoft Teams, Outlook and WhatsApp
notifications into one searchable inbox. Nothing leaves your Mac. Design details are in [SPEC.md](SPEC.md); step-by-step setup is in [RUNNING.md](RUNNING.md); the feature backlog is in [FEATURES.md](FEATURES.md).

## Requirements
- macOS 13 Ventura or later (Intel or Apple Silicon)
- Xcode 15+ (or the Swift 5.9+ command-line toolchain)
- Teams / Outlook / WhatsApp desktop apps with notifications **on** (banner or alert style, previews shown)

## Run in Xcode
1. `open Package.swift`
2. Select the **UnifiedInbox** scheme → My Mac → Run.
3. Grant Full Disk Access when the yellow banner asks (see below). When running from Xcode, the
   binary that needs access is the one in DerivedData; using `build-app.sh` is easier for daily use.

## Build a .app
```bash
./scripts/build-app.sh          # universal release build → dist/UnifiedInbox.app
open dist/UnifiedInbox.app
```

## Full Disk Access
macOS 15+ keeps the Notification Center database in a protected location.
System Settings → Privacy & Security → Full Disk Access → **+** → choose `UnifiedInbox.app` → relaunch
(or click **Check Again**).

## Tests
```bash
swift test
```
Covers bundle-id mapping, notification plist parsing, store dedupe/filters/FTS search/retention,
and polling a fake Notification Center database.

## Layout
```
Sources/InboxCore/          platform-independent core
  Models/                   InboxItem, Platform, InboxFilter
  Storage/InboxStore.swift  SQLite (GRDB) + FTS5 search, kv cursors
  Capture/                  NotificationCenterSource, GraphSource (Phase 2), CaptureCoordinator
Sources/UnifiedInboxApp/    SwiftUI app: window, menu-bar extra, settings
Tests/InboxCoreTests/
scripts/build-app.sh        universal .app bundle + ad-hoc signing
```

Data lives at `~/Library/Application Support/UnifiedInbox/inbox.sqlite`.
