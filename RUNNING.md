# How to Run Unified Inbox

Step-by-step guide to building, running and checking the app on your Mac.

---

## 1. Prerequisites

| Need | How to check |
|---|---|
| macOS 13 Ventura or later (Intel or Apple Silicon) | Apple menu → About This Mac |
| Xcode 15 or later | `xcodebuild -version` |
| Command-line tools selected | `xcode-select -p` should print `/Applications/Xcode.app/Contents/Developer` |
| Teams, Outlook and/or WhatsApp desktop apps installed and signed in | Open each app once |

If the command-line tools path is wrong:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## 2. Turn on notifications in each source app

The app only sees what macOS shows as notifications, so for **each** of Microsoft Teams, Microsoft Outlook and WhatsApp:

1. **System Settings → Notifications → [app]**
2. **Allow notifications:** on
3. **Alert style:** Banners or Alerts (not None)
4. **Show previews:** Always (otherwise message text is hidden)

Also check notifications are enabled inside each app (Teams → Settings → Notifications; Outlook → Settings → Notifications; WhatsApp → Settings → Notifications).

---

## 3. Run the tests (optional, ~1 min first time)

```bash
cd ~/Desktop/DEV/UnifiedInbox
swift test
```
Expected: `Executed 9 tests, with 0 failures`. The first run downloads GRDB.

---

## 4. Option A: Run from Xcode (best for development)

1. Open the project:
   ```bash
   cd ~/Desktop/DEV/UnifiedInbox
   open Package.swift
   ```
2. Wait for Xcode to finish **Resolving Package Graph** (status bar at the top).
3. In the scheme picker (top toolbar) choose **UnifiedInbox** → **My Mac**.
4. Press **⌘R**.
5. The Unified Inbox window opens and a tray icon appears in the menu bar.

> **Full Disk Access when running from Xcode:** the running binary isn't a standalone `.app`, so macOS
> attributes the access to **Xcode**. Add **Xcode** to Full Disk Access (step 6), then stop and run again.

If the build fails, the errors will be in the SwiftUI files (`Sources/UnifiedInboxApp/`). The core library is
tested, so problems are almost always small SwiftUI API issues. Send me the error text and I'll fix it.

---

## 5. Option B: Build a real .app (best for daily use)

```bash
cd ~/Desktop/DEV/UnifiedInbox
./scripts/build-app.sh
open dist/UnifiedInbox.app
```
- Builds a universal binary (Apple Silicon + Intel) in release mode.
- Output: `dist/UnifiedInbox.app` (ad-hoc signed).
- Optional: drag it into `/Applications` **before** granting Full Disk Access, so the grant points at the copy you'll keep using.

Debug build instead: `./scripts/build-app.sh --debug`

Running `swift run UnifiedInbox` from Terminal also works, but then Full Disk Access must be given to **Terminal** (or iTerm).

---

## 6. Grant Full Disk Access (required on macOS 15+)

On first launch you'll see a yellow banner: *"Grant Full Disk Access…"*.

1. Click **Open Settings** in the banner (or System Settings → Privacy & Security → **Full Disk Access**).
2. Click **+**, choose the right item:
   - Built app → `UnifiedInbox.app` (in `dist/` or `/Applications`)
   - Running from Xcode → `Xcode.app`
   - `swift run` → your terminal app
3. Make sure the toggle is **on**.
4. Back in Unified Inbox click **Check Again** (or quit and relaunch).
5. The banner disappears; Settings → Sources shows **Active**.

On macOS 13–14 this step is usually not needed.

> Rebuilding with ad-hoc signing can change the app's identity. If capture stops after a rebuild,
> remove UnifiedInbox from Full Disk Access with **–**, add it again, and relaunch.

---

## 7. Check it's working

1. Send yourself a test message (e.g. a Teams chat from your phone, a WhatsApp message, or an email).
2. Wait for the macOS banner to appear.
3. Within ~2 seconds it shows in Unified Inbox under **All** and its platform section, and the menu-bar count goes up.
4. Search for a word from the message using the search field (⌘F).

Existing notifications still listed in Notification Center are imported on first launch.

---

## 8. Everyday use

### Window & menu bar
| Action | How |
|---|---|
| Open the inbox window | Menu-bar icon → **Open Inbox** |
| Refresh now | ⌘R or toolbar ↻ |
| Mark all read (current view) | ⇧⌘K |
| Search | ⌘F |
| Settings | ⌘, or menu-bar ⚙︎ |
| Keep running in background | Close the window; the app stays in the menu bar |
| Quit completely | Menu-bar icon → **Quit** |
| Start automatically | Settings → General → **Launch at login** |

### Single-key triage (inbox window, when not typing in a text field)
| Key | Action |
|---|---|
| j / k | Next / previous message |
| e | Archive (in Archived: move back to inbox) |
| p | Pin / unpin |
| u | Read / unread |
| s | Snooze until tomorrow 08:00 |
| z | Snooze 1 hour |
| o or ↩ | Open in the source app |
| ⎋ | Clear selection |

More snooze options (3 hours, this evening 18:00, next Monday 08:00) are in the right-click menu and the detail toolbar.
Snoozed messages are hidden until their time, then come back **unread**. See them under **Snoozed** in the sidebar.

### More apps
Settings → **Sources** → turn on Slack, Messages, Mail, Discord, Telegram or Signal.
Turning one on re-reads Notification Center, so notifications already there are imported. The app's
notifications must be on, with previews set to Always (step 2).

### VIP senders & keyword alerts
Settings → **Alerts**:
- **VIP senders**: names matched against the sender/chat name, e.g. `Martin Nicholson, Mom`.
- **Keywords**: whole words or phrases, e.g. `urgent, server down`. End with `*` for prefixes: `invoice*` also matches "invoices".
- Click **Apply to All Messages** to re-flag existing messages.

Matching messages get a ★, appear under **Priority** in the sidebar, and (if enabled) trigger a banner and sound.
The banner only works in the built `.app` (Option B). When running from Xcode you get just the sound.

### Hover info
- Hover a message for a tooltip with the full text, exact time, app, conversation size and flags (★, pinned, snoozed).
- While hovering, the timestamp turns into quick buttons: read/unread, pin, snooze, archive, open.
- Hover sidebar items, app badges, the unread dot and toolbar buttons for what they do and their shortcuts.

### When a source app is closed
A closed app posts no notifications, so its messages can't be captured. Unified Inbox detects this:
- An orange 🌙 appears next to the app in the sidebar, and a banner names the closed apps.
- **Open in Background** launches them hidden, without switching to them.
- **Keep Running** (banner, sidebar right-click, or Settings → Sources) reopens the app hidden at startup and
  whenever it quits. It stops after 3 relaunches in 10 minutes so it doesn't fight you if you quit it on purpose.
- Settings → Sources → **Notify me when a source app is closed** posts a banner when one quits (built `.app` only).

For Teams and Outlook messages to arrive with the apps fully closed, the Microsoft 365 sign-in (Phase 2) is needed.

### Conversations, quick look, export, privacy
| Feature | How |
|---|---|
| Group by conversation | ⇧⌘G, toolbar stack icon, or View menu. Rows show a count; the detail pane shows the whole chat |
| Quick look from any app | ⌃⌥Space opens a search panel. Type to search, ↩ opens the top result, ⎋ closes. Toggle in Settings → General |
| Export | Toolbar share icon or File → Export: CSV, JSON or Markdown. Exports the selected messages, or the whole current view |
| Privacy mode | View menu or Settings → General. Hides message text in the menu bar, quick look and banners |
| Copy a message | Right-click → Copy Message |

If ⌃⌥Space does nothing, another app already uses that shortcut. Quit that app or turn its shortcut off.

### Tools (Focus, Apps, Clipboard) and global shortcuts
| Shortcut | What it does |
|---|---|
| ⌥Space | Command palette: apps, ~40 commands, aliases (`yt`, `g swift charts`). Start with `>` for commands only |
| ⌃⌥Space | Search the inbox |
| ⌃⌥V | Clipboard history: ↑↓ then ↩ copies, then ⌘V to paste |
| ⌥⇧⌘4 / ⌥⇧⌘2 | Screenshot region / copy text from screen (OCR) |
| ⇧⌘F | Start / stop a focus session |
| ⌘1 … ⌘9 | The first nine pages in the Go menu (Overview, Monitor, Launcher, Widgets, Apps, Clipboard, Focus, Windows, …). The rest are in the sidebar and ⌥Space |
| ⌃⌥← → ↑ ↓ | Tile the focused window to a half (press again to cycle ½ → ⅓ → ⅔) |
| ⌃⌥↩ / ⌃⌥C | Maximize / center the focused window |

First use of each tool asks macOS for its permission once: Screen Recording (screenshots/OCR),
Automation (Music/Spotify control) and Notifications (reminders, timer). Check them all in **Settings → Privacy**.

App icon: built into the .app by `build-app.sh`. To change it, edit `scripts/make_icon.py` and run `python3 scripts/make_icon.py`.
If the Dock still shows the old icon, run `killall Dock`.

### System alerts and history
**Settings → Nexus → System alerts**: turn on alerts for high CPU (sustained), memory pressure, low battery and low disk.
Each alert fires once per breach, then waits until the condition clears and the cooldown passes.
**System Monitor → Battery / Storage** charts the last 24 hours (one point every 5 minutes, kept across restarts).

### Windows: tiling and workspaces
**Windows** page (Tools section). Tiling needs **Accessibility** permission: the first tile asks for it, or use
System Settings → Privacy & Security → Accessibility and add `UnifiedInbox.app`. Rebuilding the app can reset the
permission; remove and re-add the app if tiling stops working.
- **Tiling**: click a layout or use ⌃⌥ arrows / ↩ / C. Set a gap between windows. "Move to Next Display".
- **Workspaces**: "Save Current…" stores open apps and their window positions. "Switch" reopens missing apps in
  the background and puts windows back (optionally hiding other apps). Also in ⌥Space: type `workspace`.

### Notes
**Notes** page (Tools). Each note is a plain Markdown file in `~/Library/Application Support/UnifiedInbox/Notes/`
("Show Folder"), so any editor works too. Type `[[Another note]]` to link; click the link in Preview to open it
(or create it). The bottom of a note lists notes that link to it and notes that mention it without a link.
Renaming a note (edit the title, press ↩) updates links everywhere. The calendar button opens today's daily note.
Search with `#tag` to filter by tag. Right-click a message → "Add to Today's Note".

### Files
**Files** page (Tools): **Large Files** (pick a folder and a minimum size), **Downloads** (grouped by type, with
suggestions: installers/archives older than a week, anything else older than 90 days) and **Duplicates**
(byte-for-byte identical files; select all but the oldest or newest copy). Selected items go to the **Trash**
after you confirm, so they can be restored. macOS asks once before the app reads Desktop, Documents or Downloads.

### Habits and weekly review
**Habits** page (Tools). Add a habit (every day, certain weekdays, or N times a week, with an optional daily
reminder), then tick the circles for the last 7 days. 🔥 is the current streak; the percentage is the last 30 days.
**Weekly Review** sums up the week: tasks done, focus minutes per day, habits, screen time and messages received.
Write a reflection and "Save as Note" to keep it in Notes. ⌥Space: type `done` to tick today's habits.

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| Banner keeps asking for Full Disk Access | Granted to the wrong item (see step 6); remove and re-add; fully quit and relaunch |
| "Notification Center database not found" | Your macOS version uses a new location. Run the command below and send me the output |
| Inbox empty, no errors | Source app notifications off, Focus mode on, or chat muted (step 2). Test with a fresh message |
| Messages show but text is blank | **Show previews** is not set to Always for that app |
| WhatsApp missing | Confirm the desktop app (not just WhatsApp Web in a browser) is posting notifications |
| Duplicate messages | Shouldn't happen; send me a screenshot |
| Xcode: "Missing package product GRDB" | File → Packages → **Reset Package Caches**, then build again |
| Launch at login toggle does nothing | Only works for the built `.app`, not when running from Xcode |

Find the notification database on your macOS version:
```bash
ls -la ~/Library/Group\ Containers/group.com.apple.usernoted/db2/ 2>&1
ls -la "$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/" 2>&1
sw_vers
```

See which app identifiers macOS is recording (needs Full Disk Access for Terminal):
```bash
sqlite3 ~/Library/Group\ Containers/group.com.apple.usernoted/db2/db "SELECT identifier FROM app;"
```
If Teams/Outlook/WhatsApp appear under a different identifier than in `Sources/InboxCore/Models/Platform.swift`, add it there.

View logs: open **Console.app**, filter by process `UnifiedInbox`.

---

## 10. Reset or uninstall

Delete all captured messages and start fresh (quit the app first):
```bash
rm -rf ~/Library/Application\ Support/UnifiedInbox
```

Uninstall: quit the app, delete `UnifiedInbox.app`, run the command above, and remove it from
System Settings → Privacy & Security → Full Disk Access and General → Login Items.
