# Mac Desktop App — Feature Specification Breakdown

> **Version:** 1.0  
> **Platform:** macOS  
> **Architecture:** Local-first, privacy-preserving, offline-capable  
> **UI Framework:** SwiftUI (native)

---

## Table of Contents

1. [Smart App & Web Control](#1-smart-app--web-control)
2. [Application Management](#2-application-management)
3. [File Operations](#3-file-operations)
4. [System Monitoring](#4-system-monitoring)
5. [Automation System](#5-automation-system)
6. [Screen Control](#6-screen-control)
7. [Modern UI & UX](#7-modern-ui--ux)
8. [Settings & Preferences](#8-settings--preferences)
9. [Local Memory System (Non-AI)](#9-local-memory-system-non-ai)
10. [Notes & Knowledge Management](#10-notes--knowledge-management)
11. [Task & Time Management](#11-task--time-management)
12. [Voice System (Offline Only)](#12-voice-system-offline-only)
13. [Security & Privacy](#13-security--privacy)
14. [Developer & Power User Features](#14-developer--power-user-features)

---

## 1. Smart App & Web Control

Unified control layer for media, browsers, apps, and contextual actions — all accessible via keyboard, hotkey, or command palette.

### 1.1 Media Control

Centralised media management that works across native apps and web players without requiring internet access.

| Feature | Description |
|---|---|
| Play / Pause / Stop | System-level media transport controls via `MediaRemote` framework, usable regardless of which app owns playback. |
| Skip Forward / Back | Track and chapter skipping, with configurable skip intervals for podcasts and audiobooks. |
| Volume Normalization | Leveled playback volume across switching sources, preventing sudden loudness spikes. |
| Media Session Detection | Detects the currently active media app and exposes its state (track title, artwork, progress) in the UI. |
| Spotify / Apple Music Control | Deep integration using AppleScript and `MediaRemoteFramework` for local control — no cloud API required. |
| Multi-Device Media Handoff | Coordinates playback hand-off between devices on the same local network (AirPlay / Continuity). |
| Global Media Hotkeys | User-assignable global shortcuts for all transport actions, intercepted at the system level. |

---

### 1.2 Browser Control

Keyboard and command-driven browser management supporting all major macOS browsers via AppleScript and accessibility APIs.

| Feature | Description |
|---|---|
| Open URLs Locally | Instantly open any saved or typed URL in the default or a specified browser profile. |
| Tab Switching | Fuzzy-search open tabs across all browser windows and jump to them by name or URL. |
| Bookmark Launcher | Browse and launch browser bookmarks via the command palette without opening the browser first. |
| Browser Profile Switching | Switch between Chrome/Firefox/Safari profiles from a single picker, including Incognito/Private windows. |
| Session Restore | Save and restore named browser sessions (sets of tabs) with one action. |
| Quick Website Macros | Record and replay multi-step browser interactions (click, fill, navigate) as saved macros. |
| Auto-Fill Templates | Pre-defined text templates injected into active browser fields on demand. |
| Browser Automation Sequences | Multi-step automated browser workflows triggered by hotkey or event, built in the visual editor. |
| Web App Launcher | Launches pinned web apps in their own window (SSB-style) without full browser chrome. |
| Browser Workspace Management | Groups related tabs and browser windows into named workspaces that can be saved and switched as a unit. |

---

### 1.3 Contextual Actions

The app observes the active window and surfaces relevant commands, shortcuts, and suggestions without requiring manual input.

| Feature | Description |
|---|---|
| Detect Active Window | Polls the Accessibility API to identify the frontmost app and window at all times. |
| Per-App Quick Commands | User-defined command sets that appear only when a specific app is focused. |
| App-Specific Shortcut Overlays | Displays a cheat-sheet overlay of the active app's shortcuts, pulled from a curated local database. |
| Smart Contextual Menus | Right-click and hotkey menus whose options adapt based on the current app, selection, and clipboard content. |
| Recent Activity Actions | Surfaces recently opened files, visited URLs, and executed commands relevant to the current context. |
| Clipboard-Aware Commands | Detects clipboard content type (URL, file path, color hex, code snippet) and offers relevant actions. |
| Focus-Based Suggestions | Proactively suggests workflows or actions based on the active app and time of day patterns. |

---

### 1.4 Quick Actions

Single-trigger access to frequently used workflows, macros, and app launches.

| Feature | Description |
|---|---|
| Launch Saved Workflows | Execute any saved automation workflow from the command palette or an assigned hotkey. |
| One-Key Macros | Single-keystroke triggers for any sequence of actions, configurable per app or globally. |
| Favorite App Launcher | Pinned list of frequently used apps launched instantly from the dock widget or hotkey. |
| Hotkey Automation | Bind any system or app-level action to a global keyboard shortcut. |
| Command Aliases | Create short text aliases (e.g., `yt` → open YouTube) usable in the launcher. |
| Text Expansion / Snippets | Expand abbreviations into full text strings anywhere in macOS — supports dynamic fields like date, clipboard, cursor position. |

---

## 2. Application Management

Full lifecycle control over every application on the system, with workspace presets and usage analytics.

### 2.1 Application Lifecycle

| Feature | Description |
|---|---|
| Launch Applications | Launch any installed app by name, fuzzy match, or alias — supports arguments and launch options. |
| Quit Applications | Gracefully quit one or multiple apps simultaneously. |
| Restart Applications | Quit and relaunch an app in one step, useful after configuration changes. |
| Force Quit Frozen Apps | Detect and force-quit unresponsive apps via `NSRunningApplication`. |
| Relaunch Crashed Apps | Watch-dog mode that automatically relaunches designated apps when they exit unexpectedly. |
| Delayed App Startup | Schedule an app to launch after a defined delay following login or an event trigger. |
| Background Launch Support | Launch apps hidden (no dock icon, no activation) for background services. |

---

### 2.2 Workspace Management

| Feature | Description |
|---|---|
| Workspace Presets | Named collections of apps, windows, and layouts that can be activated with a single command. |
| Save / Restore Open Apps | Snapshot currently running apps and window positions; restore the exact state later. |
| Multi-Monitor Layouts | Define per-monitor window arrangements that persist across display connect/disconnect events. |
| Per-Project Workspaces | Associate a workspace preset with a project folder; switching projects loads the correct environment. |
| Focus Workspaces | Minimal workspaces that quit all irrelevant apps and close unrelated windows for deep work. |
| App Grouping | Organize apps into named groups (e.g., "Design Tools", "Dev Environment") for batch launch/quit. |

---

### 2.3 Usage Analytics

Local-only usage data for personal productivity insight — no data leaves the device.

| Feature | Description |
|---|---|
| App Usage Statistics | Time spent per application per day, week, and month, stored locally in SQLite. |
| Productivity Tracking | Categorize apps as productive, neutral, or distracting and track ratios over time. |
| Time Spent per Application | Granular session logs showing exact active-foreground time per app. |
| Idle Detection | Detects keyboard/mouse inactivity and pauses time tracking after a configurable threshold. |
| Session History | Full log of app switch events with timestamps, browsable in the analytics dashboard. |
| App Frequency Analysis | Ranks apps by launch frequency to inform workflow and launcher optimization. |

---

### 2.4 Startup Automation

| Feature | Description |
|---|---|
| Startup Routines | Ordered sequences of app launches and actions that run on login. |
| Scheduled Launches | Launch specific apps at set times of day. |
| Conditional App Startup | Launch apps based on conditions: network availability, display count, time of day, battery level. |
| Login Item Manager | View and control all macOS login items from a single interface, including hidden background agents. |
| Performance-Safe Startup Queue | Staggers startup launches to avoid CPU/disk spikes during boot. |

---

## 3. File Operations

A comprehensive local file management layer with intelligent organization, search, and OCR capabilities.

### 3.1 File Management

| Feature | Description |
|---|---|
| Open Files / Folders | Open any file in its default or a specified app directly from the command palette. |
| Copy / Move / Delete Files | Execute file operations via command or automation without opening Finder. |
| Batch Rename | Rename multiple files using patterns, sequences, date stamps, and regex substitution. |
| File Tagging | Assign searchable tags to files; tags are stored in macOS extended attributes for cross-app compatibility. |
| Quick Previews | QuickLook-powered previews for files without fully opening them. |
| Drag-and-Drop Operations | System-level drag-and-drop support so files from the app's file browser work natively with other apps. |
| Secure Delete | Overwrites file data before removal to prevent trivial recovery. |
| Archive Extraction / Compression | Extract ZIP, TAR, 7Z archives and compress selections without leaving the app. |

---

### 3.2 Search & Indexing

| Feature | Description |
|---|---|
| Instant Filename Search | Sub-second fuzzy filename search across the local filesystem using an in-process index. |
| Metadata Search | Search by file creation date, modification date, kind, size, and macOS tags. |
| Semantic-Style Local Search | Non-AI keyword and local vector indexing for relevance-ranked results — no LLM required. |
| OCR-Indexed Document Search | Text extracted from scanned PDFs and images is indexed and fully searchable. |
| Content Indexing | Indexes the text body of documents (PDF, Word, Markdown, plain text) for full-text search. |
| Saved Searches | Persist any search query as a named shortcut for repeated use. |
| Smart Filters | Combine multiple filter criteria (type, date, tag, location) and save as reusable filter presets. |

---

### 3.3 File Intelligence

| Feature | Description |
|---|---|
| Duplicate Detection | Identifies exact and near-duplicate files using content hashing and size comparison. |
| Large File Finder | Surfaces files and folders consuming the most disk space, sorted and filterable. |
| Empty Folder Cleanup | Scans for and removes empty directory trees with a preview-before-delete step. |
| Smart Downloads Cleanup | Detects installer files, disk images, and old archives in ~/Downloads and flags them for removal. |
| Old File Detection | Highlights files unaccessed beyond a configurable threshold (e.g., 6 months). |
| File Relationship Mapping | Tracks which apps created or last modified files to surface related items. |
| Recent File Tracking | Maintains a per-app and global history of recently accessed files, separate from macOS Recents. |

---

### 3.4 Organization Tools

| Feature | Description |
|---|---|
| Auto-Sort Downloads | Automatically moves incoming Downloads folder items to designated subfolders by file type or pattern. |
| Rule-Based File Organization | Define IF/THEN rules: if file matches criteria, move/rename/tag it. |
| Watch Folders | Monitor directories for new files and trigger an automation rule on arrival. |
| Smart Folder Generation | Auto-generate virtual smart folders based on saved searches and rules. |
| Auto-Tagging via Rules | Apply macOS tags automatically based on filename, location, or extension rules. |
| Project-Based File Grouping | Virtual project views that aggregate files from multiple locations under a single project label. |

---

### 3.5 OCR & Document Tools

| Feature | Description |
|---|---|
| OCR for PDFs / Images | Extracts machine-readable text from scanned documents and images using on-device Vision framework. |
| Searchable Scans | OCR output is indexed so scanned PDFs appear in full-text search results. |
| Text Extraction | Extract and copy text from any on-screen image or selected region. |
| Document Previews | Rich inline previews for PDF, DOCX, PPTX, and image files without opening external apps. |
| Local PDF Indexing | All PDF text (native and OCR-derived) is indexed locally for fast retrieval. |

---

## 4. System Monitoring

Real-time hardware, network, and process visibility with diagnostic reporting — all data stays local.

### 4.1 Hardware Monitoring

| Feature | Description |
|---|---|
| CPU Usage | Per-core and aggregate CPU load updated in real time; sparkline history in the menu bar widget. |
| GPU Usage | Metal / OpenGL GPU utilization, VRAM usage, and GPU process attribution. |
| RAM Usage | Physical memory pressure, app-by-app breakdown, and swap usage over time. |
| Disk Health | S.M.A.R.T. status, read/write error counts, and reallocated sector warnings for internal drives. |
| Disk Space Analysis | Treemap-style visualisation of storage usage by folder, app data, and system categories. |
| Temperature Monitoring | CPU, GPU, and ambient temperature sensors read via IOKit. |
| Fan Speed Monitoring | Current RPM and percentage of maximum for all system fans. |
| Battery Health Cycles | Cycle count, design capacity vs. current capacity, and charge health percentage. |
| Power Usage Tracking | Current draw in watts, estimated time remaining, and per-app power impact (from `Activity Monitor` model). |

---

### 4.2 Network Monitoring

| Feature | Description |
|---|---|
| Upload / Download Tracking | Real-time and historical bandwidth usage per interface and per process. |
| Connection Quality | Latency, packet loss, and jitter to a configurable local gateway check — no external ping required. |
| Local Network Device Viewer | Scans the LAN and lists connected devices with IP, hostname, and MAC address. |
| Firewall Event Logs | Reads macOS firewall (`pf` / `ALF`) logs and presents blocked/allowed connection events in a searchable table. |
| Bandwidth History | Rolling 24-hour and 30-day bandwidth graphs stored locally. |

---

### 4.3 Process Management

| Feature | Description |
|---|---|
| Running Process Viewer | Sortable table of all running processes with PID, CPU, RAM, and parent app. |
| Process Termination | Kill or force-kill any process directly from the viewer. |
| Resource-Heavy Process Detection | Alerts when any process exceeds configurable CPU or RAM thresholds. |
| Background Service Monitor | Highlights Launch Agents and Launch Daemons, showing their status and resource footprint. |
| Memory Leak Detection | Identifies processes whose memory usage grows continuously over time without release. |
| App Responsiveness Tracking | Monitors for "spinning wheel" states and logs the duration of unresponsive periods per app. |

---

### 4.4 Diagnostics

| Feature | Description |
|---|---|
| Startup Performance Diagnostics | Measures and visualizes boot time contributions per login item and launch agent. |
| Background Task Analysis | Summarizes background CPU and network activity that occurred while the user was idle. |
| Crash Log Viewer | Parses and presents macOS crash reports from `~/Library/Logs/DiagnosticReports` in readable format. |
| System Health Reports | Generates a point-in-time health snapshot covering hardware, storage, network, and processes. |
| Performance Alerts | Configurable alert rules that send a local notification when a metric breaches a threshold. |

---

## 5. Automation System

A fully local, event-driven workflow engine with a visual builder, rich trigger types, and multi-language script support.

### 5.1 Workflow Builder

| Feature | Description |
|---|---|
| Visual Automation Editor | Canvas-based editor where actions are placed as nodes and connected with flow lines. |
| Drag-and-Drop Workflow Designer | Action blocks can be dragged from a palette and reordered or branched visually. |
| Conditional Logic | IF / ELSE IF / ELSE branches that evaluate variables, system state, or action outputs. |
| Variables and States | Named variables (string, number, boolean, file path) that persist within and across workflow runs. |
| Multi-Step Workflows | Unlimited sequential and parallel action chains. |
| Looping Workflows | FOR EACH and WHILE loop constructs with configurable iteration limits to prevent runaway automation. |

---

### 5.2 Trigger Types

| Trigger | Description |
|---|---|
| Time-Based | Run at a specific time, on a recurring schedule (cron-syntax), or after an elapsed interval. |
| Folder Changes | Fire when a file is added, removed, or modified in a watched directory. |
| App Launches / Quits | Trigger when a specified application starts or closes. |
| USB Device Detection | Activate when a specific USB device (matched by vendor/product ID) is connected or removed. |
| Bluetooth Triggers | Fire on Bluetooth device connect/disconnect events. |
| Battery Level | Trigger when battery drops below or rises above a defined percentage. |
| Network State | Activate on Wi-Fi connect/disconnect or when a specific SSID becomes available. |
| Keyboard Shortcut | Global or app-scoped hotkey as a workflow trigger. |
| Voice Command | Offline speech recognition trigger using Apple's on-device `SFSpeechRecognizer`. |

---

### 5.3 Script Support

| Language / Integration | Description |
|---|---|
| AppleScript | Execute `.applescript` or inline AppleScript blocks as workflow actions. |
| Shell Script | Run arbitrary shell commands via `/bin/sh`. |
| Bash / Zsh | Execute `.sh` / `.zsh` scripts with the user's environment loaded. |
| Python | Run `.py` scripts using the system or a specified Python interpreter; output captured as a variable. |
| JavaScript Automation | JXA (JavaScript for Automation) scripts executed natively via `OSAScript`. |
| Shortcuts Integration | Trigger Apple Shortcuts by name as a workflow action or expose this app's workflows as Shortcut actions. |

---

### 5.4 Automation Actions

| Action | Description |
|---|---|
| Launch Apps | Open applications with optional arguments and window state. |
| Move Files | Copy, move, rename, or delete files and folders as automation steps. |
| Send Local Notifications | Push a macOS notification with a title, body, and optional action button. |
| Play Sounds | Play a system sound or custom audio file as a workflow step. |
| Change System Settings | Toggle Dark Mode, Do Not Disturb, Wi-Fi, Bluetooth, and other system preferences. |
| Window Positioning | Move and resize application windows to specific coordinates or layout presets. |
| Clipboard Manipulation | Read from, write to, transform, or clear the macOS clipboard within a workflow. |

---

## 6. Screen Control

Comprehensive capture, window management, focus, and display control tools for power users.

### 6.1 Capture Tools

| Feature | Description |
|---|---|
| Screenshot Capture | Full-screen, window, and region screenshots saved to a configurable location or copied to clipboard. |
| Delayed Screenshots | Configurable delay (1–30 seconds) before capture to allow menu states or tooltips to appear. |
| Region Screenshots | Drag-select any screen region; dimensions shown live in the selection overlay. |
| Window Screenshots | Capture a specific window without shadow or with drop shadow, matching the target window's bounds. |
| Screen Recording | Record the full screen or a selected region to MP4, with optional microphone audio. |
| GIF Recording | Capture a screen region as an optimized GIF with configurable frame rate and palette. |
| OCR from Screenshots | Run on-device OCR on any captured image and copy the extracted text to clipboard. |

---

### 6.2 Window Management

| Feature | Description |
|---|---|
| Snap Windows | Drag windows to screen edges or corners to snap them to predefined size positions. |
| Tiling Layouts | Apply named tile presets (halves, thirds, quadrants, custom grids) to one or all app windows. |
| Virtual Desktops | Create, switch, and assign apps to macOS Spaces from within the app. |
| Workspace Switching | Switch the entire window layout — including Spaces assignments — with a single shortcut. |
| Auto-Window Placement | When an app launches, automatically place its window based on a saved rule for that app. |
| Picture-in-Picture Support | Float any app window as a resizable PiP overlay above all other content. |

---

### 6.3 Focus Controls

| Feature | Description |
|---|---|
| Focus Mode | Activates a distraction-free session: hides dock, menu bar extras, and non-essential notifications. |
| Website Blocking | Blocks access to specified domains at the `/etc/hosts` level during focus sessions. |
| Notification Suppression | Temporarily enables macOS Focus/DND and silences all or selected notification categories. |
| App Restrictions | Prevents launching of specified apps during a focus session. |
| Session Timers | Focus sessions run for a defined duration; an alert sounds when the session ends. |

---

### 6.4 Display Controls

| Feature | Description |
|---|---|
| Brightness Control | Adjusts internal display brightness via IOKit, including support for connected external displays. |
| Volume Control | System output volume and per-app volume adjustment from the overlay. |
| Multi-Monitor Management | Arrangement, mirroring, and primary display selection without opening System Settings. |
| Resolution Switching | Switch display resolution and scaling from a compact picker. |
| Color Profile Switching | Toggle between ICC color profiles per display — useful for design vs. video work. |

---

### 6.5 Overlay Tools

| Feature | Description |
|---|---|
| Floating Assistant Panel | A persistent, draggable panel surfacing quick actions, media controls, and system status. |
| Quick Command Overlay | A hotkey-activated command palette that appears above all windows and dismisses on action or Escape. |
| Clipboard History Overlay | Browsable, searchable history of the last N clipboard entries with one-click paste. |
| Screen Annotation Tools | Freehand drawing, arrows, and text overlays on the live screen for presentations or recording. |
| Always-On-Top Widgets | Configurable mini-widgets (clock, timer, system stats) that float above all windows. |

---

## 7. Modern UI & UX

A native, keyboard-first macOS interface built with SwiftUI, designed to stay out of the way until needed.

### 7.1 Interface

| Component | Description |
|---|---|
| Native SwiftUI Interface | Built entirely in SwiftUI for optimal macOS integration, rendering performance, and system-theme compatibility. |
| Spotlight-Style Launcher | A single-field command palette invoked by a global hotkey — the primary entry point for all features. |
| Command Palette | Full fuzzy-search over all commands, apps, files, workflows, and settings from one input field. |
| Keyboard-First Navigation | Every element is reachable and operable by keyboard; mouse is always optional, never required. |
| Dock / Menu Bar Integration | A persistent menu bar icon exposing quick actions; optional Dock integration for workspace switching. |
| Floating Assistant Widget | An always-accessible mini panel for media controls, clipboard, and system stats. |
| Sidebar Navigation | An optional persistent sidebar categorizing all feature modules for mouse-driven access. |

---

### 7.2 Customization

| Feature | Description |
|---|---|
| Dark / Light Mode | Follows system appearance or can be locked to one mode independently. |
| Custom Themes | User-authored themes specifying colours, corner radius, and transparency levels. |
| Accent Color Customization | Overrides the macOS accent color for the app's own chrome and interactive elements. |
| Resizable Widgets | All overlay widgets have user-draggable resize handles. |
| Layout Presets | Save and recall the arrangement of open panels and sidebar state as named layout presets. |
| Custom Shortcuts | Every action in the app can be rebound from the Hotkey Manager — no hardcoded shortcuts. |

---

### 7.3 Accessibility

| Feature | Description |
|---|---|
| Full Keyboard Navigation | All UI elements expose proper accessibility roles and respond to standard keyboard navigation patterns. |
| Voice Accessibility | VoiceOver-compatible; all controls, labels, and states are correctly described to the screen reader. |
| Screen Reader Support | Full NSAccessibility protocol compliance for VoiceOver. |
| High Contrast Mode | A separate theme with increased contrast ratios meeting WCAG AA standards. |
| Adjustable UI Scaling | A global scale factor overrides the app's font and control sizes independently of system display scaling. |

---

### 7.4 Interaction Design

| Feature | Description |
|---|---|
| Smooth Animations | SwiftUI spring and easing animations throughout; respects the "Reduce Motion" accessibility setting. |
| Gesture Support | Trackpad gestures (swipe, pinch, scroll) mapped to navigation and workspace switching. |
| Drag-and-Drop Support | Files, text, URLs, and app icons can be dragged into the app from Finder or other apps. |
| Context Menus | Right-click menus on every item with context-appropriate actions. |
| Multi-Window Support | Secondary windows for note editing, analytics dashboards, and automation workflows run independently. |

---

## 8. Settings & Preferences

Centralized control over all app behaviour, privacy, performance, and the plugin system.

### 8.1 General Settings

| Feature | Description |
|---|---|
| App Preferences Manager | A structured Settings window mirroring macOS System Settings conventions for discoverability. |
| Hotkey Manager | Visual table of all registered shortcuts; shows conflicts and allows rebinding with a key-capture field. |
| Startup Behavior | Controls whether the app launches at login, starts hidden, and in what mode. |
| Background Mode Settings | Configures which features run in the background (indexing, monitoring, automation) and their activity levels. |

---

### 8.2 Privacy Controls

| Feature | Description |
|---|---|
| Permission Manager | Displays all macOS permissions the app has requested (Accessibility, Full Disk, Microphone, etc.) with status and revoke shortcuts. |
| Data Access Logs | Audit trail of which features accessed which files, directories, or system resources, stored locally. |
| Local Encryption Settings | Controls whether the app's data store and vault use AES-256 encryption, with key derivation options. |
| App Sandbox Controls | Restricts which third-party plugins can access the filesystem and system APIs. |
| Indexed Folder Controls | Explicit list of folders included in and excluded from the search index. |

---

### 8.3 Resource Controls

| Feature | Description |
|---|---|
| CPU Usage Limits | Cap the percentage of CPU the app's background processes may consume. |
| Memory Usage Caps | Set a maximum RSS limit; background features throttle if the cap is approached. |
| Indexing Throttling | Reduce indexing speed and I/O priority when the system is under load or on battery. |
| Background Activity Scheduling | Restrict intensive background tasks (re-indexing, analytics rollups) to defined time windows. |

---

### 8.4 Plugin System

| Feature | Description |
|---|---|
| Plugin Marketplace (Offline Install) | Install plugins from local `.plugin` packages or a local LAN registry — no internet required. |
| Plugin Permissions | Each plugin declares the permissions it requires; the user approves them explicitly on install. |
| Plugin Sandboxing | Plugins run in isolated processes with limited IPC surface; they cannot directly access app internals. |
| Custom Plugin SDK | A documented Swift/Python SDK for building plugins, including action types, trigger hooks, and UI extension points. |

---

## 9. Local Memory System (Non-AI)

A persistent, indexed knowledge base that remembers context, sessions, and relationships — no language model involved.

### 9.1 Persistent Memory

| Feature | Description |
|---|---|
| Saved Contexts | Named snapshots of the current app state, open documents, active workspace, and clipboard — restorable at any time. |
| Session Restoration | On next launch, restore the last active workspace, open windows, and in-progress workflows. |
| Recent Activity Memory | Timestamped log of recent commands, file opens, and app switches used to populate contextual suggestions. |
| Workflow Memory | Remembers which workflows were run in which contexts, improving the relevance of suggestions over time. |
| Project Memory | Associates files, notes, tasks, and browser bookmarks with a named project for unified retrieval. |

---

### 9.2 Indexed Knowledge

| Feature | Description |
|---|---|
| Local Keyword Indexing | Full-text index of notes, documents, and activity logs for instant keyword search. |
| Linked References | Bidirectional links between notes, tasks, and files; automatically surfaced when viewing related content. |
| Context Snapshots | Point-in-time captures of system state (open apps, clipboard, active file) stored alongside workflow runs. |
| Relationship Graphs | Visual graph of connections between notes, files, projects, and tasks. |
| Searchable History | Full-text search over the complete activity log, command history, and accessed-file history. |

---

### 9.3 Storage

| Feature | Description |
|---|---|
| SQLite Database | All structured data (tasks, notes, activity logs, preferences) stored in a local SQLite database. |
| Local Vector-Style Indexing | Non-LLM embedding-free relevance indexing using TF-IDF and BM25 for ranked search results. |
| AES-256 Encryption | The database and vault files are encrypted at rest using AES-256-GCM with a user-derived key. |
| Backup / Export Tools | One-click export of the entire data store to an encrypted archive; supports scheduled auto-backup to a local path. |
| Portable Vault Mode | Relocate the entire data store to a different drive or folder (e.g., an external SSD or iCloud Drive folder). |

---

## 10. Notes & Knowledge Management

A full-featured local note-taking and knowledge base system, deeply integrated with files, tasks, and search.

### 10.1 Note Taking

| Feature | Description |
|---|---|
| Markdown Editor | Syntax-highlighted Markdown editing with live preview pane and keyboard shortcuts matching common editors. |
| Rich Text Editor | WYSIWYG rich text alternative for users who prefer formatted prose without raw Markdown. |
| Split View Editing | Side-by-side Markdown source and rendered preview, resizable with a drag handle. |
| Wiki-Style Backlinks | `[[Note Title]]` syntax creates bidirectional links between notes; a backlinks panel shows all references. |
| Embedded Media | Drag images, PDFs, videos, and audio files directly into notes for inline display. |
| Code Blocks | Fenced code blocks with syntax highlighting for 100+ languages using a local highlight library. |

---

### 10.2 Organization

| Feature | Description |
|---|---|
| Tags | Attach searchable tags to notes; tags are normalized and shown in a tag browser sidebar panel. |
| Nested Folders | Hierarchical folder tree with unlimited depth for structural organization. |
| Smart Collections | Dynamic note collections based on saved queries (e.g., "all notes tagged #project-x modified this week"). |
| Daily Notes / Journal | Auto-creates a dated note for each day; supports a configurable template injected on creation. |
| Templates / Snippets | User-defined note templates inserted from the command palette or a `/template` trigger. |
| Pinned Notes | Pin frequently accessed notes to the top of any folder or the sidebar for quick access. |

---

### 10.3 Knowledge Features

| Feature | Description |
|---|---|
| OCR for PDFs / Images | Vision-framework OCR extracts text from attached images and PDFs, making them fully searchable. |
| Searchable Notes | All note content is indexed for instant full-text and fuzzy search across the entire knowledge base. |
| Graph View | Force-directed graph visualizing the link network between all notes in the knowledge base. |
| Linked References | Every note shows a panel of other notes that reference it, with excerpt context. |
| Reading Mode | Distraction-free rendered view with no editor chrome, optimised for reading long notes. |

---

### 10.4 Export & Backup

| Feature | Description |
|---|---|
| Markdown Export | Export individual notes or entire folders as `.md` files preserving frontmatter and link syntax. |
| PDF Export | Render notes to print-ready PDF with configurable page margins and header/footer templates. |
| Encrypted Backups | Export the full knowledge base as an AES-256-encrypted archive. |
| Version History | Per-note version history with diff view; restore any previous version with one click. |

---

## 11. Task & Time Management

A local-first task manager and productivity tracker with calendar support and deep work tools.

### 11.1 Tasks

| Feature | Description |
|---|---|
| To-Do Lists | Create and manage flat or grouped to-do lists with completion checkboxes. |
| Kanban Boards | Drag-and-drop Kanban view with customizable columns and swimlanes. |
| Subtasks | Tasks support unlimited nesting of subtasks with independent due dates and priorities. |
| Priorities | Four priority levels (urgent, high, normal, low) with visual indicators in all views. |
| Tags and Categories | Attach multiple tags and assign tasks to user-defined categories for cross-list filtering. |

---

### 11.2 Scheduling

| Feature | Description |
|---|---|
| Reminders | Local notifications at set times for any task; snooze support without network dependency. |
| Recurring Tasks | Daily, weekly, monthly, and custom recurrence patterns with end-date or occurrence-count termination. |
| Deadline Tracking | Visual overdue indicators and a "due soon" smart list surfacing tasks approaching their deadline. |
| Offline Calendar Support | Built-in monthly/weekly calendar view rendered from local task due dates, with no calendar service required. |
| ICS Calendar Integration | Import `.ics` files to display external calendar events alongside tasks in the calendar view. |

---

### 11.3 Productivity

| Feature | Description |
|---|---|
| Pomodoro Timer | Configurable work/break interval timer with a persistent menu bar indicator. |
| Focus Sessions | Timed deep-work sessions linked to a specific task; activates focus mode and suppresses notifications. |
| Deep Work Tracking | Logs cumulative focused time per day and visualizes streaks and patterns over time. |
| Goal Tracking | Define measurable goals with target values and track progress with a visual completion bar. |
| Habit Tracker | Daily habit checklist with streak counting and a calendar heatmap. |
| Daily Planning Dashboard | Morning dashboard combining today's tasks, habits, calendar events, and a focus intention field. |

---

### 11.4 Reporting

| Feature | Description |
|---|---|
| Productivity Analytics | Charts showing tasks completed vs. created per day/week, plus on-time completion rate. |
| Habit Streaks | Streak counters and a calendar heatmap for each tracked habit. |
| Weekly Reviews | Auto-generated weekly summary of completed tasks, time tracked, and habit adherence. |
| Time Reports | Breakdown of time logged across projects and task categories for any date range. |

---

## 12. Voice System (Offline Only)

Fully on-device speech recognition and synthesis — no audio ever leaves the machine.

### 12.1 Voice Recognition

| Feature | Description |
|---|---|
| Local Speech Recognition | Uses Apple's `SFSpeechRecognizer` with on-device model to transcribe voice without network access. |
| Wake Phrase Support | Always-on microphone listener for a configurable wake phrase to activate voice mode hands-free. |
| Voice Command Customization | User-defined command phrases mapped to any workflow, action, or script. |
| Dictation Mode | Continuous transcription mode that outputs text to the active input field or a new note. |

---

### 12.2 Voice Actions

| Action | Description |
|---|---|
| Launch Workflows | Speak a command phrase to trigger any saved automation workflow. |
| Open Applications | "Open [app name]" matches against installed apps and launches the best match. |
| Control Media | Voice control for play, pause, skip, volume, and track info. |
| Execute Commands | Any registered command palette action can be bound to a voice phrase. |
| Search Files | "Find [filename or keyword]" runs a file search and presents results in the overlay. |

---

### 12.3 Accessibility

| Feature | Description |
|---|---|
| Voice Navigation | Navigate the app's own UI by speaking element names and actions. |
| Text-to-Speech (Offline) | Uses macOS `AVSpeechSynthesizer` with offline voice packs to read out notifications, notes, or search results. |
| Audio Feedback | Configurable audio cues confirm command recognition, workflow completion, and error states. |

---

## 13. Security & Privacy

Security-first architecture: encryption at rest, biometric lock, zero network telemetry, and fully transparent permissions.

### 13.1 Security

| Feature | Description |
|---|---|
| AES-256 Encryption | All user data at rest is encrypted with AES-256-GCM; the key is derived from the user's password via Argon2. |
| App Lock / Password | Requires a password or biometric before the app UI becomes accessible after a configurable idle timeout. |
| Biometric Unlock | Touch ID (and Apple Watch unlock) supported via `LocalAuthentication` framework. |
| Secure Vault | A designated encrypted store for sensitive snippets, passwords, and credentials used in automations. |
| Encrypted Backups | All exported backup archives are AES-256 encrypted with a separate user-chosen passphrase. |

---

### 13.2 Privacy

| Feature | Description |
|---|---|
| No Telemetry | Zero analytics, crash reporting, or usage data is transmitted — no network calls are made by default. |
| No Tracking | The app does not identify, fingerprint, or track user behaviour in any form. |
| No Internet Requirement | Every feature functions fully without an internet connection. |
| Local-Only Processing | All indexing, OCR, speech recognition, and automation run entirely on-device. |
| Transparent Permission System | A dedicated permissions dashboard lists every macOS permission the app holds, why it needs it, and how to revoke it. |

---

## 14. Developer & Power User Features

Low-level hooks, CLI access, and advanced automation tools for technical users.

### 14.1 Developer Tools

| Feature | Description |
|---|---|
| Plugin SDK | Documented Swift and Python SDK for building first- and third-party plugins with defined action, trigger, and UI extension APIs. |
| Local API Hooks | A local Unix socket / HTTP API (localhost only) that exposes app actions for external tooling and scripts. |
| CLI Integration | A bundled CLI binary (`appctl`) that mirrors all command palette actions for scripting and terminal workflows. |
| Terminal Panel | An embedded terminal emulator (using `SwiftTerm`) for quick shell access without switching apps. |
| Workflow Debugger | Step-through execution of automation workflows with variable inspection and breakpoint support. |

---

### 14.2 Advanced Automation

| Feature | Description |
|---|---|
| Regex Triggers | Trigger workflows when clipboard content, a file path, or window title matches a regular expression. |
| Event Listeners | Subscribe to low-level system events (IOKit, NSDistributedNotificationCenter) as automation triggers. |
| File System Hooks | Fine-grained FSEvents monitoring beyond simple "file changed" — supports created, renamed, moved, and attribute-changed events. |
| Local Webhooks | The app can receive POST requests on a configurable localhost port to trigger workflows from other local processes. |
| Automation Logs | Persistent execution log for every workflow run: timestamp, trigger, actions taken, variables, outcome, and duration. |

---

### 14.3 Power User Utilities

| Feature | Description |
|---|---|
| Clipboard Manager | Persistent clipboard history with type-aware display (text, image, file, URL, color). |
| Clipboard History | Searchable log of all clipboard entries with preview, pinning, and one-click paste. |
| Macro Recorder | Record any sequence of keystrokes and clicks and replay them as a saved macro. |
| Keyboard Remapper | Remap any key or key combination to a different key, action, or script — scoped globally or per-app. |
| Batch Operations | Apply any file, app, or system action to multiple targets simultaneously from the command palette. |

---

*End of Feature Specification — v1.0*
