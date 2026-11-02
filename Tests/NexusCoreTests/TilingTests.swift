import Foundation
import XCTest
@testable import NexusCore

final class TilingTests: XCTestCase {
    let screen = WindowRect(x: 0, y: 25, width: 1440, height: 875)   // below a 25 pt menu bar
    let win = WindowRect(x: 100, y: 100, width: 800, height: 600)

    func testHalvesQuartersThirds() {
        XCTAssertEqual(TilingGeometry.frame(for: .leftHalf, in: screen, current: win), WindowRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(TilingGeometry.frame(for: .rightHalf, in: screen, current: win), WindowRect(x: 720, y: 25, width: 720, height: 875))
        XCTAssertEqual(TilingGeometry.frame(for: .bottomRight, in: screen, current: win).y, 463) // 25 + 437.5 rounded
        XCTAssertEqual(TilingGeometry.frame(for: .centerThird, in: screen, current: win), WindowRect(x: 480, y: 25, width: 480, height: 875))
        XCTAssertEqual(TilingGeometry.frame(for: .maximize, in: screen, current: win), screen)
    }

    func testCenterKeepsSizeAndClamps() {
        let c = TilingGeometry.frame(for: .center, in: screen, current: win)
        XCTAssertEqual(c, WindowRect(x: 320, y: 163, width: 800, height: 600))
        let huge = WindowRect(x: 0, y: 0, width: 3000, height: 2000)
        XCTAssertEqual(TilingGeometry.frame(for: .center, in: screen, current: huge), screen)
    }

    func testGaps() {
        let l = TilingGeometry.frame(for: .leftHalf, in: screen, current: win, gap: 10)
        let r = TilingGeometry.frame(for: .rightHalf, in: screen, current: win, gap: 10)
        XCTAssertEqual(l, WindowRect(x: 10, y: 35, width: 705, height: 855))
        XCTAssertEqual(r.x - (l.x + l.width), 10)  // one full gap between neighbours
        XCTAssertEqual(r.x + r.width, 1430)
    }

    func testFlipAndScreenSelection() {
        let appKit = WindowRect(x: 0, y: 0, width: 1440, height: 875)    // bottom-left origin
        XCTAssertEqual(TilingGeometry.flip(appKit, primaryHeight: 900), WindowRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(TilingGeometry.flip(TilingGeometry.flip(win, primaryHeight: 900), primaryHeight: 900), win)
        let second = WindowRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(TilingGeometry.screenIndex(for: WindowRect(x: 1400, y: 100, width: 500, height: 400), screens: [screen, second]), 1)
        XCTAssertEqual(TilingGeometry.screenIndex(for: WindowRect(x: -9000, y: 0, width: 10, height: 10), screens: [screen, second]), 0)
    }

    func testCycling() {
        XCTAssertEqual(TilingGeometry.cycled(.leftHalf, previous: nil), .leftHalf)
        XCTAssertEqual(TilingGeometry.cycled(.leftHalf, previous: .leftHalf), .leftThird)
        XCTAssertEqual(TilingGeometry.cycled(.leftHalf, previous: .leftThird), .leftTwoThirds)
        XCTAssertEqual(TilingGeometry.cycled(.leftHalf, previous: .leftTwoThirds), .leftHalf)
        XCTAssertEqual(TilingGeometry.cycled(.rightHalf, previous: .rightHalf), .rightThird)
    }

    func testWorkspaceWindowMatching() {
        let a = WindowRect(x: 0, y: 0, width: 1, height: 1), b = WindowRect(x: 2, y: 2, width: 1, height: 1)
        let c = WindowRect(x: 3, y: 3, width: 1, height: 1)
        let saved = [SavedWindow(title: "Inbox", frame: a), SavedWindow(title: "Draft", frame: b), SavedWindow(title: "", frame: c)]
        let m = Workspace.match(saved: saved, currentTitles: ["Other", "Inbox"])
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].0, 0); XCTAssertEqual(m[0].1, b)   // leftover saved goes to leftover window in order
        XCTAssertEqual(m[1].0, 1); XCTAssertEqual(m[1].1, a)   // title match
        XCTAssertTrue(Workspace.match(saved: saved, currentTitles: []).isEmpty)
    }

    func testWorkspaceCodable() throws {
        var cfg = WorkspaceConfig()
        cfg.workspaces = [Workspace(name: "Coding", apps: [WorkspaceApp(bundleId: "com.apple.Terminal", name: "Terminal",
                                                                         windows: [SavedWindow(title: "zsh", frame: win)])])]
        let back = try JSONDecoder().decode(WorkspaceConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(back.workspaces[0].windowCount, 1)
    }
}
