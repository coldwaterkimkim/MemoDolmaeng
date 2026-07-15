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
        XCTAssertEqual(frames[0].minY, frames[1].maxY, accuracy: 0.001)
        XCTAssertEqual(frames[1].minY, frames[2].maxY, accuracy: 0.001)
        XCTAssertEqual(snapshot.groupFrames[group.id]?.midY ?? 0, visible.midY, accuracy: 0.001)
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
    func testClickOpensPeekAndSecondClickCloses() {
        let id = UUID()
        let opened = EdgePresentationReducer.reduce(state: .closed, action: .click(id))
        XCTAssertEqual(opened, .peek(id))
        XCTAssertEqual(EdgePresentationReducer.reduce(state: opened, action: .click(id)), .closed)
    }

    func testIceSurvivesSwitchingNotes() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(EdgePresentationReducer.reduce(state: .ice(first), action: .click(second)), .ice(second))
    }

    func testDoubleClickAndModeToggle() {
        let id = UUID()
        XCTAssertEqual(EdgePresentationReducer.reduce(state: .closed, action: .doubleClick(id)), .ice(id))
        XCTAssertEqual(EdgePresentationReducer.reduce(state: .ice(id), action: .toggleMode), .peek(id))
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
    func testCrepeImageUploadAcceptsRealImagesAndRejectsUnsafeInput() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengCrepeUpload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = AttachmentService(storageDirectory: storage)
        let noteID = UUID()
        let imageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )

        let imported = try service.importImage(
            data: imageData,
            originalName: "crepe.png",
            noteID: noteID
        )
        XCTAssertEqual(imported.originalName, "crepe.png")
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
