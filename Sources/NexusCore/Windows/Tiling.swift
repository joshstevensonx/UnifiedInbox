import Foundation

/// Window tiling layouts (feature spec §6.2). Pure geometry; the app applies frames via Accessibility.
public enum TileLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        }
    }

    /// Unit rectangle (x, y, w, h) in a top-left-origin space: y = 0 is the top of the screen.
    /// `.center` keeps the window's size, so it has no fixed unit rect.
    public var unitRect: (x: Double, y: Double, w: Double, h: Double)? {
        switch self {
        case .leftHalf: return (0, 0, 0.5, 1)
        case .rightHalf: return (0.5, 0, 0.5, 1)
        case .topHalf: return (0, 0, 1, 0.5)
        case .bottomHalf: return (0, 0.5, 1, 0.5)
        case .topLeft: return (0, 0, 0.5, 0.5)
        case .topRight: return (0.5, 0, 0.5, 0.5)
        case .bottomLeft: return (0, 0.5, 0.5, 0.5)
        case .bottomRight: return (0.5, 0.5, 0.5, 0.5)
        case .leftThird: return (0, 0, 1.0 / 3, 1)
        case .centerThird: return (1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return (2.0 / 3, 0, 1.0 / 3, 1)
        case .leftTwoThirds: return (0, 0, 2.0 / 3, 1)
        case .rightTwoThirds: return (1.0 / 3, 0, 2.0 / 3, 1)
        case .maximize: return (0, 0, 1, 1)
        case .almostMaximize: return (0.05, 0.05, 0.9, 0.9)
        case .center: return nil
        }
    }
}

/// A rectangle that is Codable on every platform (CGRect's Codable conformance differs on Linux).
public struct WindowRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
    public func intersectionArea(_ o: WindowRect) -> Double {
        let w = min(x + width, o.x + o.width) - max(x, o.x)
        let h = min(y + height, o.y + o.height) - max(y, o.y)
        return w > 0 && h > 0 ? w * h : 0
    }
}

public enum TilingGeometry {
    /// Target frame for `layout` inside `visible` (top-left origin, e.g. Accessibility coordinates),
    /// with `gap` points between windows and screen edges. Results are rounded to whole points.
    public static func frame(for layout: TileLayout, in visible: WindowRect, current: WindowRect, gap: Double = 0) -> WindowRect {
        guard let u = layout.unitRect else {
            let w = min(current.width, visible.width), h = min(current.height, visible.height)
            return WindowRect(x: (visible.x + (visible.width - w) / 2).rounded(),
                              y: (visible.y + (visible.height - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
        }
        let g = max(0, gap)
        let x0 = visible.x + visible.width * u.x, x1 = visible.x + visible.width * (u.x + u.w)
        let y0 = visible.y + visible.height * u.y, y1 = visible.y + visible.height * (u.y + u.h)
        // Full gap at screen edges, half gap between neighbouring tiles.
        let left = x0 + (u.x <= 0.0001 ? g : g / 2)
        let right = x1 - (u.x + u.w >= 0.9999 ? g : g / 2)
        let top = y0 + (u.y <= 0.0001 ? g : g / 2)
        let bottom = y1 - (u.y + u.h >= 0.9999 ? g : g / 2)
        return WindowRect(x: left.rounded(), y: top.rounded(), width: (right - left).rounded(), height: (bottom - top).rounded())
    }

    /// Converts a bottom-left-origin rect (AppKit / NSScreen) to top-left origin (Accessibility / CGWindow),
    /// given the height of the primary screen. The conversion is its own inverse.
    public static func flip(_ r: WindowRect, primaryHeight: Double) -> WindowRect {
        WindowRect(x: r.x, y: primaryHeight - r.y - r.height, width: r.width, height: r.height)
    }

    /// The screen (index) that holds most of `window`; falls back to the one containing its centre, then 0.
    public static func screenIndex(for window: WindowRect, screens: [WindowRect]) -> Int {
        guard !screens.isEmpty else { return 0 }
        let areas = screens.map { $0.intersectionArea(window) }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        return screens.firstIndex { $0.contains(x: window.midX, y: window.midY) } ?? 0
    }

    /// Repeating the same half-screen layout cycles widths 1/2 → 1/3 → 2/3 (like common tiling tools).
    public static func cycled(_ layout: TileLayout, previous: TileLayout?) -> TileLayout {
        switch (layout, previous) {
        case (.leftHalf, .leftHalf?): return .leftThird
        case (.leftHalf, .leftThird?): return .leftTwoThirds
        case (.rightHalf, .rightHalf?): return .rightThird
        case (.rightHalf, .rightThird?): return .rightTwoThirds
        default: return layout
        }
    }
}

// MARK: - Workspaces (spec §2.2): save and restore running apps + window frames

public struct SavedWindow: Codable, Equatable, Sendable {
    public var title: String
    public var frame: WindowRect
    public init(title: String, frame: WindowRect) { self.title = title; self.frame = frame }
}

public struct WorkspaceApp: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleId }
    public var bundleId: String
    public var name: String
    public var path: String?
    public var windows: [SavedWindow]
    public init(bundleId: String, name: String, path: String? = nil, windows: [SavedWindow] = []) {
        self.bundleId = bundleId; self.name = name; self.path = path; self.windows = windows
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var apps: [WorkspaceApp]
    /// Hide regular apps that aren't part of the workspace when switching to it.
    public var hideOthers: Bool
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, apps: [WorkspaceApp], hideOthers: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.apps = apps; self.hideOthers = hideOthers; self.createdAt = createdAt
    }

    public var windowCount: Int { apps.reduce(0) { $0 + $1.windows.count } }

    /// Pairs saved windows with an app's current windows: exact title matches first, then the rest in order.
    /// Returns (currentIndex, savedFrame) pairs.
    public static func match(saved: [SavedWindow], currentTitles: [String]) -> [(Int, WindowRect)] {
        var result: [(Int, WindowRect)] = []
        var usedCurrent = Set<Int>(), usedSaved = Set<Int>()
        for (si, s) in saved.enumerated() where !s.title.isEmpty {
            if let ci = currentTitles.indices.first(where: { !usedCurrent.contains($0) && currentTitles[$0] == s.title }) {
                result.append((ci, s.frame)); usedCurrent.insert(ci); usedSaved.insert(si)
            }
        }
        let freeCurrent = currentTitles.indices.filter { !usedCurrent.contains($0) }
        let freeSaved = saved.indices.filter { !usedSaved.contains($0) }
        for (ci, si) in zip(freeCurrent, freeSaved) { result.append((ci, saved[si].frame)) }
        return result.sorted { $0.0 < $1.0 }
    }
}

public struct WorkspaceConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var workspaces: [Workspace] = []
    /// Gap between tiled windows, in points.
    public var tileGap: Double = 0
    public init() {}
}
