import XCTest
@testable import MemoDolmaeng

final class EdgePreferencesTests: XCTestCase {
    func testHideDelayMigratesToFiveSecondsOnceAndThenPreservesUserChoice() throws {
        let suiteName = "MemoDolmaengEdgePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.35, forKey: "edge.hideDelay")

        let migrated = EdgePreferences(defaults: defaults)
        XCTAssertEqual(migrated.hideDelay, 5, accuracy: 0.001)

        migrated.hideDelay = 3.5
        let reloaded = EdgePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.hideDelay, 3.5, accuracy: 0.001)
    }
}
