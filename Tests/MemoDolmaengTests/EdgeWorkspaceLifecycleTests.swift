import AppKit
import XCTest
@testable import MemoDolmaeng

@MainActor
final class EdgeWorkspaceLifecycleTests: XCTestCase {
    func testFourthIceOnSameEdgeFoldsOldestAndKeepsNewestOnTop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let notes = try (1...4).map { index in
            try store.createNote(title: "메모 \(index)", content: "본문 \(index)")
        }
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        notes.prefix(3).forEach { workspace.handleClick(noteID: $0.id) }
        try await Task.sleep(for: .milliseconds(300))

        let panels = NSApp.windows
            .filter { $0.title == "메모돌맹 메모" && $0.isVisible }
            .sorted { $0.frame.minY > $1.frame.minY }
        XCTAssertEqual(panels.count, 3)
        XCTAssertEqual(panels[0].frame.height, panels[1].frame.height, accuracy: 1)
        XCTAssertEqual(panels[1].frame.height, panels[2].frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(panels[0].frame.minY, panels[1].frame.maxY)
        XCTAssertGreaterThanOrEqual(panels[1].frame.minY, panels[2].frame.maxY)
        XCTAssertLessThanOrEqual(panels[0].frame.minY - panels[1].frame.maxY, 1)
        XCTAssertLessThanOrEqual(panels[1].frame.minY - panels[2].frame.maxY, 1)
        for panel in panels {
            let proposed = NSSize(width: panel.frame.width + 40, height: panel.frame.height + 100)
            let resolved = try XCTUnwrap(panel.delegate?.windowWillResize?(panel, to: proposed))
            XCTAssertEqual(resolved.height, panel.frame.height, accuracy: 0.001)
            XCTAssertEqual(resolved.width, proposed.width, accuracy: 0.001)
        }

        workspace.handleClick(noteID: notes[3].id)

        XCTAssertEqual(workspace.presentationState.iceNoteIDs, Array(notes.dropFirst().map(\.id)))
        XCTAssertFalse(workspace.presentationState.isIce(notes[0].id))
        XCTAssertEqual(workspace.presentationState.focusedIceNoteID, notes[3].id)
        XCTAssertTrue(notes.allSatisfy { store.note(withID: $0.id) != nil })

        for noteID in workspace.presentationState.iceNoteIDs {
            workspace.closeMemo(noteID: noteID)
        }
        try await Task.sleep(for: .milliseconds(300))
    }

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

    func testIceOpenedOnEitherSideLeavesTheSharedIndexList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let leftNote = try store.createNote(title: "왼쪽 ICE", content: "왼쪽")
        let rightNote = try store.createNote(title: "오른쪽 ICE", content: "오른쪽")
        let availableNote = try store.createNote(title: "남은 인덱스", content: "남음")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: leftNote.id, on: .left)
        workspace.handleClick(noteID: rightNote.id, on: .right)

        XCTAssertEqual(Set(workspace.availableIndexNotes.map(\.id)), Set([availableNote.id]))
        XCTAssertEqual(workspace.edge(for: leftNote.id), .left)
        XCTAssertEqual(workspace.edge(for: rightNote.id), .right)

        workspace.closeMemo(noteID: leftNote.id)
        workspace.closeMemo(noteID: rightNote.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Set(workspace.availableIndexNotes.map(\.id)), Set([leftNote.id, rightNote.id, availableNote.id]))
    }

    func testProgrammaticOpenAndFoldDoNotPersistAResize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let note = try store.createNote(title: "크기 보존", content: "본문")
        let updatedAt = try XCTUnwrap(store.note(withID: note.id)?.updatedAt)
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: note.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.note(withID: note.id)?.panelSize)
        XCTAssertEqual(store.note(withID: note.id)?.updatedAt, updatedAt)

        workspace.closeMemo(noteID: note.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(store.note(withID: note.id)?.panelSize)
        XCTAssertEqual(store.note(withID: note.id)?.updatedAt, updatedAt)
    }

    func testIndexClickDoesNotSelectTheTitleField() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let note = try store.createNote(title: "선택되지 않을 제목", content: "본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: note.id)
        try await Task.sleep(for: .milliseconds(300))

        let panel = try XCTUnwrap(
            NSApp.windows.last { $0.title == "메모돌맹 메모" && $0.isVisible }
        )
        XCTAssertFalse((panel.firstResponder as? NSTextView)?.isFieldEditor == true)

        workspace.closeMemo(noteID: note.id)
        try await Task.sleep(for: .milliseconds(250))
    }

    func testEdgeCreationStartsAnUnsavedIceDraftOnRequestedEdge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.createNote(on: .left)

        let draft = try XCTUnwrap(workspace.activeNotes.first)
        XCTAssertEqual(workspace.edge(for: draft.id), .left)
        XCTAssertTrue(workspace.presentationState.isIce(draft.id))
        XCTAssertTrue(store.notes.isEmpty, "An untouched edge draft must not reach disk")

        workspace.closeMemo(noteID: draft.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(workspace.notes.isEmpty)
        XCTAssertTrue(store.notes.isEmpty)
    }
}
