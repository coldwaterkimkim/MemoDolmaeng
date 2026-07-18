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

        try await Task.sleep(for: .milliseconds(300))
        let settledPanels = NSApp.windows
            .filter { $0.title == "메모돌맹 메모" && $0.isVisible }
            .sorted { $0.frame.minY > $1.frame.minY }
        XCTAssertEqual(settledPanels.count, 3)
        XCTAssertGreaterThanOrEqual(settledPanels[0].frame.minY, settledPanels[1].frame.maxY)
        XCTAssertGreaterThanOrEqual(settledPanels[1].frame.minY, settledPanels[2].frame.maxY)

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

    func testNewestIceKeepsItsClickedIndexHeightAndReflowsThePreviousPanel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let first = try store.createNote(title: "첫 메모", content: "첫 본문")
        let second = try store.createNote(title: "둘째 메모", content: "둘째 본문")
        let third = try store.createNote(title: "셋째 메모", content: "셋째 본문")
        let screen = try XCTUnwrap(NSScreen.main)
        let preferencesSuite = "MemoDolmaengWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferencesSuite))
        defer { defaults.removePersistentDomain(forName: preferencesSuite) }
        let preferences = EdgePreferences(defaults: defaults)
        preferences.defaultEdge = .right
        preferences.targetDisplayID = screen.memoDisplayID
        let workspace = EdgeWorkspaceController(store: store, preferences: preferences)
        workspace.start()

        workspace.handleClick(noteID: first.id)
        let expectedSecondHandle = try XCTUnwrap(
            EdgeLayoutEngine.launcherLayout(
                notes: [second, third],
                edge: .right,
                anchorY: screen.visibleFrame.midY,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            ).handleFrames[second.id]
        )
        workspace.handleClick(noteID: second.id)
        try await Task.sleep(for: .milliseconds(300))

        let firstPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(first.id.uuidString)")
        })
        let secondPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(second.id.uuidString)")
        })
        XCTAssertEqual(secondPanel.frame.maxY, expectedSecondHandle.maxY, accuracy: 1)
        XCTAssertLessThanOrEqual(firstPanel.frame.intersection(secondPanel.frame).height, 1)

        workspace.closeMemo(noteID: first.id)
        workspace.closeMemo(noteID: second.id)
        try await Task.sleep(for: .milliseconds(250))
    }

    func testClickingEarlierIceChangesFocusWithoutChangingFifoOrder() async throws {
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
        try await Task.sleep(for: .milliseconds(280))

        let firstPanel = try XCTUnwrap(
            NSApp.windows.first {
                $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(first.id.uuidString)")
            }
        )
        firstPanel.delegate?.windowDidBecomeKey?(
            Notification(name: NSWindow.didBecomeKeyNotification, object: firstPanel)
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(workspace.presentationState.iceNoteIDs, [first.id, second.id])
        XCTAssertEqual(workspace.presentationState.focusedIceNoteID, first.id)

        workspace.toggleRecent()
        XCTAssertEqual(workspace.presentationState.iceNoteIDs, [second.id])
        XCTAssertEqual(workspace.presentationState.focusedIceNoteID, second.id)
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

    func testOpenAndFoldLeavePersistedBytesUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let notesURL = directory.appendingPathComponent("notes.json")
        let store = try NoteStore(persistenceURL: notesURL)
        let note = try store.createNote(title: "원문 보존", content: "# 제목\n\n한글 본문 **굵게**")
        let before = try Data(contentsOf: notesURL)
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: note.id)
        try await Task.sleep(for: .milliseconds(280))
        workspace.closeMemo(noteID: note.id)
        try await Task.sleep(for: .milliseconds(240))

        XCTAssertEqual(try Data(contentsOf: notesURL), before)
    }

    func testRapidOpenCloseOpenSettlesToOneEditablePanel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let note = try store.createNote(title: "빠른 전환", content: "본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        for _ in 0..<5 {
            workspace.handleClick(noteID: note.id)
            workspace.closeMemo(noteID: note.id)
            workspace.handleClick(noteID: note.id)
        }
        try await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(workspace.presentationState.iceNoteIDs, [note.id])
        let visiblePanels = NSApp.windows.filter {
            $0.title == "메모돌맹 메모" && $0.isVisible
        }
        XCTAssertEqual(visiblePanels.count, 1)
        XCTAssertEqual(visiblePanels.first?.alphaValue, 1)

        workspace.closeMemo(noteID: note.id)
        try await Task.sleep(for: .milliseconds(240))
    }

    func testPanelGeometryNeverReversesDuringOpenAndFold() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let note = try store.createNote(title: "모션 검증", content: "본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: note.id)
        let identifier = NSUserInterfaceItemIdentifier("memo-panel-\(note.id.uuidString)")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier == identifier })
        var openingFrames: [CGRect] = []
        for _ in 0..<18 {
            openingFrames.append(panel.frame)
            try await Task.sleep(for: .milliseconds(16))
        }

        for (previous, next) in zip(openingFrames, openingFrames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.width + 1, previous.width)
            XCTAssertGreaterThanOrEqual(next.height + 1, previous.height)
        }

        workspace.closeMemo(noteID: note.id)
        var foldingFrames: [CGRect] = []
        for _ in 0..<16 {
            foldingFrames.append(panel.frame)
            try await Task.sleep(for: .milliseconds(16))
        }

        for (previous, next) in zip(foldingFrames, foldingFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(next.width, previous.width + 1)
            XCTAssertLessThanOrEqual(next.height, previous.height + 1)
        }
        XCTAssertFalse(panel.isVisible)
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

        let draft = try XCTUnwrap(workspace.notes.first)
        XCTAssertEqual(workspace.edge(for: draft.id), .left)
        XCTAssertTrue(workspace.presentationState.isIce(draft.id))
        XCTAssertTrue(store.notes.isEmpty, "An untouched edge draft must not reach disk")

        workspace.closeMemo(noteID: draft.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(workspace.notes.isEmpty)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testAdjacentButtonsCreateIndependentDraftsInOneHorizontalLane() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let source = try store.createNote(title: "기준 메모", content: "기준 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: source.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))

        workspace.createAdjacentMemo(to: source.id, direction: .right)
        let rightDraft = try XCTUnwrap(workspace.notes.first { $0.id != source.id })
        XCTAssertEqual(rightDraft.color, source.color, "A child memo must inherit its mother memo color")
        workspace.createAdjacentMemo(to: source.id, direction: .left)
        let leftDraft = try XCTUnwrap(
            workspace.notes.first { $0.id != source.id && $0.id != rightDraft.id }
        )
        XCTAssertEqual(leftDraft.color, source.color, "Every child in the chain must share the mother color")
        try await Task.sleep(for: .milliseconds(320))

        let sourcePanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(source.id.uuidString)")
        })
        let leftPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(leftDraft.id.uuidString)")
        })
        let rightPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(rightDraft.id.uuidString)")
        })

        XCTAssertLessThan(leftPanel.frame.maxX, sourcePanel.frame.minX)
        XCTAssertLessThan(sourcePanel.frame.maxX, rightPanel.frame.minX)
        XCTAssertEqual(leftPanel.frame.minY, sourcePanel.frame.minY, accuracy: 1)
        XCTAssertEqual(rightPanel.frame.minY, sourcePanel.frame.minY, accuracy: 1)
        XCTAssertEqual(leftPanel.frame.height, sourcePanel.frame.height, accuracy: 1)
        XCTAssertEqual(rightPanel.frame.height, sourcePanel.frame.height, accuracy: 1)
        XCTAssertEqual(Set(workspace.presentationState.iceNoteIDs), Set([source.id, leftDraft.id, rightDraft.id]))
        XCTAssertEqual(store.notes.map(\.id), [source.id], "Blank adjacent drafts must stay off disk")

        workspace.closeMemo(noteID: source.id)
        XCTAssertFalse(workspace.presentationState.isIce(source.id))
        XCTAssertTrue(workspace.presentationState.isIce(leftDraft.id))
        XCTAssertTrue(workspace.presentationState.isIce(rightDraft.id))

        workspace.closeMemo(noteID: leftDraft.id)
        workspace.closeMemo(noteID: rightDraft.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.notes.map(\.id), [source.id])
        XCTAssertEqual(store.notes.map(\.id), [source.id])
    }

    func testAdjacentInsertionFromMiddleMemoKeepsExactHorizontalOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let source = try store.createNote(
            title: "mother",
            content: "기준 본문",
            color: .pink
        )
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: source.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))

        workspace.createAdjacentMemo(to: source.id, direction: .right)
        let tail = try XCTUnwrap(workspace.notes.first { $0.id != source.id })
        workspace.createAdjacentMemo(to: source.id, direction: .right)
        let middle = try XCTUnwrap(workspace.notes.first {
            $0.id != source.id && $0.id != tail.id
        })
        try await Task.sleep(for: .milliseconds(360))

        let horizontalOrder = [source.id, middle.id, tail.id].sorted { lhs, rhs in
            let leftWindow = NSApp.windows.first {
                $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(lhs.uuidString)")
            }
            let rightWindow = NSApp.windows.first {
                $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(rhs.uuidString)")
            }
            return (leftWindow?.frame.minX ?? 0) < (rightWindow?.frame.minX ?? 0)
        }
        XCTAssertEqual(horizontalOrder, [source.id, middle.id, tail.id])
        XCTAssertTrue(
            [source.id, middle.id, tail.id].allSatisfy {
                workspace.note(withID: $0)?.color == .pink
            }
        )

        [source.id, middle.id, tail.id].forEach { workspace.closeMemo(noteID: $0) }
        try await Task.sleep(for: .milliseconds(300))
    }

    func testHorizontalLaneUsesOneMotherColorAfterRecolorAndMotherCloses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let mother = try store.createNote(
            title: "mother",
            content: "기준 본문",
            color: .pink
        )
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: mother.id, on: .right)
        try await Task.sleep(for: .milliseconds(280))

        workspace.createAdjacentMemo(to: mother.id, direction: .right)
        let child = try XCTUnwrap(workspace.notes.first { $0.id != mother.id })
        workspace.updateAppearance(noteID: child.id, color: .green)

        XCTAssertEqual(workspace.note(withID: mother.id)?.color, .green)
        XCTAssertEqual(workspace.note(withID: child.id)?.color, .green)
        XCTAssertEqual(store.note(withID: mother.id)?.color, .green)

        workspace.closeMemo(noteID: mother.id)
        workspace.createAdjacentMemo(to: child.id, direction: .right)
        let grandchild = try XCTUnwrap(workspace.notes.first {
            $0.id != mother.id && $0.id != child.id
        })

        XCTAssertEqual(grandchild.color, .green)
        XCTAssertEqual(workspace.note(withID: child.id)?.color, .green)
        XCTAssertEqual(workspace.note(withID: mother.id)?.color, .green)

        workspace.closeMemo(noteID: child.id)
        workspace.closeMemo(noteID: grandchild.id)
        try await Task.sleep(for: .milliseconds(300))
    }

    func testHoveringAnInternalInsertionPanelExpandsAndRestoresOnlyItsGap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let mother = try store.createNote(title: "mother", content: "기준 본문", color: .yellow)
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: mother.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))
        workspace.createAdjacentMemo(to: mother.id, direction: .right)
        let child = try XCTUnwrap(workspace.notes.first { $0.id != mother.id })
        try await Task.sleep(for: .milliseconds(320))

        let insertionPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("adjacent-insertion-") == true
                && $0.isVisible
                && abs($0.frame.width - EdgeLayoutEngine.laneGap) <= 1
        })
        let insertionView = try XCTUnwrap(insertionPanel.contentView)
        let entered = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: insertionPanel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
        insertionView.mouseEntered(with: entered)
        try await Task.sleep(for: .milliseconds(220))

        let expandedWindows = try [mother.id, child.id]
            .map { id in
                try XCTUnwrap(NSApp.windows.first {
                    $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(id.uuidString)")
                })
            }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(
            expandedWindows[1].frame.minX - expandedWindows[0].frame.maxX,
            EdgeLayoutEngine.laneExpandedGap,
            accuracy: 1
        )
        XCTAssertEqual(insertionPanel.frame.width, EdgeLayoutEngine.laneExpandedGap, accuracy: 1)
        XCTAssertEqual(expandedWindows[0].frame.height, expandedWindows[1].frame.height, accuracy: 0.001)

        let exited = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: insertionPanel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
        insertionView.mouseExited(with: exited)
        try await Task.sleep(for: .milliseconds(340))

        let restoredWindows = try [mother.id, child.id]
            .map { id in
                try XCTUnwrap(NSApp.windows.first {
                    $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(id.uuidString)")
                })
            }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(
            restoredWindows[1].frame.minX - restoredWindows[0].frame.maxX,
            EdgeLayoutEngine.laneGap,
            accuracy: 1
        )

        workspace.closeMemo(noteID: mother.id)
        workspace.closeMemo(noteID: child.id)
        try await Task.sleep(for: .milliseconds(300))
    }

    func testEscapeFromAnyHorizontalMemoClosesTheWholeLane() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let mother = try store.createNote(title: "mother", content: "기준 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: mother.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))
        workspace.createAdjacentMemo(to: mother.id, direction: .right)
        let child = try XCTUnwrap(workspace.notes.first { $0.id != mother.id })
        try await Task.sleep(for: .milliseconds(320))

        let childPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(child.id.uuidString)")
        })
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: childPanel.windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        XCTAssertTrue(childPanel.performKeyEquivalent(with: escape))
        try await Task.sleep(for: .milliseconds(340))

        XCTAssertTrue(workspace.presentationState.iceNoteIDs.isEmpty)
        XCTAssertEqual(store.notes.map(\.id), [mother.id])
        XCTAssertFalse(childPanel.isVisible)
    }

    func testCommandWFromAnyHorizontalMemoClosesTheWholeLane() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let mother = try store.createNote(title: "mother", content: "기준 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: mother.id, on: .right)
        try await Task.sleep(for: .milliseconds(280))
        workspace.createAdjacentMemo(to: mother.id, direction: .right)
        _ = try XCTUnwrap(workspace.notes.first { $0.id != mother.id })
        try await Task.sleep(for: .milliseconds(320))

        let motherPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(mother.id.uuidString)")
        })
        let commandW = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: motherPanel.windowNumber,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: KeyboardShortcuts.KeyCode.w
            )
        )
        XCTAssertTrue(motherPanel.performKeyEquivalent(with: commandW))
        try await Task.sleep(for: .milliseconds(340))

        XCTAssertTrue(workspace.presentationState.iceNoteIDs.isEmpty)
        XCTAssertEqual(store.notes.map(\.id), [mother.id])
        XCTAssertFalse(motherPanel.isVisible)
    }

    func testTrayCreateDoesNotReuseAnOpenAdjacentDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let source = try store.createNote(title: "기준 메모", content: "기준 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: source.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))
        workspace.createAdjacentMemo(to: source.id, direction: .right)
        let adjacentDraft = try XCTUnwrap(workspace.notes.first { $0.id != source.id })
        let IDsBeforeCreate = Set(workspace.notes.map(\.id))

        workspace.createNote(on: .right)

        let createdID = try XCTUnwrap(Set(workspace.notes.map(\.id)).subtracting(IDsBeforeCreate).first)
        XCTAssertNotEqual(createdID, adjacentDraft.id)
        XCTAssertEqual(workspace.edge(for: createdID), .right)
        XCTAssertTrue(workspace.presentationState.isIce(createdID))
        XCTAssertTrue(workspace.presentationState.isIce(adjacentDraft.id))

        for noteID in workspace.presentationState.iceNoteIDs {
            workspace.closeMemo(noteID: noteID)
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    func testAdjacentRevealBuffersTheFirstImmediateInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let source = try store.createNote(title: "기준 메모", content: "기준 본문")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()
        workspace.handleClick(noteID: source.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))

        workspace.createAdjacentMemo(to: source.id, direction: .right)
        let child = try XCTUnwrap(workspace.notes.first { $0.id != source.id })
        let childPanel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(child.id.uuidString)")
        })
        let immediateInput = try XCTUnwrap(childPanel.firstResponder as? NSTextView)
        immediateInput.insertText(
            "즉시 입력",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(workspace.prepareForTermination())

        try await Task.sleep(for: .milliseconds(320))

        XCTAssertEqual(store.note(withID: child.id)?.content, "즉시 입력")
        XCTAssertEqual(store.note(withID: source.id)?.content, "기준 본문")
        workspace.closeMemo(noteID: child.id)
        workspace.closeMemo(noteID: source.id)
        try await Task.sleep(for: .milliseconds(300))
    }

    func testRevealBufferPreservesImmediateEditingOfExistingContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let note = try store.createNote(title: "기존 메모", content: "AB")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: note.id, on: .right)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == NSUserInterfaceItemIdentifier("memo-panel-\(note.id.uuidString)")
        })
        let immediateInput = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertEqual(immediateInput.string, "AB")
        immediateInput.deleteBackward(nil)
        XCTAssertTrue(workspace.prepareForTermination())

        XCTAssertEqual(store.note(withID: note.id)?.content, "A")
        workspace.closeMemo(noteID: note.id)
        try await Task.sleep(for: .milliseconds(300))
    }

    func testHorizontalLaneKeepsItsOriginalFIFOAgeAfterMotherCloses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NoteStore(persistenceURL: directory.appendingPathComponent("notes.json"))
        let first = try store.createNote(title: "A", content: "첫 번째")
        let second = try store.createNote(title: "B", content: "두 번째")
        let third = try store.createNote(title: "C", content: "세 번째")
        let fourth = try store.createNote(title: "D", content: "네 번째")
        let workspace = EdgeWorkspaceController(store: store)
        workspace.start()

        workspace.handleClick(noteID: first.id, on: .left)
        workspace.handleClick(noteID: second.id, on: .left)
        workspace.handleClick(noteID: third.id, on: .left)
        try await Task.sleep(for: .milliseconds(280))
        workspace.createAdjacentMemo(to: first.id, direction: .right)
        let child = try XCTUnwrap(workspace.notes.first {
            ![first.id, second.id, third.id, fourth.id].contains($0.id)
        })
        workspace.closeMemo(noteID: first.id)

        workspace.handleClick(noteID: fourth.id, on: .left)

        XCTAssertFalse(workspace.presentationState.isIce(child.id), "The oldest lane must be evicted even after its mother closes")
        XCTAssertTrue(workspace.presentationState.isIce(second.id))
        XCTAssertTrue(workspace.presentationState.isIce(third.id))
        XCTAssertTrue(workspace.presentationState.isIce(fourth.id))

        for noteID in workspace.presentationState.iceNoteIDs {
            workspace.closeMemo(noteID: noteID)
        }
        try await Task.sleep(for: .milliseconds(300))
    }
}
