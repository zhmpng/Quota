import XCTest
@testable import QuotaCore

final class IslandPolicyTests: XCTestCase {
    func testOnlyDesktopAppsActivateTheirProvider() {
        XCTAssertEqual(IslandPolicy.provider(forBundleIdentifier: "com.openai.codex"), .openai)
        XCTAssertEqual(IslandPolicy.provider(forBundleIdentifier: "com.openai.chat"), .openai)
        XCTAssertEqual(IslandPolicy.provider(forBundleIdentifier: "com.anthropic.claudefordesktop"), .claude)
        for id in [nil, "com.openai.codex.helper", "com.anthropic.claudefordesktop.helper", "local.atlas.launcher", "com.apple.Safari"] {
            XCTAssertNil(IslandPolicy.provider(forBundleIdentifier: id))
        }
        XCTAssertNil(IslandPolicy.provider(forBundleIdentifier: "com.openai.codex", isTerminated: true))
    }
    func testOptInAndExclusiveSelection() {
        let running: Set<Provider> = [.claude, .openai]
        XCTAssertFalse(IslandPolicy.isVisible(selected: nil, running: running, hasDisplay: true))
        let claude = IslandPolicy.selection(current: nil, changing: .claude, enabled: true)
        XCTAssertEqual(claude, .claude)
        let openai = IslandPolicy.selection(current: claude, changing: .openai, enabled: true)
        XCTAssertEqual(openai, .openai)
        XCTAssertEqual(IslandPolicy.selection(current: openai, changing: .claude, enabled: false), .openai)
        XCTAssertNil(IslandPolicy.selection(current: openai, changing: .openai, enabled: false))
    }
    func testWaitingDoesNotFallBackToAnotherRunningProvider() {
        XCTAssertFalse(IslandPolicy.isVisible(selected: .claude, running: [.openai], hasDisplay: true))
        XCTAssertTrue(IslandPolicy.isVisible(selected: .claude, running: [.openai, .claude], hasDisplay: true))
        XCTAssertFalse(IslandPolicy.isVisible(selected: .claude, running: [.openai, .claude], hasDisplay: false))
        XCTAssertFalse(IslandPolicy.isVisible(selected: .claude, running: [.claude], hasDisplay: true, suspended: true))
    }
    func testGeometryReservesCameraAndKeepsTopEdgeOn14And16InchLayouts() throws {
        for size in [CGSize(width: 1512, height: 982), CGSize(width: 1728, height: 1117)] {
            let screen = CGRect(origin: .zero, size: size)
            let left = CGRect(x: 0, y: size.height - 37, width: (size.width - 184) / 2, height: 37)
            let right = CGRect(x: left.maxX + 184, y: left.minY, width: left.width, height: 37)
            let geometry = try XCTUnwrap(IslandGeometry(screenFrame: screen, safeAreaTop: 37, leftArea: left, rightArea: right, isBuiltIn: true))
            XCTAssertEqual(geometry.notchWidth, 184)
            XCTAssertEqual(geometry.collapsedSize.width, 296)
            for expanded in [false, true] {
                let frame = geometry.frame(expanded: expanded)
                XCTAssertEqual(frame.maxY, screen.maxY)
                XCTAssertEqual(frame.midX, screen.midX)
                XCTAssertGreaterThanOrEqual((frame.width - geometry.notchWidth) / 2, 56)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }
    func testScreenCoordinatesCanBeNegativeOrAboveAnotherDisplay() throws {
        let screen = CGRect(x: -1728, y: 1080, width: 1728, height: 1117)
        let left = CGRect(x: -1728, y: 2160, width: 772, height: 37)
        let right = CGRect(x: -772, y: 2160, width: 772, height: 37)
        let geometry = try XCTUnwrap(IslandGeometry(screenFrame: screen, safeAreaTop: 37, leftArea: left, rightArea: right, isBuiltIn: true))
        XCTAssertEqual(geometry.frame(expanded: true).midX, -864)
        XCTAssertEqual(geometry.frame(expanded: true).maxY, 2197)
    }
    func testExternalOrUnnotchedScreensNeverGetSyntheticIsland() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 945, width: 664, height: 37)
        let right = CGRect(x: 848, y: 945, width: 664, height: 37)
        XCTAssertNil(IslandGeometry(screenFrame: screen, safeAreaTop: 37, leftArea: left, rightArea: right, isBuiltIn: false))
        XCTAssertNil(IslandGeometry(screenFrame: screen, safeAreaTop: 0, leftArea: left, rightArea: right, isBuiltIn: true))
        XCTAssertNil(IslandGeometry(screenFrame: screen, safeAreaTop: 37, leftArea: nil, rightArea: nil, isBuiltIn: true))
        XCTAssertNil(IslandGeometry(screenFrame: screen, safeAreaTop: 37, leftArea: right, rightArea: left, isBuiltIn: true))
    }
}
