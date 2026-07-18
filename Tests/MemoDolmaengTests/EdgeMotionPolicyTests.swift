import XCTest
@testable import MemoDolmaeng

final class EdgeMotionPolicyTests: XCTestCase {
    func testCollapsedMemoSurfaceDoesNotLayOutExpandedEditor() {
        XCTAssertFalse(
            EdgeMemoPanelLayoutPolicy.showsExpandedBody(
                in: CGSize(width: 100, height: EdgeLayoutEngine.sideHandleHeight)
            )
        )
        XCTAssertFalse(
            EdgeMemoPanelLayoutPolicy.showsExpandedBody(
                in: CGSize(width: MemoPanelSize.minimum.width, height: 75)
            )
        )
        XCTAssertTrue(
            EdgeMemoPanelLayoutPolicy.showsExpandedBody(
                in: EdgeMemoPanelLayoutPolicy.minimumExpandedBodySize
            )
        )
        XCTAssertEqual(EdgeMemoPanelLayoutPolicy.bodyRevealProgress(expansionProgress: 0.42), 0)
        XCTAssertEqual(EdgeMemoPanelLayoutPolicy.bodyRevealProgress(expansionProgress: 1), 1)
    }

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
