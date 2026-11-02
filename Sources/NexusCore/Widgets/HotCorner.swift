import Foundation

// MARK: - Hot corner (task 24): park the pointer in a screen corner to open the launcher.

public enum ScreenCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

public struct HotCornerDetector: Sendable {
    public var corner: ScreenCorner
    /// Distance from the corner (points) that still counts.
    public var tolerance: Double
    /// How long the pointer must stay before firing.
    public var dwell: TimeInterval
    private var enteredAt: Date?
    private var fired = false

    public init(corner: ScreenCorner = .off, tolerance: Double = 4, dwell: TimeInterval = 0.35) {
        self.corner = corner; self.tolerance = tolerance; self.dwell = dwell
    }

    /// Which corner of which screen `point` is in. Screens are bottom-left-origin frames (AppKit), so
    /// "top" is the frame's max y. Returns nil when not in any corner.
    public static func corner(at x: Double, _ y: Double, screens: [WindowRect], tolerance: Double) -> ScreenCorner? {
        for s in screens where x >= s.x - 1 && x <= s.x + s.width + 1 && y >= s.y - 1 && y <= s.y + s.height + 1 {
            let left = x <= s.x + tolerance, right = x >= s.x + s.width - 1 - tolerance
            let bottom = y <= s.y + tolerance, top = y >= s.y + s.height - 1 - tolerance
            switch (left, right, top, bottom) {
            case (true, _, true, _): return .topLeft
            case (_, true, true, _): return .topRight
            case (true, _, _, true): return .bottomLeft
            case (_, true, _, true): return .bottomRight
            default: continue
            }
        }
        return nil
    }

    /// Feed pointer samples. Returns true once per visit, after the pointer has stayed for `dwell`.
    public mutating func update(x: Double, y: Double, screens: [WindowRect], now: Date) -> Bool {
        guard corner != .off, Self.corner(at: x, y, screens: screens, tolerance: tolerance) == corner else {
            enteredAt = nil; fired = false
            return false
        }
        let start = enteredAt ?? now
        enteredAt = start
        guard !fired, now.timeIntervalSince(start) >= dwell else { return false }
        fired = true
        return true
    }
}

// MARK: - Appearance (density + accent)

public enum UIDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, comfortable, spacious
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Multiplier for row padding.
    public var spacing: Double {
        switch self {
        case .compact: return 0.55
        case .comfortable: return 1
        case .spacious: return 1.4
        }
    }
    /// Points added to list text size.
    public var fontDelta: Double {
        switch self {
        case .compact: return -1
        case .comfortable: return 0
        case .spacious: return 1
        }
    }
}

public enum AccentPalette {
    /// Name → hex. The first is the original glass blue.
    public static let colors: [(name: String, hex: String)] = [
        ("Glass blue", "#8CB3FF"), ("Mint", "#7BD8B0"), ("Amber", "#FFC56B"), ("Coral", "#FF8A80"),
        ("Lilac", "#C792EA"), ("Teal", "#5FD7D7"), ("Graphite", "#B8C0CC"),
    ]

    /// Parses "#RRGGBB" (or without #) into 0…1 components.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
