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
        XCTAssertEqual(snapshot.groupFrames[group.id]?.midY ?? 0, visible.midY, accuracy: 0.001)
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

    func testManualGroupKeepsPositionAndDefaultGroupMovesOutOfCollision() {
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

        XCTAssertEqual(manualFrame.midY, visible.midY, accuracy: 0.001)
        XCTAssertFalse(manualFrame.insetBy(dx: 0, dy: -EdgeLayoutEngine.groupGap).intersects(defaultFrame))
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
        XCTAssertEqual(panel.maxY, handle.minY, accuracy: 0.001)
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
                XCTAssertEqual(panel.minX, handle.maxX, accuracy: 0.001)
            } else {
                XCTAssertEqual(handle.maxX, screen.maxX, accuracy: 0.001)
                XCTAssertEqual(panel.maxX, handle.minX, accuracy: 0.001)
            }
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
        XCTAssertEqual(panel.maxX, handle.minX, accuracy: 0.001)
    }

    func testUnifiedSurfaceIncludesHandleAndRestoresBodySizeOnSideEdges() {
        let body = CGRect(x: 100, y: 100, width: 340, height: 400)

        for (edge, handle) in [
            (EdgeDock.left, CGRect(x: 4, y: 474, width: 96, height: 26)),
            (EdgeDock.right, CGRect(x: 440, y: 474, width: 96, height: 26))
        ] {
            let surface = EdgeLayoutEngine.unifiedSurfaceFrame(
                bodyFrame: body,
                handleFrame: handle
            )
            let restored = EdgeLayoutEngine.bodySize(
                fromSurfaceSize: surface.size,
                handleSize: handle.size,
                edge: edge
            )

            XCTAssertEqual(surface, body.union(handle))
            XCTAssertEqual(restored.width, body.width, accuracy: 0.001)
            XCTAssertEqual(restored.height, body.height, accuracy: 0.001)
        }
    }

    func testUnifiedTopSurfaceRestoresBodySizeWithoutAccumulatingHandleHeight() {
        let body = CGRect(x: 100, y: 100, width: 340, height: 400)
        let handle = CGRect(x: 220, y: 500, width: 100, height: 26)
        let surface = EdgeLayoutEngine.unifiedSurfaceFrame(
            bodyFrame: body,
            handleFrame: handle
        )
        let restored = EdgeLayoutEngine.bodySize(
            fromSurfaceSize: surface.size,
            handleSize: handle.size,
            edge: .top
        )

        XCTAssertEqual(surface, body.union(handle))
        XCTAssertEqual(restored.width, body.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, body.height, accuracy: 0.001)
    }

    func testStoredPanelSizeIsClampedToVisibleScreen() {
        let tinyVisible = CGRect(x: 0, y: 0, width: 260, height: 210)
        let handle = CGRect(x: 260, y: 100, width: 80, height: 26)
        let panel = EdgeLayoutEngine.panelFrame(
            adjacentTo: handle,
            screenFrame: CGRect(x: 0, y: 0, width: 340, height: 210),
            visibleFrame: tinyVisible,
            edge: .left,
            aspectRatio: MemoAspectRatio.portrait.value,
            panelSize: MemoPanelSize(width: 720, height: 900)
        )

        XCTAssertEqual(panel.width, tinyVisible.width, accuracy: 0.001)
        XCTAssertEqual(panel.height, tinyVisible.height, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(panel.minY, tinyVisible.minY)
        XCTAssertLessThanOrEqual(panel.maxY, tinyVisible.maxY)
    }

    func testPanelRevealAnchorsTouchEachHandleEdge() {
        let panel = CGRect(x: 100, y: 100, width: 340, height: 400)

        let right = EdgeLayoutEngine.panelRevealAnchorRect(
            panelFrame: panel,
            handleFrame: CGRect(x: 440, y: 474, width: 90, height: 26),
            edge: .right
        )
        XCTAssertEqual(right.maxX, panel.width, accuracy: 0.001)
        XCTAssertEqual(right.minY, 374, accuracy: 0.001)
        XCTAssertEqual(right.height, 26, accuracy: 0.001)

        let left = EdgeLayoutEngine.panelRevealAnchorRect(
            panelFrame: panel,
            handleFrame: CGRect(x: 10, y: 250, width: 90, height: 26),
            edge: .left
        )
        XCTAssertEqual(left.minX, 0, accuracy: 0.001)
        XCTAssertEqual(left.minY, 150, accuracy: 0.001)

        let top = EdgeLayoutEngine.panelRevealAnchorRect(
            panelFrame: panel,
            handleFrame: CGRect(x: 220, y: 500, width: 100, height: 26),
            edge: .top
        )
        XCTAssertEqual(top.minX, 120, accuracy: 0.001)
        XCTAssertEqual(top.maxY, panel.height, accuracy: 0.001)
        XCTAssertEqual(top.width, 100, accuracy: 0.001)
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
        XCTAssertGreaterThan(
            EdgeLayoutEngine.hiddenHandleFrame(for: frame, edge: .top).minY,
            frame.minY
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

    func testDropEdgeAndNormalizedCenterUseVisibleFrame() {
        XCTAssertEqual(
            EdgeLayoutEngine.dock(
                at: CGPoint(x: screen.maxX - 2, y: visible.midY),
                screenFrame: screen,
                visibleFrame: visible
            ),
            .right
        )
        XCTAssertEqual(
            EdgeLayoutEngine.dock(
                at: CGPoint(x: visible.midX, y: visible.maxY - 1),
                screenFrame: screen,
                visibleFrame: visible
            ),
            .top
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

    func testTenManualGroupsCompressGloballyWithoutOverlapOnSmallScreen() {
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
            XCTAssertGreaterThanOrEqual(
                pair.1.minY - pair.0.maxY,
                EdgeLayoutEngine.groupGap - 0.01
            )
        }
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
}

final class EdgePresentationReducerTests: XCTestCase {
    func testHoverOpensPeekAndClickPinsIce() {
        let id = UUID()
        let opened = EdgePresentationReducer.reduce(state: EdgePresentationState(), action: .hover(id))
        XCTAssertEqual(opened.peekNoteID, id)

        let pinned = EdgePresentationReducer.reduce(state: opened, action: .click(id))
        XCTAssertNil(pinned.peekNoteID)
        XCTAssertEqual(pinned.iceNoteIDs, [id])
        XCTAssertFalse(EdgePresentationReducer.reduce(state: pinned, action: .click(id)).hasOpenPanels)
    }

    func testExistingIceSurvivesHoverAndSecondIce() {
        let first = UUID()
        let second = UUID()
        let initial = EdgePresentationState(iceNoteIDs: [first])
        let previewed = EdgePresentationReducer.reduce(state: initial, action: .hover(second))
        XCTAssertEqual(previewed.peekNoteID, second)
        XCTAssertEqual(previewed.iceNoteIDs, [first])

        let pinned = EdgePresentationReducer.reduce(state: previewed, action: .click(second))
        XCTAssertNil(pinned.peekNoteID)
        XCTAssertEqual(pinned.iceNoteIDs, [first, second])
        XCTAssertTrue(pinned.isIce(first))
        XCTAssertTrue(pinned.isIce(second))
    }

    func testDoubleClickAndModeToggle() {
        let id = UUID()
        let pinned = EdgePresentationReducer.reduce(
            state: EdgePresentationState(),
            action: .doubleClick(id)
        )
        XCTAssertEqual(pinned.iceNoteIDs, [id])
        let peeked = EdgePresentationReducer.reduce(state: pinned, action: .toggleMode)
        XCTAssertEqual(peeked.peekNoteID, id)
        XCTAssertTrue(peeked.iceNoteIDs.isEmpty)
    }

    func testFocusAndCloseAffectOnlyRequestedIce() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let state = EdgePresentationState(iceNoteIDs: [first, second, third])

        let focused = EdgePresentationReducer.reduce(state: state, action: .focus(first))
        XCTAssertEqual(focused.iceNoteIDs, [second, third, first])

        let closed = EdgePresentationReducer.reduce(state: focused, action: .close(third))
        XCTAssertEqual(closed.iceNoteIDs, [second, first])
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
}
