import XCTest
@testable import MemoDolmaeng

final class EdgePreferencesTests: XCTestCase {
    func testLegacyTopDefaultMigratesToRightSide() throws {
        let suiteName = "MemoDolmaengEdgePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(EdgeDock.top.rawValue, forKey: "edge.defaultDock")

        let preferences = EdgePreferences(defaults: defaults)

        XCTAssertEqual(preferences.defaultEdge, .right)
        XCTAssertEqual(defaults.string(forKey: "edge.defaultDock"), EdgeDock.right.rawValue)
    }

}
