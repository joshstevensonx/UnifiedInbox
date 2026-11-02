import Foundation
import XCTest
@testable import NexusCore

final class HotCornerTests: XCTestCase {
    let screens = [WindowRect(x: 0, y: 0, width: 1440, height: 900), WindowRect(x: 1440, y: 0, width: 1920, height: 1080)]

    func testCornerDetection() {
        XCTAssertEqual(HotCornerDetector.corner(at: 0, 899, screens: screens, tolerance: 4), .topLeft)
        XCTAssertEqual(HotCornerDetector.corner(at: 1439, 0, screens: screens, tolerance: 4), .bottomRight)
        XCTAssertEqual(HotCornerDetector.corner(at: 3359, 1079, screens: screens, tolerance: 4), .topRight)   // second screen
        XCTAssertEqual(HotCornerDetector.corner(at: 1442, 2, screens: screens, tolerance: 4), .bottomLeft)
        XCTAssertNil(HotCornerDetector.corner(at: 700, 450, screens: screens, tolerance: 4))
        XCTAssertNil(HotCornerDetector.corner(at: 0, 450, screens: screens, tolerance: 4))   // edge, not corner
    }

    func testDwellFiresOncePerVisit() {
        var d = HotCornerDetector(corner: .topLeft, dwell: 0.3)
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(d.update(x: 0, y: 899, screens: screens, now: t))
        XCTAssertFalse(d.update(x: 1, y: 898, screens: screens, now: t + 0.2))
        XCTAssertTrue(d.update(x: 0, y: 899, screens: screens, now: t + 0.31))
        XCTAssertFalse(d.update(x: 0, y: 899, screens: screens, now: t + 2))       // still there: no repeat
        XCTAssertFalse(d.update(x: 500, y: 500, screens: screens, now: t + 3))     // leave
        XCTAssertFalse(d.update(x: 0, y: 899, screens: screens, now: t + 4))
        XCTAssertTrue(d.update(x: 0, y: 899, screens: screens, now: t + 4.4))
        var off = HotCornerDetector(corner: .off, dwell: 0)
        XCTAssertFalse(off.update(x: 0, y: 899, screens: screens, now: t))
    }

    func testAppearanceHelpers() {
        XCTAssertEqual(AccentPalette.rgb("#FF8000")?.r, 1)
        XCTAssertEqual(AccentPalette.rgb("FF8000")?.g ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(AccentPalette.rgb("#XYZ"))
        XCTAssertTrue(UIDensity.compact.spacing < UIDensity.spacious.spacing)
        XCTAssertNotNil(AccentPalette.colors.first.flatMap { AccentPalette.rgb($0.hex) })
    }
}
