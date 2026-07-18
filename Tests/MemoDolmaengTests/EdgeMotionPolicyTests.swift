import XCTest
@testable import MemoDolmaeng

final class EdgeMotionPolicyTests: XCTestCase {
    func testReduceMotionRemovesGeometryAndCapsFeedbackFade() {
        let policy = EdgeMotionPolicy(
            reduceMotion: true,
            increaseContrast: false,
            reduceTransparency: false
        )

        XCTAssertFalse(policy.animatesGeometry)
        XCTAssertEqual(policy.geometryDuration(0.22), 0)
        XCTAssertEqual(policy.fadeDuration(0.16), 0.08)
        XCTAssertEqual(policy.fadeDuration(0.05), 0.05)
    }

    func testRegularMotionKeepsDeclaredDurations() {
        let policy = EdgeMotionPolicy(
            reduceMotion: false,
            increaseContrast: true,
            reduceTransparency: true
        )

        XCTAssertTrue(policy.animatesGeometry)
        XCTAssertEqual(policy.geometryDuration(0.22), 0.22)
        XCTAssertEqual(policy.fadeDuration(0.16), 0.16)
    }
}
