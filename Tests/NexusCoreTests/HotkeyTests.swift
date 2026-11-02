import Foundation
import XCTest
@testable import NexusCore

final class HotkeyTests: XCTestCase {
    func testDisplay() {
        XCTAssertEqual(KeyCombo(keyCode: 0x31, modifiers: [.control, .option]).display, "⌃⌥Space")
        XCTAssertEqual(KeyCombo(keyCode: 0x09, modifiers: [.command, .shift, .option, .control]).display, "⌃⌥⇧⌘V")
        XCTAssertEqual(KeyCombo(keyCode: 0x7B, modifiers: [.option]).display, "⌥←")
        XCTAssertEqual(KeyNames.name(for: 0xFF), "Key 255")
    }

    func testValidity() {
        XCTAssertTrue(KeyCombo(keyCode: 0x31, modifiers: [.option]).isValidGlobal)
        XCTAssertFalse(KeyCombo(keyCode: 0x00, modifiers: [.shift]).isValidGlobal)
        XCTAssertFalse(KeyCombo(keyCode: 0x00, modifiers: []).isValidGlobal)
        XCTAssertTrue(KeyCombo(keyCode: 0x60, modifiers: []).isValidGlobal)   // F5
    }

    func testOverridesAndConflicts() throws {
        let def = HotkeyBinding(combo: KeyCombo(keyCode: 0x31, modifiers: [.option]))
        var cfg = HotkeyConfig()
        XCTAssertEqual(cfg.binding(for: "launcher", default: def), def)
        let custom = HotkeyBinding(combo: KeyCombo(keyCode: 0x28, modifiers: [.command, .option]))
        cfg.set("launcher", custom, default: def)
        XCTAssertEqual(cfg.binding(for: "launcher", default: def), custom)
        cfg.set("launcher", def, default: def)                       // back to default: not stored
        XCTAssertTrue(cfg.overrides.isEmpty)

        let same = KeyCombo(keyCode: 0x31, modifiers: [.option])
        let conflicts = HotkeyConfig.conflicts([
            "a": HotkeyBinding(combo: same), "b": HotkeyBinding(combo: same),
            "c": HotkeyBinding(combo: same, enabled: false), "d": HotkeyBinding(combo: nil),
        ])
        XCTAssertEqual(conflicts, [same: ["a", "b"]])
        cfg.set("x", HotkeyBinding(combo: nil, enabled: false), default: def)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyConfig.self, from: JSONEncoder().encode(cfg)), cfg)
    }
}
