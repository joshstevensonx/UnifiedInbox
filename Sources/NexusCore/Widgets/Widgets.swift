import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, memory, battery, network, storage, clock, inbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .network: return "Network"
        case .storage: return "Storage"
        case .clock: return "Clock"
        case .inbox: return "Inbox"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .battery: return "battery.75percent"
        case .network: return "arrow.up.arrow.down"
        case .storage: return "internaldrive"
        case .clock: return "clock"
        case .inbox: return "tray"
        }
    }

    public var summary: String {
        switch self {
        case .cpu: return "Total CPU load with a live history line"
        case .memory: return "Memory used and pressure"
        case .battery: return "Charge, power source and time remaining"
        case .network: return "Download and upload speed"
        case .storage: return "Free space on the startup disk"
        case .clock: return "Minimal time and date"
        case .inbox: return "Unread messages by app"
        }
    }

    public var defaultSize: CGSize {
        switch self {
        case .clock: return CGSize(width: 220, height: 110)
        case .network: return CGSize(width: 220, height: 130)
        case .inbox: return CGSize(width: 220, height: 150)
        default: return CGSize(width: 180, height: 130)
        }
    }

    public static let minimumSize = CGSize(width: 140, height: 90)
}

public struct WidgetAppearance: Codable, Equatable, Sendable {
    public var opacity: Double
    public var cornerRadius: Double
    public var showHistory: Bool
    public init(opacity: Double = 0.85, cornerRadius: Double = 16, showHistory: Bool = true) {
        self.opacity = opacity; self.cornerRadius = cornerRadius; self.showHistory = showHistory
    }
}

public struct WidgetInstance: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: WidgetKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Matches NSScreen's CGDirectDisplayID when known.
    public var displayID: UInt32?
    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var appearance: WidgetAppearance

    public init(id: UUID = UUID(), kind: WidgetKind, frame: CGRect, displayID: UInt32? = nil,
                isVisible: Bool = true, alwaysOnTop: Bool = false, appearance: WidgetAppearance = .init()) {
        self.id = id; self.kind = kind
        x = frame.origin.x; y = frame.origin.y; width = frame.width; height = frame.height
        self.displayID = displayID; self.isVisible = isVisible; self.alwaysOnTop = alwaysOnTop
        self.appearance = appearance
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.width; height = newValue.height }
    }
}

public struct WidgetConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var widgets: [WidgetInstance]
    public init(widgets: [WidgetInstance] = []) { schemaVersion = Self.currentSchema; self.widgets = widgets }
}

/// A screen as seen by the layout engine (decoupled from NSScreen for testing).
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var visibleFrame: CGRect
    public var isPrimary: Bool
    public init(id: UInt32, visibleFrame: CGRect, isPrimary: Bool) {
        self.id = id; self.visibleFrame = visibleFrame; self.isPrimary = isPrimary
    }
}

public enum WidgetLayout {
    /// Spec §5.7 restore algorithm: known display → otherwise the display the frame overlaps most →
    /// otherwise primary; then clamp inside its visible bounds.
    public static func restore(_ w: WidgetInstance, displays: [DisplayInfo]) -> (frame: CGRect, displayID: UInt32?) {
        guard !displays.isEmpty else { return (w.frame, w.displayID) }
        let target = displays.first { $0.id == w.displayID }
            ?? displays.max { overlap(w.frame, $0.visibleFrame) < overlap(w.frame, $1.visibleFrame) }
                .flatMap { overlap(w.frame, $0.visibleFrame) > 0 ? $0 : nil }
            ?? displays.first { $0.isPrimary }
            ?? displays[0]
        return (clamp(w.frame, to: target.visibleFrame), target.id)
    }

    /// Keeps the whole widget visible, shrinking it only if it's larger than the screen.
    public static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(max(f.width, WidgetKind.minimumSize.width), bounds.width)
        f.size.height = min(max(f.height, WidgetKind.minimumSize.height), bounds.height)
        f.origin.x = min(max(f.minX, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.minY, bounds.minY), bounds.maxY - f.height)
        return f
    }

    /// Where to place a new widget: cascade from the top-right so widgets don't stack on one point.
    public static func placement(for kind: WidgetKind, existing: [CGRect], in bounds: CGRect) -> CGRect {
        let size = kind.defaultSize
        let margin: CGFloat = 24, step: CGFloat = 28
        var origin = CGPoint(x: bounds.maxX - size.width - margin, y: bounds.maxY - size.height - margin)
        var tries = 0
        while existing.contains(where: { abs($0.minX - origin.x) < 8 && abs($0.minY - origin.y) < 8 }) && tries < 20 {
            origin.x -= step; origin.y -= step; tries += 1
        }
        return clamp(CGRect(origin: origin, size: size), to: bounds)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
