import AppKit
import XCTest
@testable import MemoDolmaeng

@MainActor
final class EdgeWorkspaceLifecycleTests: XCTestCase {
    func testOpeningSecondIceKeepsFirstIceOpenAndStored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let first = try store.createNote(title: "첫 메모", content: "첫 본문")
        let second = try store.createNote(title: "둘째 메모", content: "둘째 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: first.id)
        workspace.handleClick(noteID: second.id)

        XCTAssertEqual(workspace.presentationState.iceNoteIDs, [first.id, second.id])
        XCTAssertGreaterThanOrEqual(
            NSApp.windows.filter { $0.title == "메모돌맹 메모" && $0.isVisible }.count,
            2
        )
        XCTAssertNotNil(store.note(withID: first.id))
        XCTAssertNotNil(store.note(withID: second.id))

        workspace.closeMemo(noteID: first.id)
        XCTAssertEqual(workspace.presentationState.iceNoteIDs, [second.id])
        XCTAssertNotNil(store.note(withID: first.id))

        workspace.closeMemo(noteID: second.id)
        try await Task.sleep(for: .milliseconds(250))
    }

    func testEdgeCreationStartsAnUnsavedIceDraftOnRequestedEdge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.createNote(on: .top)

        let draft = try XCTUnwrap(workspace.activeNotes.first)
        XCTAssertEqual(workspace.edge(for: draft.id), .top)
        XCTAssertTrue(workspace.presentationState.isIce(draft.id))
        XCTAssertTrue(store.notes.isEmpty, "An untouched edge draft must not reach disk")

        workspace.closeMemo(noteID: draft.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(workspace.notes.isEmpty)
        XCTAssertTrue(store.notes.isEmpty)
    }
}
