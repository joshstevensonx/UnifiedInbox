# Unified Inbox: Feature Backlog

Effort: **S** ≈ a day · **M** ≈ a few days · **L** ≈ a week or more.
Status: ✅ built (core unit-tested; UI not yet compiled on a Mac) · 🚧 in progress · ⬜ not started

## Now building (batch 1)
| Feature | Effort | Status |
|---|---|---|
| More sources via Notification Center: Slack, Messages, Discord, Telegram, Signal, Apple Mail + per-app on/off | S | ✅ |
| Snooze (1 hour, this evening, tomorrow morning, next week) with auto-return as unread | S–M | ✅ |
| VIP senders + keyword alerts → Priority view, ★ marker, optional alert sound/banner | S | ✅ |
| Keyboard-first triage (j/k, e, p, u, s, o/↩, ⎋) | S | ✅ |
| Thread grouping ("Jane (5 new)") + conversation view | M | ✅ |
| Global quick-look hotkey (⌃⌥Space search panel) | M | ✅ |

## Batch 2
| Feature | Effort | Status |
|---|---|---|
| Hover info: rich tooltips on messages, sidebar, badges, buttons; hover quick actions on rows | S | ✅ |
| Closed-app detection: sidebar/banner warnings, "Open in Background", "Keep running" auto-relaunch, closed-app alert | M | ✅ |
| Export CSV / JSON / Markdown (selection or current view) | S | ✅ |
| Privacy mode: mask previews in menu bar, quick look, banners | S | ✅ |
| Menu-bar stats text ("★2 · 12") | S | ✅ |
| Copy message to clipboard | S | ✅ |

## Triage & productivity
- ⬜ Send to task: Apple Reminders, Things, Todoist, Asana, Notion (M)
- ⬜ Follow-up reminders: "remind me if no reply in 2 days" (M)
- ⬜ Command palette ⌘K with natural commands (M)
- ✅ Saved searches as sidebar items (S)
- ✅ Private notes on a message (S)

## Batch 3: NEXUS merge (see docs/NEXUS_Product_Documentation.md)
| Feature | Spec | Status |
|---|---|---|
| Sidebar NEXUS section: Overview, System Monitor, Launcher, Widgets (⌘1–⌘5 via Go menu) | §4 | ✅ |
| Shared monitoring coordinator: off-main sampling, 2 s / 15 s adaptive, battery 30 s, storage 60 s, sleep/wake aware, bounded 5-min history | §5.3, §7, §12 | ✅ |
| Real CPU, memory (+pressure), battery, network, storage, uptime, Mac identity; explicit "Unavailable" / "No battery" states | §5.3, §11 | ✅ |
| Overview page: identity, metric cards with sparklines, inbox card, quick actions, pinned apps, active widgets | §6 | ✅ |
| System Monitor page: CPU / Memory / Network / Battery / Storage tabs, labelled charts, pause | §6 | ✅ |
| Launcher: app discovery, ranked search (prefix, word, initials, fuzzy), pin, groups, folders (security-scoped bookmarks), links, sort modes, missing-app state | §5.2 | ✅ |
| Launcher panel ⌥Space: ↑↓ ↩ ⌘↩ ⎋ | §5.2 | ✅ |
| Floating widgets: CPU, Memory, Battery, Network, Storage, Clock, Inbox; move, resize, duplicate, hide, opacity, always-on-top, history toggle; per-display restore + clamp | §5.5, §5.7 | ✅ |
| Widget gallery with live previews | §6 | ✅ |
| Menu bar: live CPU / memory / battery / network strip, pause, launcher button | §5.9 | ✅ |
| Inbox: banners no longer overlap (moved into list column), list header with chips, date sections, setup card | — | ✅ |

## Batch 4: from docs/App_Feature_Spec.md
| Feature | Spec | Status |
|---|---|---|
| App icon (dark glass hub + three source orbs), `scripts/make_icon.py` → `Resources/AppIcon.icns` | — | ✅ |
| Command palette in ⌥Space: ~40 commands, apps, aliases (`yt`, `g {query}`), `>` for commands only | §7.1, §1.4 | ✅ |
| Clipboard history: text, URL, colour, path, image; pin, search, filters, copy back; skips password managers; ⌃⌥V panel + page | §14.3, §6.5 | ✅ |
| Apps: running apps with CPU and memory, quit, force quit (confirmed), restart, hide | §2.1, §4.3 | ✅ |
| Screen time: foreground time per app, idle detection (5 min), 7-day chart, productive/neutral/distracting | §2.3 | ✅ |
| Media: Now Playing + play/pause/next/previous for Music and Spotify (AppleScript, no private APIs) | §1.1 | ✅ |
| Capture: region, window, full, 5 s delayed screenshots to clipboard / Desktop / Pictures | §6.1 | ✅ |
| OCR: copy text from a screen region, or from an image/PDF file (Vision, on-device) | §3.5, §6.1 | ✅ |
| Tasks: quick-add parsing (today/tomorrow, !priority, #tags), priorities, due dates + reminders, filters | §11.1, §11.2 | ✅ |
| Pomodoro: focus/short/long breaks, menu-bar countdown, per-task focus minutes, daily log, streak | §11.3 | ✅ |
| Permissions dashboard + "Your data" (Settings → Privacy) | §8.2, §13.2 | ✅ |
| Tools menu shortcuts: ⌥⇧⌘4 region, ⌥⇧⌘2 OCR, ⇧⌘F focus | — | ✅ |

## Batch 5: everything that needs no account or payment
UI items marked ✅ are syntax-checked on Linux but **not yet compiled on a Mac** (run `./scripts/build-app.sh`).

| # | Feature | Status |
|---|---|---|
| 11 | Inbox rules engine (sender / keyword / app → archive, pin, label, mute), labels with colours, quiet hours, auto-archive read messages | ✅ |
| 12 | Saved searches in the sidebar, private notes, "Remind me", Add to Tasks / Apple Reminders, export by date range | ✅ |
| 13 | Threshold alerts (CPU sustained, memory pressure, low battery, low disk; debounced + cooldown) and 24 h battery / storage history charts | ✅ |
| 14 | Window tiling (16 layouts, ⌃⌥ hotkeys, ½→⅓→⅔ cycling, gaps, next display) + workspaces (save / switch apps and window frames, hide others) | ✅ |
| 15 | Notes: plain `.md` files, Markdown preview with clickable tasks, [[links]] (click to open / create), backlinks + unlinked mentions, rename updates links, #tags, daily notes, "Add to Note" from a message | ✅ |
| 16 | File tools: large-file finder (size threshold, skips Library/.git/node_modules), Downloads cleanup by category with age-based suggestions, byte-exact duplicate finder (keep oldest/newest), Move to Trash with confirmation | ✅ |
| 17 | Habits (daily / weekdays / N× per week, 7-day grid, streaks, 30-day rate, daily reminder) + weekly review (tasks, focus chart, habits, screen time, messages, reflection, save as note) | ✅ |
| 18 | App lock (Touch ID or Mac password; after N min away, on sleep, on screen lock; covers window, menu bar, quick look, clipboard, launcher) + encrypted backup (AES-256-GCM, PBKDF2-SHA256 210k) and staged restore with automatic restart | ✅ |
| 19 | Hotkey manager: one registry for all global shortcuts, record / clear / reset per action, conflict and "owned by another app" warnings, extra assignable actions (today's note, focus, screenshot, OCR, lock, play/pause, every tile layout) | ✅ |
| 20 | Automation: triggers (new message with filters, app opens / quits, time of day + weekdays, battery low, CPU high, focus start / end) → actions (notify, open / quit / hide app, URL, workspace, focus, Shortcuts, sound, copy, task, daily note, privacy mode, palette command) with {placeholders}, cooldown, loop guard, Run Now, run log | ✅ |
| 21 | Text snippets: abbreviation → expansion in any app (global key monitor + paste, clipboard restored, transient so clipboard history skips it), {date} {time} {clipboard} {cursor}…, word-boundary matching, overlap warnings, excluded apps, never in password fields | ✅ |
| 22 | Process manager (all processes) + log viewer | ⬜ |
| 23 | `inboxctl` CLI + stdio MCP server over the local DB | ⬜ |
| 24 | Ambient clock, density / accent settings, hot-corner launcher, daily digest | ⬜ |

## From the feature spec: good next candidates
- ✅ Window snapping / tiling layouts (needs Accessibility permission) §6.2
- ✅ Workspaces: save/restore running apps + window positions §2.2
- ✅ Text expansion / snippets (needs Accessibility) §1.4
- ✅ Notes with Markdown, backlinks, daily notes §10
- ✅ File tools: large-file finder, Downloads cleanup, duplicates §3.3
- ✅ Threshold alerts: CPU, memory pressure, low battery, low disk §4.4 (batch 5)
- ✅ Habit tracker + weekly review §11.3–11.4
- ✅ Hotkey manager with rebinding §8.1
- ✅ App lock with Touch ID §13.1
- ⬜ Not planned: private-API features (MediaRemote, fan/temperature via SMC, /etc/hosts blocking)

## NEXUS: not built yet
- ⬜ Process manager (P1)
- ✅ Workspaces: save / switch layouts (P1)
- ⬜ Ambient clocks and scenes
- ✅ Threshold alerts: CPU, memory pressure, low battery, low disk (opt-in, debounced)
- ✅ Automation rules
- ⬜ Launcher edge / hot-corner reveal (task 24); ✅ configurable hotkeys
- ✅ Battery and storage history charts (24 h)

## Up next (batch 4)
- ✅ Saved searches as sidebar items (S)
- ✅ Quiet hours per app (S)
- ✅ Private notes on a message (S)
- ✅ Touch ID lock (S)

## Messages when apps are fully closed
A closed app posts no notifications, so local capture can't see its messages. "Keep running" (batch 2) covers most cases.
The complete fix is per platform:
- Teams / Outlook: Microsoft Graph sign-in (Phase 2 in SPEC.md), which works with the apps closed.
- WhatsApp: no personal API; the desktop app must be running (Keep running handles this).
- Slack / Discord / Telegram: their own APIs (each L).

## Smart filtering & rules
- ✅ Full rules engine: sender / keyword / app → archive, pin, label, alert (M)
- ✅ Labels / colours per client or project (S)
- ✅ Auto-cleanup: archive group-chat noise after X hours (S)
- ⬜ Noise detection: learn threads you always archive unread (M)

## On-device AI (private)
- ⬜ Daily / hourly digest (M)
- ⬜ Priority scoring from sender, keywords, wording (M–L)
- ⬜ Thread summaries (M)
- ⬜ Draft replies to copy into the source app (L)
- ⬜ Date & task extraction → calendar (M)
- ⬜ Natural-language search, reusing a local llama.cpp backend (L)

## Focus & wellbeing
- ⬜ Focus sessions with summary afterwards (M)
- ✅ Quiet hours per app (S)
- ⬜ Batched delivery every 30/60 min (M)
- ⬜ Work / personal split views (S)
- ⬜ Volume & response-time analytics (M)

## More sources
- ⬜ "Any app" picker for Notification Center capture (S)
- ⬜ Gmail / Google Calendar via API (L)
- ⬜ Calendar sidebar with upcoming meetings (M)
- ⬜ Webhook / email-forward inbox for alerts (M)

## Actions back in source apps
- ⬜ Reply from inbox (Graph for Teams/Outlook, click-to-chat for WhatsApp) (L)
- ⬜ Two-way read state for Outlook/Teams (M)
- ⬜ Deep links to the exact chat / email / contact (M)
- ⬜ Mark done in Outlook when archived here (M)

## UI / UX
- ⬜ Desktop & Notification Center widgets (M)
- ⬜ Compact / comfortable density, themes (S)
- ⬜ Contact avatars, per-app accent colours (M)
- ✅ Menu-bar stats text (S)
- ⬜ Shortcuts app actions (App Intents) (M)
- ⬜ Siri / voice queries (M)

## Data & integration
- ✅ Export CSV / JSON / Markdown (by date range / client: ⬜)
- ⬜ Local CLI / API (M)
- ⬜ MCP server so AI assistants can query the inbox locally (M)
- ✅ Encrypted backup & restore (S)
- ⬜ End-to-end encrypted sync between Macs (L)
- ⬜ Per-client message counts for billing (M)

## Security & reliability
- ⬜ SQLCipher-encrypted database, key in Keychain (M)
- ✅ Touch ID lock (S)
- ✅ Privacy mode: mask previews in menu bar / quick look / banners (widgets: ⬜)
- ⬜ Capture self-healing after macOS updates (M)
- ⬜ Sparkle auto-updates + notarized DMG (M)
- ⬜ Local log viewer (S)
