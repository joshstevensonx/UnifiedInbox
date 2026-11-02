# Handoff: Unified Inbox + NEXUS (continue from here)

Last updated: 2026-11-02. Project folder on the Mac: `~/Desktop/DEV/UnifiedInbox`.

## What this is
A native macOS app (Swift 5.9 package, SwiftUI + AppKit, macOS 13+, universal binary) that combines:
1. **Unified Inbox**: captures Teams / Outlook / WhatsApp (plus optional Slack, Messages, Mail, Discord, Telegram, Signal) notifications by reading the Notification Center database read-only (needs Full Disk Access).
2. **NEXUS tools**: Overview dashboard, System Monitor, Launcher and command palette, floating widgets, Apps and Screen Time, Clipboard history, Focus (tasks and Pomodoro), capture and OCR, media controls, permissions dashboard.

Design: dark glass, minimal (`Views/Theme.swift`). App icon from `scripts/make_icon.py`.

## Build and test
```bash
cd ~/Desktop/DEV/UnifiedInbox
./scripts/build-app.sh          # → dist/UnifiedInbox.app (universal, ad-hoc signed, icon bundled)
swift test                      # core unit tests (47 at handoff, all passing on Linux toolchain)
open Package.swift              # Xcode
```
On Linux (cloud sandbox) the app target can't build. Only `InboxCore` and `NexusCore` with tests can, using stub symbols for GRDB's SQLite snapshot API. The SwiftUI files are only syntax-checked (`swiftc -parse`). **Always ask the user to run `./scripts/build-app.sh` and paste `error:` lines.**

### Build status at handoff
- Last confirmed good Mac build: the NEXUS merge (batch 3).
- Batch 4 build failed on one error (async `openApplication` in `AppsManager.restart`), now fixed. Not yet re-confirmed.
- Batch 5 (below) has **not been built on a Mac yet**. Expect a few compile errors; fix them first.

### Gotchas already hit (avoid repeating)
- Don't read `self` properties in `init` before every stored property is set. Use locals (see `AppModel.init`).
- Inside `Task {}` / async contexts, `NSWorkspace.openApplication(at:configuration:)` resolves to the async throwing overload. Always pass a completion handler `{ _, _ in }`.
- `internal` is a keyword (don't name variables that).
- `NSRunningApplication.activate()` with no args is macOS 14+. Use `activate(options: [])`.
- Static properties on `@MainActor` classes used from nonisolated code need `nonisolated static`.
- UserNotifications crash outside a `.app` bundle. Use `UNUserNotificationCenterSafe` / `PriorityNotifier`.
- `if let (a, b) = optionalTuple` isn't valid Swift. Bind to a single name.

## Layout
```
Package.swift                 targets: InboxCore (GRDB), NexusCore, UnifiedInboxApp, 2 test targets
Sources/InboxCore/            Models, Storage (InboxStore SQLite+FTS5, exporter), Capture (NC DB, Graph stub, coordinator),
                              Rules (AlertRules, SnoozeOption, InboxGrouping/DayBucket, InboxRules: RuleSet/QuietHours/SavedSearch)
Sources/NexusCore/            Monitoring (Metrics, SystemSampler [macOS], Thresholds), Launcher, Widgets,
                              Productivity (Clipboard, Palette/aliases, Usage, Focus: Pomodoro + TodoItem)
Sources/UnifiedInboxApp/      AppModel (hub), UnifiedInboxApp (scenes/menus), Views/, Nexus/ (feature models + views)
Tests/                        InboxCoreTests, NexusCoreTests
Resources/                    Info.plist (usage strings), AppIcon.icns/png
docs/                         NEXUS_Product_Documentation.md, App_Feature_Spec.md (source specs)
SPEC.md RUNNING.md FEATURES.md HANDOFF.md
```
Local data: `~/Library/Application Support/UnifiedInbox/` (inbox.sqlite + launcher/aliases/widgets/clipboard/usage/tasks/rules .json).

## User's instruction for the current batch
> "Do everything that doesn't require account setup or payment."

Excluded (need an account or payment): Microsoft Graph sign-in, Slack/Discord/Telegram APIs, Todoist/Asana/Notion, cross-Mac sync, Developer ID notarization/Sparkle. Not planned: private APIs (MediaRemote, SMC temps/fans, /etc/hosts blocking).

## Batch 5 progress (task list)
| # | Task | Status |
|---|---|---|
| 11 | Inbox rules engine, labels, quiet hours, auto-archive | ✅ core + tests + Settings → Rules tab + sidebar Labels |
| 12 | Saved searches, private notes, "Remind me", Add to Tasks / Apple Reminders, export by date range | ✅ |
| 13 | Threshold alerts + battery/storage history | ✅ tests (`ThresholdTests`), wired in `SystemMonitor`, charts in Monitor Battery/Storage tabs, Settings → Nexus → System alerts |
| 14 | Window tiling + workspaces (Accessibility) | ✅ `NexusCore/Windows/Tiling.swift` (+`TilingTests`), `Nexus/WindowManager.swift`, Windows page, palette commands |
| 15 | Notes: Markdown, [[backlinks]], daily notes | ✅ `NexusCore/Productivity/Notes.swift` (+`NotesTests`), `Nexus/NotesModel.swift`, Notes page |
| 16 | File tools: large files, Downloads cleanup, duplicates | ✅ `NexusCore/Files/FileTools.swift` (+`FileToolsTests`), `Nexus/FileToolsModel.swift`, Files page; folder usage strings in Info.plist |
| 17 | Habits + weekly review | ⬜ |
| 18 | Touch ID app lock + AES-GCM encrypted backup/restore | ⬜ |
| 19 | Hotkey manager with rebinding (central registry over `GlobalHotKey`) | ⬜ |
| 20 | Automation rules (triggers → actions, cooldown, run log) | ⬜ |
| 21 | Text snippet expansion (event tap, Accessibility) | ⬜ |
| 22 | Process manager (libproc, all processes) + log viewer | ⬜ |
| 23 | `inboxctl` CLI + stdio MCP server over the local DB | ⬜ |
| 24 | Ambient clock, density/accent settings, hot-corner launcher, daily digest (FoundationModels if available) | ⬜ |
| 25 | Verify, update FEATURES/RUNNING, sync | ⬜ |

### Notes for later tasks
- When adding Automation (task 20), call `automation?.newMessages(items)` at the top of `AppModel.handleNew` (removed at handoff because the type doesn't exist yet).
- New global hotkeys must use `GlobalHotKey` (QuickLook.swift). It supports several at once via a shared handler keyed by id. Existing: ⌃⌥Space quick look, ⌥Space palette, ⌃⌥V clipboard.
- Sidebar pages are `AppSection` cases (AppModel.swift). Add a case, title, symbol, `SidebarView` row, `ContentView.page` switch case, `pageHelp`, and environment objects in `UnifiedInboxApp.swift`.
- Persist feature state with `JSONFileStore<T>` (NexusCore/Launcher/Launcher.swift) under Application Support.
- Accessibility-based features must check trust via `AX.isTrusted()` (WindowManager.swift) and guide the user. The `PermissionsView` Accessibility row lists what uses it; add snippets (task 21) there.
- `AppSection` now has more than 9 cases; the Go menu only assigns ⌘1–⌘9 to the first nine.
- Tiling hotkeys are registered in `WindowManager.setHotKeysEnabled` via `GlobalHotKey`; move them into the hotkey registry in task 19.
- Reusable `TextPrompt.ask(title:message:)` (WindowManager.swift) for one-field NSAlert prompts.
- Add usage strings to `Resources/Info.plist` for any new permission (Reminders strings were added in batch 5).

## Continuing in a Claude Code cloud session
1. On the Mac, push the folder to a private GitHub repo (commands in the chat that created this file, or: `git init && git add -A && git commit -m "Unified Inbox + NEXUS" && gh repo create unifiedinbox --private --source . --push`).
2. Start a session at claude.ai/code on that repo. `CLAUDE.md` is read automatically and points here.
3. Verify with `./scripts/linux-test.sh` (Linux: syntax check + 47 core tests). The macOS build still happens on the Mac: `git pull && ./scripts/build-app.sh`.
4. Commit work in small batches with clear messages so the Mac can pull and build after each one.

## Working method used so far (Cowork session)
- Cloud workspace copy: `/mnt/user-data/outputs/UnifiedInbox` (mirror of the Mac folder). Edit there, run `swift test` / `swiftc -parse`, then `device_commit_files` to the Mac and compare md5 checksums. Edits made directly on the Mac must be staged back to the cloud copy.
- README.md and RUNNING.md were last edited on the Mac directly. Don't overwrite them from the cloud copy without staging first.
- Keep the progress sidebar (TaskCreate/TaskUpdate) and an in-chat progress bar updated. The user asked for this.
