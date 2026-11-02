import Foundation

// MARK: - Hotkey registry model (task 19). Carbon constants are mirrored here so this stays cross-platform.

public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    // Values match Carbon's cmdKey / shiftKey / optionKey / controlKey.
    public static let command = HotkeyModifiers(rawValue: 0x0100)
    public static let shift = HotkeyModifiers(rawValue: 0x0200)
    public static let option = HotkeyModifiers(rawValue: 0x0800)
    public static let control = HotkeyModifiers(rawValue: 0x1000)

    /// macOS order: ⌃⌥⇧⌘
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public init(keyCode: UInt32, modifiers: HotkeyModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }

    public var display: String { modifiers.symbols + KeyNames.name(for: keyCode) }

    /// A global hotkey needs ⌃, ⌥ or ⌘ (⇧ alone would steal normal typing), except function keys.
    public var isValidGlobal: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty || KeyNames.isFunctionKey(keyCode)
    }
}

public enum KeyNames {
    /// ANSI key codes (Carbon kVK_*) → label.
    static let table: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
        0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
        0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x2A: "\\", 0x32: "`",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
    ]

    public static func name(for keyCode: UInt32) -> String { table[keyCode] ?? "Key \(keyCode)" }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool { name(for: keyCode).hasPrefix("F") && name(for: keyCode).count > 1 }

    /// Key codes that are modifiers themselves (can't be the key of a combo).
    public static let modifierKeyCodes: Set<UInt32> = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x39, 0x3F]
}

public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var combo: KeyCombo?          // nil = no shortcut
    public var enabled: Bool
    public init(combo: KeyCombo?, enabled: Bool = true) { self.combo = combo; self.enabled = enabled }
}

/// User overrides on top of each action's default. Only changed actions are stored.
public struct HotkeyConfig: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var overrides: [String: HotkeyBinding] = [:]
    public init() {}

    public func binding(for id: String, default def: HotkeyBinding) -> HotkeyBinding { overrides[id] ?? def }

    public mutating func set(_ id: String, _ binding: HotkeyBinding, default def: HotkeyBinding) {
        overrides[id] = binding == def ? nil : binding
    }

    /// Action ids that share an enabled combo with another action.
    public static func conflicts(_ effective: [String: HotkeyBinding]) -> [KeyCombo: [String]] {
        var byCombo: [KeyCombo: [String]] = [:]
        for (id, b) in effective where b.enabled { if let c = b.combo { byCombo[c, default: []].append(id) } }
        return byCombo.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
    }
}
