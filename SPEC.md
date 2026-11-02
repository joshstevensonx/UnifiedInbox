# Unified Inbox — Specification

**Status:** v0.1 scaffold · **Platform:** macOS 13+, universal (arm64 + x86_64) · **Stack:** Swift 5.9, SwiftUI, GRDB/SQLite

## 1. Goal
One local-first Mac app that gathers notifications from Microsoft Teams, Microsoft Outlook and
WhatsApp into a single inbox, so the user can monitor, search, triage and jump to the right app
without switching between three apps.

### In scope (v1)
- Background capture of Teams, Outlook, WhatsApp notifications while the app runs (menu-bar resident).
- Unified inbox: All / Unread / Pinned / per-platform / Archived views.
- Full-text search across title, subtitle and body.
- Triage: mark read/unread, pin, archive, bulk actions, "mark all read".
- "Open in app" to jump to the source app (web client fallback).
- Menu-bar extra with per-platform unread counts and latest unread items; Dock badge.
- Retention policy (7/30/90 days/forever; pinned items kept), launch at login.

### Out of scope (v1)
Replying from the inbox, cloud sync between Macs, other platforms (Slack, Gmail…), AI summaries.
These are candidates for later phases (§8).

## 2. Constraints that shape the design
| Platform | Official API for personal use | Consequence |
|---|---|---|
| Teams | Microsoft Graph (`Chat.Read`) — needs Entra app registration; some tenants block user consent | Optional, Phase 2 |
| Outlook | Microsoft Graph (`Mail.Read`) — works for M365 and Outlook.com accounts | Optional, Phase 2 |
| WhatsApp | **None** for personal accounts (Business Cloud API only covers business numbers) | Must be captured locally |

macOS has no public API for one app to read another app's notifications. The practical local
route is reading the **Notification Center SQLite database** read-only.

## 3. Capture strategy (hybrid)
### 3.1 Notification Center source (Phase 1, default for all three)
- DB path, newest first:
  - macOS 15+: `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (TCC-protected → **Full Disk Access** required)
  - macOS 13–14: `$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db`
- Query `record JOIN app` filtered by bundle ids, incrementally by `rec_id > cursor` (cursor in `kv`).
  If `MAX(rec_id)` drops below the cursor (DB reset), rescan from 0 — ids dedupe.
- `record.data` is a binary plist: `req.titl` (title), `req.subt` (subtitle), `req.body`, `req.thre` (thread);
  `delivered_date` is Mac absolute time (seconds since 2001-01-01).
- Bundle ids: Teams `com.microsoft.teams2`, `com.microsoft.teams`; Outlook `com.microsoft.Outlook`;
  WhatsApp `net.whatsapp.WhatsApp` (native), `desktop.WhatsApp` (legacy Electron).
- Poll every 2 s (configurable). The query is indexed and cheap; the DB file is opened per poll so file moves don't break capture.

**Known limits** — surfaced in UI copy:
- Only sees what the app posts: muted chats, Focus-suppressed or "Show previews: never" notifications are missing or redacted.
- Notifications must be captured before macOS prunes them (polling makes this a non-issue while running; anything delivered while the app was quit and already dismissed is lost).
- Private schema — changed in Sequoia and may change again. Mitigations: parser treats every field as optional;
  `checkAccess()` health check; fixture tests; a fallback source (§3.3).
- Read state is one-way: marking read in Unified Inbox doesn't mark it read in Teams/WhatsApp.

### 3.2 Microsoft Graph source (Phase 2, opt-in for Teams/Outlook)
- Auth: MSAL for macOS, delegated, scopes `Mail.Read Chat.Read offline_access` (later `Mail.ReadWrite`, `ChatMessage.Send` for actions). Tokens in Keychain.
- Outlook: `GET /me/mailFolders/inbox/messages?$filter=receivedDateTime gt {cursor}` every 60 s (move to delta queries later).
- Teams: `GET /me/chats?$expand=lastMessagePreview` every 60 s (move to `/chats/{id}/messages/delta` per active chat later).
- When Graph is enabled for a platform, the coordinator removes that platform from the Notification Center source to avoid duplicates.
- Scaffold: `GraphSource` implemented against a `GraphTokenProvider` protocol; MSAL provider not yet wired.

### 3.3 Fallback (research item)
Accessibility observer on the Notification Center process (`AXObserver` on banner windows) if the DB becomes unreadable on a future macOS. Requires Accessibility permission; more brittle; only captures banners as they appear.

## 4. Architecture
```
┌───────────────────────── UnifiedInboxApp (SwiftUI, @MainActor) ─────────────────────────┐
│ Window: NavigationSplitView (Sidebar │ ItemList │ Detail) + .searchable                    │
│ MenuBarExtra: unread counts, latest 8 unread      Settings: sources, retention, login     │
│                         AppModel (ObservableObject, GRDB ValueObservation)                │
└───────────────────────────────────────┬──────────────────────────────────────────────────┘
                                        │ live queries / actions
┌───────────────────────────────────────▼─────────────── InboxCore ───────────────────────┐
│ CaptureCoordinator (actor) ── polls ──► CaptureSource protocol                           │
│        │ insertNew (dedupe by id)        ├─ NotificationCenterSource  (read-only SQLite) │
│        ▼                                 └─ GraphSource               (HTTPS, Phase 2)    │
│ InboxStore (GRDB DatabaseQueue)                                                          │
│   inbox_item ── triggers ──► inbox_fts (FTS5)      kv (cursors/settings)                 │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```
- **InboxCore** has no AppKit/SwiftUI dependency, so it's unit-testable and reusable (e.g. a future CLI or widget).
- UI updates are push-based via `ValueObservation`; capture writes trigger UI refresh automatically.
- The app stays alive when the window closes (`applicationShouldTerminateAfterLastWindowClosed = false`).

## 5. Data model
`inbox_item`
| column | type | notes |
|---|---|---|
| id | TEXT PK | `nc:<uuid>` or `graph:mail:<id>` / `graph:chat:<id>` |
| platform | TEXT | teams / outlook / whatsapp |
| origin | TEXT | notificationCenter / graph |
| sourceBundleId | TEXT | app that posted it |
| title, subtitle, body | TEXT | sender / chat-or-subject / preview |
| threadId | TEXT | conversation key when available |
| receivedAt, capturedAt | DATETIME | indexed on receivedAt |
| isRead, isPinned, isArchived | BOOL | user state — never overwritten by re-capture |

`inbox_fts` — FTS5 external-content index (unicode61, diacritics removed); user input is converted to quoted prefix terms, so search is injection-safe.
`kv` — `notificationCenter.lastRecId`, `graph.mail.since`, etc.

## 6. Privacy & security
- All data in `~/Library/Application Support/UnifiedInbox/inbox.sqlite`; no telemetry; network only when Graph is enabled.
- Notification Center DB opened **read-only**; app never writes to system databases.
- Full Disk Access is broad: explained in onboarding, and the app reads only the NC database.
- Distribution: Developer ID + hardened runtime + notarization. **Not Mac App Store** — the sandbox forbids reading the NC database.
- Phase 3 option: encrypt the store with SQLCipher (GRDB supports it) and keep the key in Keychain.

## 7. UX summary
- Sidebar: All, Unread, Pinned · Teams, Outlook, WhatsApp (with unread badges) · Archived.
- List rows: platform badge, sender, relative time, subtitle, 2-line preview, unread dot, pin icon.
- Detail: full captured text (selectable), actions (read, pin, archive, open in app).
- Keyboard: ⌘R refresh, ⇧⌘K mark all read, ⌫ archive selection, ⌘F search.
- Setup banner when capture needs Full Disk Access, with "Open Settings" and "Check Again".

## 8. Roadmap
| Phase | Scope |
|---|---|
| **1 — MVP (this scaffold)** | NC capture for all three, store + FTS, inbox UI, menu bar, settings, retention, tests |
| 1.1 | Onboarding window, per-platform enable toggles, thread grouping view, keyboard navigation (j/k), notification sound/badge rules, export to CSV |
| 2 — Microsoft 365 | MSAL sign-in, Graph source for Outlook/Teams, full content, deep links (`msteams:` / Outlook web link), two-way read state for Outlook |
| 3 — Power features | Rules (VIP senders, keyword alerts, auto-archive), Focus-aware digest, SQLCipher encryption, Sparkle auto-updates, signed/notarized DMG |
| 4 — Optional | Reply from inbox (Graph), more sources (Slack, Gmail), on-device summaries |

## 9. Risks
| Risk | Impact | Mitigation |
|---|---|---|
| macOS changes NC DB path/schema/permissions | Capture stops | Multi-path probe, tolerant parser, health check + banner, AX fallback (§3.3), fixture tests per macOS version |
| User declines Full Disk Access | No capture | Clear onboarding; Graph still works for Teams/Outlook |
| Previews hidden / chats muted | Missing content | UI note; Graph for Microsoft content |
| Tenant blocks Graph consent | No Phase 2 for that account | NC capture remains default |
| Duplicates between NC and Graph | Noise | Platform hand-off in coordinator |

## 10. Verification status
- `InboxCore` builds and all 9 unit tests pass (verified on Swift 6.0.3, Linux).
- The SwiftUI app target has not been compiled yet — first build must happen in Xcode on a Mac. Expect small fixes.
- The Notification Center schema was checked against a fake DB fixture, not a live macOS 15/26 DB — confirm on your Mac before trusting it.
