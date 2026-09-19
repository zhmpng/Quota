import XCTest
import QuotaCore
@testable import QuotaApp

final class IslandSettingsTests: XCTestCase {
    @MainActor func testChoiceSurvivesRestartAndProviderReplacement() throws {
        let suite = "quota.island.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // No display or live application reads: these tests cannot create an overlay.
        let island = DynamicIslandController(defaults: defaults, environment: { .init(running: [.claude], geometry: nil) })
        XCTAssertNil(island.selectedProvider)
        island.setEnabled(true, for: .claude)
        XCTAssertEqual(island.selectedProvider, .claude)
        island.setEnabled(true, for: .openai)
        XCTAssertEqual(island.selectedProvider, .openai)
        XCTAssertEqual(island.runningProviders, [.claude])
        let restored = DynamicIslandController(defaults: defaults, environment: { .init(running: [], geometry: nil) })
        XCTAssertEqual(restored.selectedProvider, .openai)
        restored.setEnabled(false, for: .claude)
        XCTAssertEqual(restored.selectedProvider, .openai)
        restored.setEnabled(false, for: .openai)
        XCTAssertNil(defaults.string(forKey: IslandPolicy.preferenceKey))
    }
    @MainActor func testInvalidSavedValueNeverOptsIn() throws {
        let suite = "quota.island.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("all", forKey: IslandPolicy.preferenceKey)
        let island = DynamicIslandController(defaults: defaults, environment: { .init(running: [.claude, .openai], geometry: nil) })
        XCTAssertNil(island.selectedProvider)
        island.refreshEnvironment()
        XCTAssertFalse(island.hasSupportedDisplay)
        XCTAssertNil(island.selectedProvider)
    }
}
