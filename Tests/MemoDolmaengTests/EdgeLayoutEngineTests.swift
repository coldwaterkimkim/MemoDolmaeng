import CoreGraphics
import XCTest
@testable import MemoDolmaeng

final class EdgeLayoutEngineTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 50, width: 1_200, height: 800)
    private let visible = CGRect(x: 100, y: 50, width: 1_200, height: 770)

    func testDefaultGroupIsPackedOnRightInStoredOrder() {
        let group = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5)
        let notes = [
            note(title: "첫째", groupID: group.id, order: 0),
            note(title: "둘째", groupID: group.id, order: 1),
            note(title: "셋째", groupID: group.id, order: 2)
        ]

        let snapshot = EdgeLayoutEngine.layout(
            notes: notes,
            groups: [group],
            defaultGroupID: group.id,
            screenFrame: screen,
            visibleFrame: visible
        )
        let frames = notes.compactMap { snapshot.handleFrames[$0.id] }

        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { abs($0.maxX - screen.maxX) < 0.001 })
        XCTAssertTrue(frames.allSatisfy { $0.height == EdgeLayoutEngine.sideHandleHeight })
        XCTAssertTrue(frames.allSatisfy { $0.width > $0.height })
        XCTAssertEqual(frames[0].minY, frames[1].maxY, accuracy: 0.001)
        XCTAssertEqual(frames[1].minY, frames[2].maxY, accuracy: 0.001)
        XCTAssertEqual(snapshot.groupFrames[group.id]?.maxY ?? 0, visible.maxY, accuracy: 0.001)
    }

    func testLauncherTrayFollowsCursorAndShowsSameOrderOnBothSides() throws {
        let group = MemoEdgeGroup(edge: .top, normalizedCenter: 0.5)
        let notes = [
            note(title: "첫째", groupID: group.id, order: 0),
            note(title: "둘째", groupID: group.id, order: 1),
            note(title: "셋째", groupID: group.id, order: 2)
        ]
        let anchorY: CGFloat = 360
        let left = EdgeLayoutEngine.launcherLayout(
            notes: notes,
            edge: .left,
            anchorY: anchorY,
            screenFrame: screen,
            visibleFrame: visible
        )
        let right = EdgeLayoutEngine.launcherLayout(
            notes: notes,
            edge: .right,
            anchorY: anchorY,
            screenFrame: screen,
            visibleFrame: visible
        )

        let leftFrames = try notes.map { try XCTUnwrap(left.handleFrames[$0.id]) }
        let rightFrames = try notes.map { try XCTUnwrap(right.handleFrames[$0.id]) }
        XCTAssertEqual(leftFrames.map(\.midY), rightFrames.map(\.midY))
        XCTAssertTrue(leftFrames.allSatisfy { $0.minX == screen.minX })
        XCTAssertTrue(rightFrames.allSatisfy { $0.maxX == screen.maxX })
        let union = leftFrames.dropFirst().reduce(leftFrames[0]) { $0.union($1) }
        XCTAssertEqual(union.midY, anchorY, accuracy: 0.001)
        XCTAssertGreaterThan(leftFrames[0].midY, leftFrames[1].midY)
        XCTAssertGreaterThan(leftFrames[1].midY, leftFrames[2].midY)
    }

    func testSideHandleExpandsForFullDisplayTitle() throws {
        let group = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5)
        let memo = note(title: "메모돌멩 수정사항", groupID: group.id, order: 0)
        let snapshot = EdgeLayoutEngine.layout(
            notes: [memo],
            groups: [group],
            defaultGroupID: group.id,
            screenFrame: screen,
            visibleFrame: visible
        )
        let frame = try XCTUnwrap(snapshot.handleFrames[memo.id])

        XCTAssertGreaterThan(frame.width, 120)
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.height, EdgeLayoutEngine.sideHandleHeight, accuracy: 0.001)
    }

    func testLegacyGroupsOnOneEdgeCollapseIntoOneTopAnchoredRail() {
        let manual = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5, createdAt: Date(timeIntervalSince1970: 1))
        let defaultGroup = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5, createdAt: Date(timeIntervalSince1970: 2))
        let manualNote = note(title: "수동", groupID: manual.id, order: 0)
        let defaultNote = note(title: "기본", groupID: defaultGroup.id, order: 0)

        let snapshot = EdgeLayoutEngine.layout(
            notes: [manualNote, defaultNote],
            groups: [defaultGroup, manual],
            defaultGroupID: defaultGroup.id,
            screenFrame: screen,
            visibleFrame: visible
        )
        let manualFrame = try! XCTUnwrap(snapshot.groupFrames[manual.id])
        let defaultFrame = try! XCTUnwrap(snapshot.groupFrames[defaultGroup.id])

        XCTAssertEqual(manualFrame, defaultFrame)
        XCTAssertEqual(manualFrame.maxY, visible.maxY, accuracy: 0.001)
    }

    func testTopHandlesSitImmediatelyBelowMenuBarAndPanelOpensDown() throws {
        let group = MemoEdgeGroup(edge: .top, normalizedCenter: 0.5)
        let memo = note(title: "상단메모", groupID: group.id, order: 0)
        let snapshot = EdgeLayoutEngine.layout(
            notes: [memo],
            groups: [group],
            defaultGroupID: UUID(),
            screenFrame: screen,
            visibleFrame: visible
        )
        let handle = try XCTUnwrap(snapshot.handleFrames[memo.id])
        let panel = EdgeLayoutEngine.panelFrame(
            adjacentTo: handle,
            screenFrame: screen,
            visibleFrame: visible,
            edge: .top,
            aspectRatio: 1
        )

        XCTAssertEqual(handle.maxY, visible.maxY, accuracy: 0.001)
        XCTAssertEqual(handle.height, 26, accuracy: 0.001)
        XCTAssertEqual(panel.maxY, handle.maxY, accuracy: 0.001)
        XCTAssertLessThan(panel.minY, handle.minY)
        XCTAssertLessThanOrEqual(panel.minX, handle.midX)
        XCTAssertGreaterThanOrEqual(panel.maxX, handle.midX)
    }

    func testEdgeCreationControlsStayOnTheirPhysicalEdges() {
        let rightHandles = [
            CGRect(x: screen.maxX - 90, y: 420, width: 90, height: 26),
            CGRect(x: screen.maxX - 110, y: 394, width: 110, height: 26)
        ]
        let right = EdgeLayoutEngine.edgeControlFrame(
            edge: .right,
            handleFrames: rightHandles,
            screenFrame: screen,
            visibleFrame: visible
        )
        XCTAssertEqual(right.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(right.maxY, rightHandles.last!.minY - EdgeLayoutEngine.groupGap, accuracy: 0.001)

        let topHandles = [CGRect(x: 500, y: visible.maxY - 26, width: 100, height: 26)]
        let top = EdgeLayoutEngine.edgeControlFrame(
            edge: .top,
            handleFrames: topHandles,
            screenFrame: screen,
            visibleFrame: visible
        )
        XCTAssertEqual(top.minX, topHandles[0].maxX + EdgeLayoutEngine.groupGap, accuracy: 0.001)
        XCTAssertEqual(top.maxY, visible.maxY, accuracy: 0.001)
    }

    func testDeleteDropTargetIsCenteredAboveVisibleScreenBottom() {
        let target = EdgeLayoutEngine.deleteDropFrame(visibleFrame: visible)
        XCTAssertEqual(target.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(target.minY, visible.minY + 18, accuracy: 0.001)
        XCTAssertTrue(visible.contains(target))
    }

    func testSidePanelsAttachToPhysicalEdges() throws {
        for edge in [EdgeDock.left, .right] {
            let group = MemoEdgeGroup(edge: edge, normalizedCenter: 0.5)
            let memo = note(title: edge.title, groupID: group.id, order: 0)
            let snapshot = EdgeLayoutEngine.layout(
                notes: [memo],
                groups: [group],
                defaultGroupID: group.id,
                screenFrame: screen,
                visibleFrame: visible
            )
            let handle = try XCTUnwrap(snapshot.handleFrames[memo.id])
            let panel = EdgeLayoutEngine.panelFrame(
                adjacentTo: handle,
                screenFrame: screen,
                visibleFrame: visible,
                edge: edge,
                aspectRatio: 0.75
            )
            if edge == .left {
                XCTAssertEqual(handle.minX, screen.minX, accuracy: 0.001)
                XCTAssertEqual(panel.minX, screen.minX, accuracy: 0.001)
            } else {
                XCTAssertEqual(handle.maxX, screen.maxX, accuracy: 0.001)
                XCTAssertEqual(panel.maxX, screen.maxX, accuracy: 0.001)
            }
            XCTAssertLessThan(panel.minY, handle.minY)
            XCTAssertGreaterThanOrEqual(panel.minY, visible.minY)
            XCTAssertLessThanOrEqual(panel.maxY, visible.maxY)
        }
    }

    func testPanelUsesStoredSizeAndKeepsItsDockedEdge() {
        let handle = CGRect(x: screen.maxX - 100, y: 430, width: 100, height: 26)
        let storedSize = MemoPanelSize(width: 512, height: 388)
        let panel = EdgeLayoutEngine.panelFrame(
            adjacentTo: handle,
            screenFrame: screen,
            visibleFrame: visible,
            edge: .right,
            aspectRatio: MemoAspectRatio.square.value,
            panelSize: storedSize
        )

        XCTAssertEqual(panel.size.width, 512, accuracy: 0.001)
        XCTAssertEqual(panel.size.height, 388, accuracy: 0.001)
        XCTAssertEqual(panel.maxX, screen.maxX, accuracy: 0.001)
    }

    func testPanelExpansionKeepsTheIndexOuterEdgeAndGrowsDownward() {
        let cases: [(EdgeDock, CGRect)] = [
            (.left, CGRect(x: screen.minX, y: 500, width: 96, height: 26)),
            (.right, CGRect(x: screen.maxX - 96, y: 500, width: 96, height: 26)),
            (.top, CGRect(x: 600, y: visible.maxY - 26, width: 100, height: 26))
        ]

        for (edge, handle) in cases {
            let panel = EdgeLayoutEngine.panelFrame(
                adjacentTo: handle,
                screenFrame: screen,
                visibleFrame: visible,
                edge: edge,
                aspectRatio: 1,
                panelSize: MemoPanelSize(width: 340, height: 340)
            )

            if edge == .left {
                XCTAssertEqual(panel.minX, handle.minX, accuracy: 0.001)
            } else if edge == .right {
                XCTAssertEqual(panel.maxX, handle.maxX, accuracy: 0.001)
            } else {
                XCTAssertEqual(panel.maxY, handle.maxY, accuracy: 0.001)
            }
            XCTAssertEqual(panel.maxY, handle.maxY, accuracy: 0.001)
            XCTAssertLessThan(panel.minY, handle.minY)
            XCTAssertEqual(panel.size, CGSize(width: 340, height: 340))
        }
    }

    func testStoredPanelSizeIsClampedToPhysicalWidthAndSpaceBelowItsTitle() {
        let tinyVisible = CGRect(x: 0, y: 0, width: 260, height: 210)
        let tinyScreen = CGRect(x: 0, y: 0, width: 340, height: 210)
        let handle = CGRect(x: 0, y: 100, width: 80, height: 26)
        let panel = EdgeLayoutEngine.panelFrame(
            adjacentTo: handle,
            screenFrame: tinyScreen,
            visibleFrame: tinyVisible,
            edge: .left,
            aspectRatio: MemoAspectRatio.portrait.value,
            panelSize: MemoPanelSize(width: 720, height: 900)
        )

        XCTAssertEqual(panel.width, tinyScreen.width, accuracy: 0.001)
        XCTAssertEqual(panel.height, handle.maxY - tinyVisible.minY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(panel.minY, tinyVisible.minY)
        XCTAssertLessThanOrEqual(panel.maxY, tinyVisible.maxY)
    }

    func testExpandedTitleBarContainsItsOriginalIndexAcrossEdgesAndSizes() {
        let sideYValues = [visible.minY + 14, visible.midY, visible.maxY - 26]
        let sideWidths: [CGFloat] = [64, 320]
        let panelWidths: [CGFloat] = [280, 720]

        for edge in [EdgeDock.left, .right] {
            for y in sideYValues {
                for handleWidth in sideWidths {
                    for panelWidth in panelWidths {
                        let handleX = edge == .right ? screen.maxX - handleWidth : screen.minX
                        let handle = CGRect(x: handleX, y: y, width: handleWidth, height: 26)
                        let panel = EdgeLayoutEngine.panelFrame(
                            adjacentTo: handle,
                            screenFrame: screen,
                            visibleFrame: visible,
                            edge: edge,
                            aspectRatio: 1,
                            panelSize: MemoPanelSize(width: panelWidth, height: 340)
                        )
                        let titleBar = EdgeLayoutEngine.panelTitleBarFrame(in: panel)

                        XCTAssertTrue(
                            titleBar.contains(handle),
                            "\(edge) title bar \(titleBar) must contain index \(handle)"
                        )
                    }
                }
            }
        }

        for handleWidth in sideWidths {
            let handle = CGRect(
                x: visible.maxX - handleWidth,
                y: visible.maxY - 26,
                width: handleWidth,
                height: 26
            )
            let panel = EdgeLayoutEngine.panelFrame(
                adjacentTo: handle,
                screenFrame: screen,
                visibleFrame: visible,
                edge: .top,
                aspectRatio: 1,
                panelSize: MemoPanelSize(width: 280, height: 340)
            )
            XCTAssertTrue(EdgeLayoutEngine.panelTitleBarFrame(in: panel).contains(handle))
        }
    }

    func testHiddenFramesMoveOutwardFromEachEdge() {
        let frame = CGRect(x: 100, y: 200, width: 80, height: 26)
        XCTAssertLessThan(
            EdgeLayoutEngine.hiddenHandleFrame(for: frame, edge: .left).minX,
            frame.minX
        )
        XCTAssertGreaterThan(
            EdgeLayoutEngine.hiddenHandleFrame(for: frame, edge: .right).minX,
            frame.minX
        )
        XCTAssertGreaterThanOrEqual(
            EdgeLayoutEngine.hiddenHandleFrame(for: frame, edge: .top).minY,
            frame.maxY
        )

        let panel = CGRect(x: 300, y: 150, width: 340, height: 340)
        XCTAssertGreaterThan(
            EdgeLayoutEngine.collapsedPanelFrame(
                for: panel,
                edge: .right,
                screenFrame: screen,
                visibleFrame: visible
            ).minX,
            screen.maxX
        )
        XCTAssertLessThan(
            EdgeLayoutEngine.collapsedPanelFrame(
                for: panel,
                edge: .left,
                screenFrame: screen,
                visibleFrame: visible
            ).maxX,
            screen.minX
        )
    }

    func testOnlySideEdgesHaveInteractiveHotZonesAndDropTargets() {
        let topHotZone = EdgeLayoutEngine.hotZoneFrame(
            edge: .top,
            thickness: 2,
            screenFrame: screen,
            visibleFrame: visible
        )
        XCTAssertEqual(topHotZone, .zero)

        XCTAssertEqual(
            EdgeLayoutEngine.dock(
                at: CGPoint(x: screen.maxX - 2, y: visible.midY),
                screenFrame: screen,
                visibleFrame: visible
            ),
            .right
        )
        XCTAssertNil(
            EdgeLayoutEngine.dock(
                at: CGPoint(x: screen.midX, y: screen.maxY - 1),
                screenFrame: screen,
                visibleFrame: visible
            )
        )
        XCTAssertNil(
            EdgeLayoutEngine.dock(
                at: CGPoint(x: screen.midX, y: visible.maxY - 1),
                screenFrame: screen,
                visibleFrame: visible
            )
        )
        XCTAssertEqual(
            EdgeLayoutEngine.normalizedCenter(
                at: CGPoint(x: visible.midX, y: visible.midY),
                edge: .top,
                visibleFrame: visible
            ),
            0.5,
            accuracy: 0.001
        )
    }

    func testTenLegacyGroupsBecomeOneCompactNonOverlappingRailOnSmallScreen() {
        let notesAndGroups = (0..<10).map { index -> (MemoNote, MemoEdgeGroup) in
            let timestamp = Date(timeIntervalSince1970: Double(index))
            let group = MemoEdgeGroup(
                edge: .right,
                normalizedCenter: 0.5,
                createdAt: timestamp
            )
            return (
                note(
                    title: "여섯글자\(index)",
                    groupID: group.id,
                    order: 0,
                    createdAt: timestamp
                ),
                group
            )
        }
        let defaultGroup = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5)
        let smallScreen = CGRect(x: 0, y: 0, width: 900, height: 620)
        let smallVisibleFrame = CGRect(x: 0, y: 20, width: 900, height: 600)
        let snapshot = EdgeLayoutEngine.layout(
            notes: notesAndGroups.map(\.0),
            groups: notesAndGroups.map(\.1) + [defaultGroup],
            defaultGroupID: defaultGroup.id,
            screenFrame: smallScreen,
            visibleFrame: smallVisibleFrame
        )

        let frames = notesAndGroups.compactMap { snapshot.handleFrames[$0.0.id] }
            .sorted { $0.minY < $1.minY }
        XCTAssertEqual(frames.count, 10)
        XCTAssertGreaterThanOrEqual(frames.first?.minY ?? 0, smallVisibleFrame.minY)
        XCTAssertLessThanOrEqual(frames.last?.maxY ?? .infinity, smallVisibleFrame.maxY)
        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.minY - pair.0.maxY, -0.01)
        }
    }

    func testOneAndTwoIceLanesKeepFixedHeightAndUncontestedClickPositions() throws {
        let first = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 320)
        let second = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 700)
        let fixedHeight = EdgeLayoutEngine.fixedIcePanelHeight(visibleFrame: visible)

        let one = EdgeLayoutEngine.iceLaneFrames(
            edge: .left,
            items: [first],
            screenFrame: screen,
            visibleFrame: visible
        )
        let two = EdgeLayoutEngine.iceLaneFrames(
            edge: .left,
            items: [first, second],
            screenFrame: screen,
            visibleFrame: visible
        )

        XCTAssertEqual(try XCTUnwrap(one[first.id]).height, fixedHeight, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(two[first.id]).height, fixedHeight, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(two[second.id]).height, fixedHeight, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(one[first.id]).maxY, 320, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(two[first.id]).maxY, 320, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(two[second.id]).maxY, 700, accuracy: 0.001)
    }

    func testOverlappingSecondIceKeepsNewClickAndMovesOlderOnItsExistingSide() throws {
        let older = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 500)
        let newest = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 480)
        let frames = EdgeLayoutEngine.iceLaneFrames(
            edge: .right,
            items: [older, newest],
            screenFrame: screen,
            visibleFrame: visible
        )

        let olderFrame = try XCTUnwrap(frames[older.id])
        let newestFrame = try XCTUnwrap(frames[newest.id])
        XCTAssertEqual(newestFrame.maxY, 480, accuracy: 0.001)
        XCTAssertEqual(olderFrame.minY, newestFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(olderFrame.height, newestFrame.height, accuracy: 0.001)
    }

    func testNewIceMovesOnlyWhenOlderMemoHasNoRoomOnItsExistingSide() throws {
        let older = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 320)
        let newest = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 370)
        let frames = EdgeLayoutEngine.iceLaneFrames(
            edge: .right,
            items: [older, newest],
            screenFrame: screen,
            visibleFrame: visible
        )

        let olderFrame = try XCTUnwrap(frames[older.id])
        let newestFrame = try XCTUnwrap(frames[newest.id])
        XCTAssertEqual(olderFrame.maxY, 320, accuracy: 0.001)
        XCTAssertEqual(newestFrame.minY, olderFrame.maxY, accuracy: 0.001)
        XCTAssertNotEqual(newestFrame.maxY, 370, accuracy: 0.001)
    }

    func testThreeIceLanesAloneUseThreeZonesAndNewestTakesNearestZone() throws {
        let oldest = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 760)
        let middle = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 180)
        let newest = EdgeIceLaneLayoutItem(id: UUID(), preferredTopY: 480)
        let frames = EdgeLayoutEngine.iceLaneFrames(
            edge: .left,
            items: [oldest, middle, newest],
            screenFrame: screen,
            visibleFrame: visible
        )
        let sorted = frames.values.sorted { $0.minY < $1.minY }
        let fixedHeight = EdgeLayoutEngine.fixedIcePanelHeight(visibleFrame: visible)

        XCTAssertEqual(sorted.count, 3)
        XCTAssertTrue(sorted.allSatisfy { abs($0.height - fixedHeight) < 0.001 })
        XCTAssertGreaterThanOrEqual(sorted[0].minY, visible.minY)
        XCTAssertLessThan(sorted[0].minY - visible.minY, 3)
        XCTAssertEqual(sorted[0].maxY, sorted[1].minY, accuracy: 0.001)
        XCTAssertEqual(sorted[1].maxY, sorted[2].minY, accuracy: 0.001)
        XCTAssertEqual(sorted[2].maxY, visible.maxY, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames[newest.id]).minY, sorted[1].minY, accuracy: 0.001)
    }

    private func note(
        title: String,
        groupID: UUID,
        order: Int,
        createdAt: Date = Date()
    ) -> MemoNote {
        MemoNote(
            title: title,
            content: title,
            placement: MemoPlacement(groupID: groupID, order: order),
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

final class EdgeScreenSelectorTests: XCTestCase {
    private let candidates = [
        EdgeScreenCandidate(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), isMain: true),
        EdgeScreenCandidate(displayID: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), isMain: false)
    ]

    func testPreferredDisplayWins() {
        XCTAssertEqual(
            EdgeScreenSelector.selectedIndex(candidates: candidates, preferredDisplayID: 2, pointer: .zero),
            1
        )
    }

    func testMissingDisplayFallsBackToPointerThenMain() {
        XCTAssertEqual(
            EdgeScreenSelector.selectedIndex(
                candidates: candidates,
                preferredDisplayID: 999,
                pointer: CGPoint(x: 150, y: 50)
            ),
            1
        )
        XCTAssertEqual(
            EdgeScreenSelector.selectedIndex(
                candidates: candidates,
                preferredDisplayID: 999,
                pointer: CGPoint(x: 500, y: 500)
            ),
            0
        )
    }

    func testHotZoneRequiresARealRetreatBeforeTheNextEdgeEntry() {
        XCTAssertEqual(
            EdgeHotZoneSpatialResolver.event(isLatched: false, verticalMatch: true, distance: 1),
            true
        )
        XCTAssertNil(
            EdgeHotZoneSpatialResolver.event(isLatched: true, verticalMatch: true, distance: 5),
            "Minor edge jitter must not rearm the toggle"
        )
        XCTAssertEqual(
            EdgeHotZoneSpatialResolver.event(isLatched: true, verticalMatch: true, distance: 12),
            false
        )
        XCTAssertEqual(
            EdgeHotZoneSpatialResolver.event(isLatched: false, verticalMatch: true, distance: 0),
            true
        )
    }

    func testSharedDisplaySeamBelongsToTheScreenEnteredAtThatPoint() throws {
        let leftScreenRight = EdgeHotZoneID(screenIdentifier: "left", displayID: 1, edge: .right)
        let rightScreenLeft = EdgeHotZoneID(screenIdentifier: "right", displayID: 2, edge: .left)
        let seam = CGPoint(x: 1_440, y: 450)
        let resolved = EdgeHotZoneSeamResolver.preferredZone(
            at: seam,
            candidates: [
                EdgeHotZoneActivationSample(
                    zoneID: leftScreenRight,
                    screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
                ),
                EdgeHotZoneActivationSample(
                    zoneID: rightScreenLeft,
                    screenFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900)
                )
            ]
        )

        XCTAssertEqual(try XCTUnwrap(resolved), rightScreenLeft)
    }

    @MainActor
    func testRemovingAHotZoneScreenClearsItsPointerEdges() {
        let controller = EdgeHotZoneController()
        let screen = EdgeHotZoneScreen(
            identifier: "detached-display",
            displayID: 42,
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860)
        )
        var exitEvents: [(EdgeDock, UInt32?)] = []
        controller.onPointerChange = { zoneID, inside in
            if !inside { exitEvents.append((zoneID.edge, zoneID.displayID)) }
        }

        controller.update(screens: [screen])
        controller.update(screens: [])

        XCTAssertEqual(Set(exitEvents.map(\.0)), Set(EdgeDock.interactiveCases))
        XCTAssertTrue(exitEvents.allSatisfy { $0.1 == 42 })
    }
}

final class EdgePresentationReducerTests: XCTestCase {
    func testEdgeEntryShowsHidesAndMovesThePersistentTray() {
        let left = EdgeHotZoneID(screenIdentifier: "main", displayID: 1, edge: .left)
        let right = EdgeHotZoneID(screenIdentifier: "main", displayID: 1, edge: .right)
        let otherDisplayLeft = EdgeHotZoneID(screenIdentifier: "other", displayID: 2, edge: .left)

        XCTAssertEqual(
            EdgeHotZoneToggleResolver.action(visibleZone: nil, enteredZone: left),
            .show(left)
        )
        XCTAssertEqual(
            EdgeHotZoneToggleResolver.action(visibleZone: left, enteredZone: left),
            .hide
        )
        XCTAssertEqual(
            EdgeHotZoneToggleResolver.action(visibleZone: left, enteredZone: right),
            .move(right)
        )
        XCTAssertEqual(
            EdgeHotZoneToggleResolver.action(visibleZone: left, enteredZone: otherDisplayLeft),
            .move(otherDisplayLeft)
        )
    }

    func testClickOpensAndClosesIce() {
        let id = UUID()
        let opened = EdgePresentationReducer.reduce(state: EdgePresentationState(), action: .click(id))
        XCTAssertEqual(opened.iceNoteIDs, [id])
        XCTAssertFalse(EdgePresentationReducer.reduce(state: opened, action: .click(id)).hasOpenPanels)
    }

    func testOpeningSecondIceKeepsExistingIce() {
        let first = UUID()
        let second = UUID()
        let initial = EdgePresentationState(iceNoteIDs: [first])
        let pinned = EdgePresentationReducer.reduce(state: initial, action: .open(second))
        XCTAssertEqual(pinned.iceNoteIDs, [first, second])
        XCTAssertTrue(pinned.isIce(first))
        XCTAssertTrue(pinned.isIce(second))
    }

    func testOpeningExistingIceMovesItToMostRecentPosition() {
        let id = UUID()
        let other = UUID()
        let opened = EdgePresentationReducer.reduce(
            state: EdgePresentationState(iceNoteIDs: [id, other]),
            action: .open(id)
        )
        XCTAssertEqual(opened.iceNoteIDs, [other, id])
    }

    func testFocusAndCloseAffectOnlyRequestedIce() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let state = EdgePresentationState(iceNoteIDs: [first, second, third])

        let focused = EdgePresentationReducer.reduce(state: state, action: .focus(first))
        XCTAssertEqual(focused.iceNoteIDs, [first, second, third])
        XCTAssertEqual(focused.focusedIceNoteID, first)

        let closed = EdgePresentationReducer.reduce(state: focused, action: .close(third))
        XCTAssertEqual(closed.iceNoteIDs, [first, second])
        XCTAssertEqual(closed.focusedIceNoteID, first)
    }
}

final class MemoAssetSchemeHandlerTests: XCTestCase {
    @MainActor
    func testResolvesOnlyOneFileInsideUUIDDirectory() {
        let root = URL(fileURLWithPath: "/tmp/memodolmaeng-assets", isDirectory: true)
        let noteID = UUID(uuidString: "123E4567-E89B-42D3-A456-426614174000")!
        let valid = AttachmentService.assetURL(noteID: noteID, fileName: "image.png")
        XCTAssertEqual(
            MemoAssetSchemeHandler.resolvedFileURL(for: valid, rootURL: root)?.path,
            root.resolvingSymlinksInPath()
                .appendingPathComponent(noteID.uuidString)
                .appendingPathComponent("image.png").path
        )
        XCTAssertNil(
            MemoAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "memodolmaeng-asset://\(noteID.uuidString)/folder/image.png")!,
                rootURL: root
            )
        )
        XCTAssertNil(
            MemoAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "https://example.com/image.png")!,
                rootURL: root
            )
        )
    }

    @MainActor
    func testStagedAttachmentDeletionRecoversOrFinalizesOnNextLaunch() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengStaging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        let source = storage.appendingPathComponent("source.png")
        let imageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        try imageData.write(to: source)
        let noteID = UUID()
        let service = AttachmentService(storageDirectory: storage)
        let imported = try service.importImage(at: source, noteID: noteID)
        XCTAssertNotNil(try service.stageDeletion(noteID: noteID))

        let relaunched = AttachmentService(storageDirectory: storage)
        relaunched.reconcileStagedDeletions(existingNoteIDs: [noteID])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: relaunched.rootURL
                    .appendingPathComponent(noteID.uuidString)
                    .appendingPathComponent(imported.fileName).path
            )
        )

        XCTAssertNotNil(try relaunched.stageDeletion(noteID: noteID))
        relaunched.reconcileStagedDeletions(existingNoteIDs: [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: relaunched.rootURL.appendingPathComponent(noteID.uuidString).path
            )
        )
    }

    @MainActor
    func testNativeImageImportAcceptsRealImagesAndRejectsUnsafeInput() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengNativeImageUpload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = AttachmentService(storageDirectory: storage)
        let noteID = UUID()
        let imageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )

        let imported = try service.importImage(
            data: imageData,
            originalName: "native-editor.png",
            noteID: noteID
        )
        XCTAssertEqual(imported.originalName, "native-editor.png")
        XCTAssertEqual(imported.assetURL.scheme, MemoAssetSchemeHandler.scheme)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: service.rootURL
                    .appendingPathComponent(noteID.uuidString)
                    .appendingPathComponent(imported.fileName).path
            )
        )

        XCTAssertThrowsError(
            try service.importImage(data: imageData, originalName: "../escape.png", noteID: noteID)
        )
        XCTAssertThrowsError(
            try service.importImage(data: Data("not an image".utf8), originalName: "fake.png", noteID: noteID)
        )
    }

    @MainActor
    func testNativeImageImportHonorsTheTwentyMegabyteBoundary() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengImageBoundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = AttachmentService(storageDirectory: storage)
        let noteID = UUID()
        let baseImage = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )

        var exactLimitImage = baseImage
        exactLimitImage.append(
            Data(count: AttachmentService.maximumImportedImageBytes - baseImage.count)
        )
        let imported = try service.importImage(
            data: exactLimitImage,
            originalName: "exact-limit.png",
            noteID: noteID
        )
        let importedSize = try FileManager.default.attributesOfItem(
            atPath: service.rootURL
                .appendingPathComponent(noteID.uuidString)
                .appendingPathComponent(imported.fileName).path
        )[.size] as? NSNumber
        XCTAssertEqual(importedSize?.intValue, AttachmentService.maximumImportedImageBytes)

        exactLimitImage.append(0)
        XCTAssertThrowsError(
            try service.importImage(
                data: exactLimitImage,
                originalName: "over-limit.png",
                noteID: noteID
            )
        ) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadTooLarge.rawValue)
        }
    }
}
