# NEXUS --- Unified Native macOS Desktop Utility

**Product Requirements Document, Technical Specification and
Implementation Guide**\
Version 1.0 · Native macOS · Local-first · Swift / SwiftUI / AppKit

## 1. Executive summary

NEXUS combines four desktop utility experiences in one native macOS
application:

1.  **Launcher:** searchable application and folder launcher, pinned
    apps, groups, URLs and quick actions.
2.  **System Monitor:** CPU, memory, battery, network and storage
    metrics, process information, history and alerts.
3.  **Floating Widgets:** independent, movable and resizable desktop
    widgets for system metrics, clocks and quick information.
4.  **Ambient Desktop:** configurable clocks, visual themes, floating
    scenes and full-screen ambient mode.

A fifth layer, **Workspaces & Automation**, connects the experiences
through saved layouts, display assignments, triggers and actions.

**Product statement:** One native control centre for launching apps,
understanding your Mac and shaping your desktop.

### Product principles

-   Native first; use SwiftUI and AppKit.
-   Local first; no account or cloud backend required.
-   Lightweight; one shared monitoring engine serves all widgets.
-   Modular; users can enable features independently.
-   Respect macOS security and privacy boundaries.
-   Never display unavailable hardware metrics as zero.
-   Support keyboard navigation, VoiceOver and Reduce Motion.

## 2. Goals and non-goals

### Goals

-   Run as a menu-bar utility with a full dashboard.
-   Launch applications, folders, URLs and approved shortcuts.
-   Display reliable system metrics.
-   Create and manage floating widgets.
-   Provide ambient clocks and visual scenes.
-   Save and restore multi-display workspaces.
-   Support configurable alerts and simple automations.
-   Ship as a signed and notarised macOS application.

### Non-goals for MVP

-   Replacing or modifying the protected macOS Dock.
-   Replacing Mission Control, Spaces or Stage Manager.
-   Kernel extensions or privileged daemons.
-   Arbitrary shell-script execution.
-   Cloud sync, accounts or telemetry by default.
-   Windows or Linux support.
-   Promising temperature, fan or GPU readings where macOS does not
    expose them reliably.

## 3. Users and core journeys

Target users: Mac power users, developers, multi-display users and
people who value desktop customisation.

  ID      Journey
  ------- -------------------------------------------------------
  UC-01   Invoke launcher, search for an app and launch it
  UC-02   Reveal optional edge launcher and select a pinned app
  UC-03   Inspect CPU, memory, battery and network activity
  UC-04   Inspect processes and request normal termination
  UC-05   Add, move, resize and theme floating widgets
  UC-06   Save a Work or Development desktop workspace
  UC-07   Switch workspace manually or through a rule
  UC-08   Display an ambient clock on a selected screen

## 4. Information architecture

### Main navigation

  Section          Purpose
  ---------------- -----------------------------------------------
  Overview         System summary, alerts and active widgets
  Launcher         Apps, folders, groups, URLs and shortcuts
  System Monitor   Metrics, history and processes
  Widgets          Widget catalogue and configuration
  Ambient          Clocks, scenes, themes and display modes
  Workspaces       Saved layouts and display assignments
  Automation       Triggers, conditions and actions
  Settings         Appearance, monitoring, shortcuts and privacy

### Application surfaces

-   Main dashboard window.
-   Menu-bar popover.
-   Searchable launcher panel.
-   Independent floating widget windows.
-   Ambient / full-screen window.
-   Native macOS notifications for opted-in alerts.

Closing the dashboard must not unexpectedly stop the menu-bar utility or
its required services.

## 5. Functional requirements

Priority: **P0** MVP blocker; **P1** post-MVP; **P2** later enhancement.

### 5.1 App shell and lifecycle

  ID       Requirement                                    Priority
  -------- ---------------------------------------------- ----------
  APP-01   Native macOS application                       P0
  APP-02   Menu-bar status item and popover               P0
  APP-03   Open dashboard from menu bar                   P0
  APP-04   Supported launch-at-login option               P0
  APP-05   Restore selected surfaces and workspace        P0
  APP-06   Clean quit and observer/timer cleanup          P0
  APP-07   Handle sleep/wake and display changes          P0
  APP-08   Optional Dock presence / accessory behaviour   P1
  APP-09   Update mechanism                               P2

### 5.2 Launcher

-   Discover applications from standard application locations.
-   Add applications manually.
-   Search by name and launch with Return.
-   Pin/unpin apps and organise groups.
-   Sort manually, alphabetically or by recent use.
-   Add folders through a user-selected open panel.
-   Add URLs and approved system actions.
-   Optional recent and frequently used sections.
-   Configurable global shortcut.
-   Optional edge reveal and hot-corner reveal.
-   Optional auto-hide, orientation and screen placement.
-   Keyboard navigation and Escape-to-dismiss.
-   Handle moved or missing applications.
-   Use security-scoped bookmarks for persistent user-selected folder
    access.

**Constraint:** NEXUS is an independent launcher. It must not attempt to
modify the protected native Dock.

### 5.3 System monitoring

  ------------------------------------------------------------------------
  Metric                                         MVP Implementation notes
  --------------------- ---------------------------- ---------------------
  CPU total usage                                Yes Host statistics /
                                                     supported system
                                                     interfaces

  Memory used/free                               Yes VM statistics

  Memory pressure                                Yes Supported
                                                     memory-pressure APIs

  Battery                                        Yes IOKit / power-source
  percentage/state                                   interfaces

  Network throughput                             Yes Interface byte
                                                     counters and deltas

  Storage capacity                               Yes FileManager volume
                                                     resource values

  Uptime                                          P1 Supported system
                                                     source

  Process list                                    P1 Visibility and
                                                     permissions vary

  Audio devices                                   P1 Core Audio

  Display information                             P1 Core Graphics /
                                                     AppKit

  GPU utilisation                                 P2 Hardware and OS
                                                     dependent

  Temperature/fan speed                           P2 Limited public API
                                                     coverage
  ------------------------------------------------------------------------

Monitoring engine requirements: - One shared coordinator serves all
consumers. - Each metric includes value, unit, timestamp and
availability state. - Widgets subscribe to metric updates; they do not
poll independently. - Configurable sampling intervals with safe
defaults. - Mark stale or unsupported data explicitly. - Handle counter
resets, sleep/wake and interface changes. - Bound in-memory history and
avoid unbounded polling.

Suggested default sampling: CPU/memory/network every 2 seconds; battery
every 30 seconds; storage every 60 seconds; static hardware information
on launch and relevant system changes.

Network throughput formula:

`bytes_per_second = (current_bytes - previous_bytes) / elapsed_seconds`

Handle negative deltas, counter resets and interface changes.

### 5.4 Process manager (P1)

-   List process name, PID, CPU and memory where available.
-   Sort, search and filter.
-   Open associated application.
-   Request normal termination.
-   Force quit only with warning and confirmation.
-   Never automatically terminate system-critical processes.

### 5.5 Floating widget engine

MVP widgets: - CPU - Memory - Battery - Network - Clock

P1 widgets: - Storage - Top process - Audio - Calendar - Display
information

Widget controls: - Preset and custom sizes. - Drag, resize, duplicate,
hide and remove. - Theme, opacity, typography, background and corner
radius. - Display assignment and screen-edge snapping. - Always-on-top
option. - Hide on full-screen applications option. - Click-through
option where appropriate. - Edit mode and per-widget settings. - Persist
position and configuration.

Use AppKit window management (`NSPanel` / `NSWindow`) where necessary.
Validate window levels and collection behaviours across Spaces,
full-screen apps and macOS releases. Do not assume one configuration
works everywhere.

### 5.6 Ambient desktop

Clock types: - Digital, analogue, flip-style, minimal and world clock. -
Countdown clock (P1).

Original visual themes: - Glass, holographic, jelly-inspired, wireframe,
matrix-inspired, morphing gradient, retro and minimal.

Display modes: - Floating clock. - Windowed scene. - Full-screen ambient
scene. - Multi-display ambient mode. - Screensaver-style mode (P2;
investigate the correct macOS extension/distribution model).

Controls: - 12/24-hour format and date format. - Typography, colours,
animation speed and position. - Transparency and background effects. -
Night mode. - Reduce Motion support and static alternatives. - Pause
expensive animation when hidden. - Do not prevent display sleep unless
the user explicitly selects a supported mode.

### 5.7 Workspaces

A workspace stores: - Name and description. - Widget instances, settings
and positions. - Display assignments. - Launcher groups. - Ambient mode
and theme. - Visibility preferences. - Optional automation associations.

Operations: - Create, rename, duplicate, delete and activate. - Set
default workspace. - Preview layout. - Export/import configuration. -
Restore previous layout.

Display restore algorithm: 1. Match known display identifiers. 2. If
unavailable, compare display characteristics where reasonable. 3. Fall
back to the primary display. 4. Clamp window positions to visible
bounds. 5. Avoid stacking all widgets at one fallback point.

### 5.8 Automation (P1/P2)

Triggers: - Application launched/terminated (P1). - External display
connected/disconnected (P1). - Battery threshold (P1). - Time schedule
(P1). - Manual workspace activation (P1). - Network state changes (P2).

Actions: - Activate workspace. - Show/hide widget. - Show
notification. - Open application, folder or URL. - Activate ambient
theme. - Run a specifically selected Apple Shortcut.

Each rule stores name, enabled state, trigger, conditions, ordered
actions, cooldown, last execution and result. Explain actions before
enabling. Do not support arbitrary shell execution in MVP.

### 5.9 Menu bar

-   Compact CPU, memory, battery and network summary.
-   Open dashboard and launcher.
-   Show/hide widgets.
-   Select workspace.
-   Toggle ambient mode.
-   Pause monitoring.
-   Settings and Quit.
-   User-selectable indicators.

### 5.10 Alerts

MVP: CPU threshold, elevated memory pressure, low battery and low disk
space. Alerts must be opt-in, configurable, debounced, and delivered
through native notifications after permission is granted. Avoid repeated
alerts for one continuous condition.

## 6. UI / UX specification

### Visual direction

Dark glass / minimalist, with native macOS interaction patterns: - Clear
hierarchy and compact information density. - Subtle translucency rather
than excessive blur. - Restrained accent colour. - Strong contrast for
metric values. - Motion communicates state rather than serving as
decoration.

### Main window

-   Persistent sidebar.
-   Resizable content area.
-   Restore last window size and position.
-   Standard macOS focus and keyboard behaviour.
-   Minimum useful window dimensions.

### Overview page

1.  Mac identity: model, chip and macOS version.
2.  CPU, memory, battery and network cards.
3.  Performance chart.
4.  Active widgets.
5.  Current workspace.
6.  Alerts and recent events.
7.  Quick actions.

### Launcher page

Search, pinned apps, groups, folders, URLs, shortcuts, recent apps and
edit/reorder mode.

### System Monitor page

Tabs for Overview, CPU, Memory, Network, Battery, Storage, Processes and
Hardware. Charts must show units, timestamps, selected time range and
missing-data states.

### Widget gallery

Search, category filters, preview, Add action, active instances and
per-widget settings.

### Ambient page

Scene gallery, live preview, clock style, theme, display selector and
animation controls.

### Workspace page

Workspace cards, layout preview, create/duplicate/rename/delete,
activate, display assignment and import/export.

### Accessibility

VoiceOver labels, full keyboard navigation, sufficient contrast, Reduce
Motion support, no colour-only status indicators and appropriate text
scaling.

## 7. Technical architecture

### Recommended stack

  Layer                 Technology
  --------------------- -----------------------------------------------
  Language              Swift
  Main UI               SwiftUI
  Windowing/lifecycle   AppKit
  Charts                Swift Charts
  Animation             SwiftUI / Core Animation
  Advanced graphics     Metal only when justified
  CPU/memory            Supported host and VM statistics
  Battery               IOKit / power-source interfaces
  Network               Network framework and interface counters
  Storage               FileManager
  Audio                 Core Audio
  Display               Core Graphics / AppKit
  Persistence           SwiftData or SQLite
  Preferences           UserDefaults
  Notifications         UserNotifications
  Login launch          ServiceManagement
  Shortcuts             App Intents / supported Shortcuts integration

Choose the minimum macOS deployment target after confirming API needs
and intended user base.

### Architecture layers

``` text
NEXUS
├── Presentation
│   ├── Dashboard
│   ├── MenuBarPopover
│   ├── Launcher
│   ├── WidgetWindows
│   ├── Ambient
│   └── Settings
├── ApplicationServices
│   ├── WorkspaceService
│   ├── WidgetRegistry
│   ├── LauncherService
│   ├── AutomationEngine
│   ├── AlertService
│   └── ThemeService
├── SystemData
│   ├── CPUProvider
│   ├── MemoryProvider
│   ├── BatteryProvider
│   ├── NetworkProvider
│   ├── StorageProvider
│   ├── ProcessProvider
│   ├── AudioProvider
│   └── DisplayProvider
├── Persistence
│   ├── WorkspaceRepository
│   ├── WidgetRepository
│   ├── LauncherRepository
│   └── MetricsHistoryRepository
└── macOSIntegration
    ├── AppKit
    ├── IOKit
    ├── CoreGraphics
    ├── CoreAudio
    ├── Network
    ├── UserNotifications
    └── ServiceManagement
```

Architecture rules: - Dependency injection for services. - Protocols for
metric providers. - Keep sampling outside SwiftUI views. - Publish
immutable metric snapshots. - Use an actor or serialised component for
shared sampling state. - Publish UI state on the main actor. - Keep
persistence behind repositories. - Isolate OS-version-specific code. -
Cancel subscriptions when widgets are removed. - Bound history in
memory.

## 8. Suggested project structure

``` text
NEXUS/
├── README.md
├── CHANGELOG.md
├── NEXUS.xcodeproj
├── Sources/
│   ├── App/
│   ├── Core/
│   │   ├── Models/
│   │   ├── Protocols/
│   │   └── Utilities/
│   ├── Features/
│   │   ├── Overview/
│   │   ├── Launcher/
│   │   ├── SystemMonitor/
│   │   ├── ProcessManager/
│   │   ├── Widgets/
│   │   ├── Ambient/
│   │   ├── Workspaces/
│   │   ├── Automation/
│   │   └── Settings/
│   ├── Services/
│   │   ├── Monitoring/
│   │   ├── Windowing/
│   │   ├── Workspace/
│   │   ├── Notifications/
│   │   └── Persistence/
│   ├── Platform/
│   ├── DesignSystem/
│   └── Resources/
├── Tests/
│   ├── UnitTests/
│   ├── IntegrationTests/
│   └── UITests/
├── Documentation/
└── Scripts/
```

## 9. Data model

Use SwiftData for a straightforward native MVP or SQLite when explicit
migration/query control is preferred. Select one primary persistence
system.

### Workspace

  Field                   Type
  ----------------------- -----------------
  id                      UUID
  name                    String
  description             Optional String
  isDefault               Bool
  createdAt / updatedAt   Date
  configurationVersion    Int

### WidgetInstance

  Field                   Type
  ----------------------- -----------------
  id                      UUID
  workspaceId             UUID
  widgetType              String
  displayIdentifier       Optional String
  positionX / positionY   Double
  width / height          Double
  zOrder                  Int
  isVisible               Bool
  configurationJSON       String

### LauncherItem

  Field          Type
  -------------- -------------------------------
  id             UUID
  groupId        Optional UUID
  itemType       app / folder / URL / shortcut
  title          String
  target         String
  bookmarkData   Optional Data
  sortOrder      Int
  isPinned       Bool

### LauncherGroup

`id: UUID`, `name: String`, `sortOrder: Int`,
`iconName: Optional String`.

### AutomationRule

`id`, `name`, `isEnabled`, versioned `triggerJSON`, `conditionsJSON`,
`actionsJSON`, `cooldownSeconds`, `lastExecutedAt`, `lastResult`.

### MetricSample

`id`, `metricKey`, `value`, `unit`, `timestamp`, optional `source`.

Bound metric retention. MVP can use an in-memory ring buffer and persist
history only when the user enables it.

Example widget configuration:

``` json
{
  "schemaVersion": 1,
  "widgetType": "cpu",
  "appearance": {
    "theme": "glass",
    "opacity": 0.82,
    "cornerRadius": 16
  },
  "display": {
    "mode": "compact",
    "showHistory": true
  },
  "refreshIntervalSeconds": 2
}
```

Every exported configuration must include a schema version. Validate
imports, migrate explicitly and preserve unknown widget types as
unavailable rather than silently deleting them.

## 10. Permissions, security and privacy

Request permissions only when a user enables a feature that needs them.
Explain the reason before triggering a macOS prompt.

Potential capabilities: - Notifications. - Login-item registration. -
User-selected folder access through security-scoped bookmarks. -
Shortcuts / automation permissions where required. - Accessibility only
if a specific feature genuinely needs it. - Do not request Screen
Recording for MVP without a real requirement.

Privacy requirements: - No account required. - No analytics by
default. - No transmission of process names, file paths or metric
history. - Local configuration and history. - Online integrations
separately enabled and disclosed. - Data export and reset.

Security requirements: - Validate imported workspace files. - Never
execute code from imported configuration. - Do not store secrets in
plain-text preferences. - Avoid privileged helpers in MVP. - Sign and
notarise releases.

## 11. API feasibility and limitations

  -----------------------------------------------------------------------
  Capability                          Feasibility
  ----------------------------------- -----------------------------------
  CPU usage                           Good

  Memory statistics                   Good

  Battery state                       Good

  Network throughput                  Good

  Disk capacity                       Good

  Process list                        Partial; visibility and permissions
                                      vary

  GPU utilisation                     Hardware and OS dependent

  Temperature                         Limited; no universal public API
                                      for all Macs

  Fan speed                           Limited; hardware dependent

  Native Dock modification            Not supported; do not build around
                                      it

  Global hotkeys                      Feasible; validate implementation
                                      and permission implications

  Edge hover detection                Feasible with caveats; test across
                                      displays and full-screen apps

  Arbitrary window control            Restricted; respect
                                      privacy/accessibility boundaries
  -----------------------------------------------------------------------

Use public, supported APIs for core features. Unavailable metrics must
have a clear unavailable state.

## 12. Performance and energy

-   One shared monitoring coordinator.
-   Widgets subscribe only to needed metrics.
-   Different sampling intervals per metric.
-   Pause or reduce animation when hidden.
-   Reduce sampling when idle.
-   Avoid independent timers per widget.
-   Downsample long chart ranges.
-   Profile with Instruments.
-   Test Apple Silicon and Intel only if both are in scope.

Suggested targets to validate: - Idle CPU below 1% on a representative
supported Mac. - Idle memory below 150 MB for MVP. - Responsive UI with
no sampling work on the main thread. - No network requests unless an
online feature is explicitly enabled.

## 13. Testing and QA

### Unit tests

-   CPU usage calculation.
-   Network throughput calculation.
-   Stale and unavailable metric states.
-   Threshold evaluation and debouncing.
-   Workspace serialization.
-   Configuration migration.
-   Display fallback.
-   Launcher sorting/search.
-   Automation cooldown.

### Integration tests

-   Monitoring coordinator/providers.
-   Persistence repositories.
-   Widget registration and lifecycle.
-   Window restoration.
-   Notifications.
-   Workspace activation.
-   Import/export validation.

### UI tests

-   Open/close dashboard.
-   Open launcher and launch app.
-   Add/remove/move/resize widget.
-   Change theme.
-   Create and activate workspace.
-   Configure and trigger alert.
-   Restore after relaunch.

### Manual test matrix

-   Single display and multiple displays.
-   Different display resolutions.
-   Display disconnect/reconnect while running.
-   Full-screen apps and multiple Spaces.
-   Sleep/wake.
-   Battery/power transitions.
-   Network interface changes.
-   Launch at login.
-   Reduce Motion and VoiceOver.
-   Every supported macOS version.

Acceptance checklist: - \[ \] Menu-bar item remains responsive. - \[ \]
Closing dashboard does not unexpectedly quit app. - \[ \] Launcher
keyboard navigation works. - \[ \] Metrics show units and timestamps. -
\[ \] Unsupported metrics are not shown as zero. - \[ \] Widgets move,
resize and restore. - \[ \] Display changes do not strand widgets
off-screen. - \[ \] Ambient mode exits reliably. - \[ \] Workspace
save/restore works. - \[ \] Alerts are opt-in and debounced. - \[ \]
Quit cleans up observers, timers and windows. - \[ \] No unexpected
network activity. - \[ \] Release is signed and notarised.

## 14. Development roadmap

### Phase 0 --- Technical validation

-   Confirm minimum macOS version and hardware scope.
-   Create Xcode project.
-   Validate CPU, memory, battery and network providers.
-   Prototype menu-bar lifecycle.
-   Prototype floating windows across Spaces and displays.
-   Measure idle resource usage.

**Exit:** API feasibility and window behaviour are validated.

### Phase 1 --- MVP foundation

-   App shell, sidebar and menu-bar popover.
-   Shared monitoring coordinator.
-   CPU, memory, battery and network.
-   Launcher catalogue, search and pinning.
-   Clock and metric widgets.
-   Theme settings and local persistence.

**Exit:** Core user journeys work end-to-end.

### Phase 2 --- Desktop experience

-   Widget gallery and window manager.
-   Drag, resize and snap.
-   Multi-display restoration.
-   Ambient clock themes.
-   Workspaces and import/export.

### Phase 3 --- Advanced monitoring

-   Process manager.
-   Storage, audio and display information.
-   Historical charts and threshold alerts.
-   Optional CSV export.

### Phase 4 --- Automation

-   Rule editor, triggers, conditions and actions.
-   Execution history.
-   Shortcuts integration.

### Phase 5 --- Release

-   Accessibility review.
-   Performance and energy profiling.
-   Compatibility testing.
-   Signing, notarisation and DMG packaging.
-   Release notes and support documentation.

## 15. MVP scope lock

The first release includes only: 1. Native SwiftUI app shell. 2.
Menu-bar utility and popover. 3. Searchable application launcher with
pinned apps. 4. CPU, memory, battery and network monitoring. 5. Shared
monitoring coordinator. 6. CPU, memory, battery, network and clock
widgets. 7. Floating windows with move and resize. 8. Dark/light
appearance and one glass-style theme. 9. Basic workspace save and
switching. 10. Local persistence and relaunch restoration.

Defer GPU, temperature, fan speed, advanced 3D scenes, process
termination, complex automation and cloud sync.

## 16. Codex implementation instructions

### Operating rules

-   Build a real native macOS application in Swift/SwiftUI/AppKit.
-   Do not create an Electron or web substitute.
-   Do not add a backend, account system or analytics.
-   Do not use private macOS APIs.
-   Do not claim support for unavailable metrics.
-   Implement in phases; keep the project buildable after each
    milestone.
-   Add tests alongside core services.
-   Use realistic sample data only in previews and UI tests, never as
    live readings.
-   Document permissions and OS limitations.

### Implementation sequence

1.  Inspect repository, Xcode version, deployment target and build
    tools.
2.  Confirm macOS target and hardware scope.
3.  Create project and app lifecycle.
4.  Implement menu-bar entry and dashboard shell.
5.  Define metric models and provider protocols.
6.  Implement and test CPU and memory providers.
7.  Add battery and network providers.
8.  Build shared monitoring coordinator.
9.  Connect dashboard to real metrics.
10. Build launcher catalogue, search and pinning.
11. Build widget registry and clock widget.
12. Add CPU, memory, battery and network widgets.
13. Implement AppKit floating window manager.
14. Add persistence and restoration.
15. Add themes and workspace model.
16. Profile, test and package.

### Definition of done

A feature is complete when it handles loading, empty, unavailable and
error states; persists required configuration; handles cancellation and
lifecycle changes; has appropriate tests; is keyboard/accessibility
usable; avoids unbounded polling or memory growth; and is documented.

### Initial Codex prompt

> You are implementing NEXUS, a native macOS desktop utility using
> Swift, SwiftUI and AppKit. Treat this specification as the source of
> truth.
>
> First inspect the repository, Xcode version, deployment target and
> build tools. Do not overwrite existing work without understanding it.
>
> Implement only the MVP foundation: native app shell, menu-bar entry
> point, dashboard, shared system-monitoring architecture, real CPU and
> memory metrics, battery and network metrics where supported,
> searchable app launcher with pinning, and a basic floating widget
> engine with clock and metric widgets.
>
> Use supported macOS APIs only. Keep sampling outside SwiftUI views.
> Use one shared monitoring coordinator. Model unsupported metrics
> explicitly as unavailable. Never present mock values as live data.
>
> Keep the project buildable at every step. Add unit tests for
> calculations, persistence and state transitions. Handle sleep/wake,
> app lifecycle and display changes. Use local persistence. Do not add
> cloud services, analytics or accounts.
>
> Before each module, provide a concise plan and identify API
> limitations. After implementation, build the app, run relevant tests,
> fix errors and report exact files changed, build/test results,
> limitations and the next recommended task.
>
> Do not implement later-phase features until the MVP foundation is
> working and verified.

## 17. Risks and open decisions

  -----------------------------------------------------------------------
  Risk / decision                     Mitigation
  ----------------------------------- -----------------------------------
  Hardware metrics differ by Mac      Capability-based providers and
                                      unavailable states

  Floating windows vary across Spaces AppKit prototype and manual QA

  Global hotkeys need careful         Validate early
  implementation                      

  Edge detection conflicts with       Optional and configurable
  gestures                            

  Many widgets increase energy use    Shared sampling and
                                      visibility-aware rendering

  Displays disconnect                 Reconciliation and fallback
                                      algorithm

  3D scenes affect performance        Defer and profile

  Process termination is disruptive   Normal termination first; confirm
                                      force quit

  macOS APIs change                   Isolate providers and test OS
                                      versions

  Scope expands                       Enforce MVP scope lock
  -----------------------------------------------------------------------

Confirm before implementation: - Minimum supported macOS version. -
Apple Silicon only or Apple Silicon plus Intel. - Native Dock remains
available (recommended: yes). - Edge launcher default (recommended:
optional). - Metric history (recommended: bounded local history). - Free
personal-use or commercial distribution.

## 18. Final product definition

NEXUS is a native, local-first macOS utility suite with a menu-bar
control centre, searchable launcher, shared system-monitoring engine,
floating desktop widgets, ambient clocks and saved workspaces.

Its differentiator is the unified system: one configuration model, one
monitoring engine, one widget framework and one desktop experience.

**Recommended strategy:** validate macOS APIs and window behaviour
first, ship a reliable MVP, then expand into workspaces, advanced
monitoring and automation.
