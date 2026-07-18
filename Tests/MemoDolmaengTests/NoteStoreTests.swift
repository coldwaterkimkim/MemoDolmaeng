import Foundation
import XCTest
@testable import MemoDolmaeng

@MainActor
final class NoteStoreTests: XCTestCase {
    func testLegacyMigrationFiltersEmptyNotesAndCreatesPackedDefaultGroup() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var legacyNotes = [LegacyNoteFixture.empty(updatedAt: baseDate)]
        for index in 0..<12 {
            legacyNotes.append(
                LegacyNoteFixture(
                    content: "# 메모 \(index + 1)",
                    isVisible: index < 3,
                    color: index == 0 ? .pink : .black,
                    isTranslucent: index == 0,
                    updatedAt: baseDate.addingTimeInterval(TimeInterval(index))
                )
            )
        }
        let visibleIDs = Set(legacyNotes.filter(\.isVisible).map(\.id))
        try fixture.writeLegacy(legacyNotes)

        let store = try NoteStore(persistenceURL: fixture.notesURL, now: { baseDate })

        XCTAssertEqual(store.notes.count, 12)
        XCTAssertEqual(store.activeNotes().count, 10)
        XCTAssertTrue(visibleIDs.isSubset(of: Set(store.activeNotes().map(\.id))))
        let ordered = store.activeNotes().sorted { $0.placement.order < $1.placement.order }
        XCTAssertTrue(visibleIDs.contains(ordered[0].id))
        XCTAssertTrue(visibleIDs.contains(ordered[1].id))
        XCTAssertTrue(visibleIDs.contains(ordered[2].id))
        XCTAssertTrue(store.notes.allSatisfy { $0.placement.groupID == store.defaultGroupID })
        XCTAssertEqual(store.defaultGroup.edge, .right)
        XCTAssertFalse(store.notes.contains(where: { !MemoNote.hasMeaningfulContent($0.content) }))

        let envelope = try fixture.readEnvelope()
        XCTAssertEqual(envelope.schemaVersion, 4)
        XCTAssertEqual(envelope.edgeGroups.count, 1)
    }

    func testV2MigrationPreservesVisualOrderAndBacksUpOriginalBytes() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let notes = [
            V2NoteFixture(title: "아래", content: "아래", handlePosition: 0.1),
            V2NoteFixture(title: "위", content: "위", handlePosition: 0.9),
            V2NoteFixture(title: "중간", content: "중간", handlePosition: 0.5),
            V2NoteFixture(title: "빈메모", content: "   ", handlePosition: 0.7)
        ]
        let originalData = try fixture.writeV2(notes)
        let store = try NoteStore(
            persistenceURL: fixture.notesURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        XCTAssertEqual(
            store.activeNotes().sorted { $0.placement.order < $1.placement.order }.map(\.title),
            ["위", "중간", "아래"]
        )
        XCTAssertEqual(store.defaultGroup.edge, .right)
        let backups = try fixture.backups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("notes-pre-edge-v3-"))
        XCTAssertEqual(try Data(contentsOf: backups[0]), originalData)

        _ = try NoteStore(persistenceURL: fixture.notesURL)
        XCTAssertEqual(try fixture.backups().count, 1, "v3 reload must not create another migration backup")
    }

    func testV3MigrationFlattensEachEdgeAndPreservesVisualOrderAndWidth() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let upper = MemoEdgeGroup(
            edge: .right,
            normalizedCenter: 0.8,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let lower = MemoEdgeGroup(
            edge: .right,
            normalizedCenter: 0.2,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let upperNote = MemoNote(
            title: "위",
            content: "위",
            placement: MemoPlacement(groupID: upper.id, order: 0),
            panelSize: MemoPanelSize(width: 510, height: 420)
        )
        let lowerNote = MemoNote(
            title: "아래",
            content: "아래",
            placement: MemoPlacement(groupID: lower.id, order: 0)
        )
        try fixture.writeEnvelope(
            NoteStoreEnvelope(
                schemaVersion: 3,
                notes: [lowerNote, upperNote],
                edgeGroups: [lower, upper],
                defaultGroupID: upper.id
            )
        )

        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let ordered = store.activeNotes().sorted { $0.placement.order < $1.placement.order }

        XCTAssertEqual(ordered.map(\.title), ["위", "아래"])
        XCTAssertEqual(store.edgeGroups.filter { $0.edge == .right }.count, 1)
        XCTAssertEqual(store.note(withID: upperNote.id)?.panelSize?.cgSize.width, 510)
        XCTAssertEqual(try fixture.readEnvelope().schemaVersion, 4)
        XCTAssertTrue(try fixture.backups().contains {
            $0.lastPathComponent.hasPrefix("notes-pre-edge-stack-v4-")
        })
    }

    func testMigrationBackupFailureThrowsWithoutOverwritingSource() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let originalData = try fixture.writeV2([V2NoteFixture(title: "보존", content: "지켜야 할 메모")])
        try Data("blocks-directory-creation".utf8).write(
            to: fixture.directory.appendingPathComponent("Backups")
        )

        XCTAssertThrowsError(try NoteStore(persistenceURL: fixture.notesURL))
        XCTAssertEqual(try Data(contentsOf: fixture.notesURL), originalData)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.notesURL))
        XCTAssertTrue(root is [String: Any])
    }

    func testEmptyNotesCannotBeCreatedAndStoredEmptyNotesAreRemovedOnLoad() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let store = try NoteStore(persistenceURL: fixture.notesURL)
        XCTAssertThrowsError(try store.createNote(content: " \n\t")) { error in
            XCTAssertEqual(error as? NoteStoreError, .emptyNoteCannotBePersisted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.notesURL.path))

        let group = MemoEdgeGroup(edge: .right)
        let empty = MemoNote(
            title: "빈 메모",
            content: "",
            placement: MemoPlacement(groupID: group.id, order: 0)
        )
        try fixture.writeEnvelope(
            NoteStoreEnvelope(notes: [empty], edgeGroups: [group], defaultGroupID: group.id)
        )
        let reloaded = try NoteStore(persistenceURL: fixture.notesURL)
        XCTAssertTrue(reloaded.notes.isEmpty)
        XCTAssertTrue(try fixture.readEnvelope().notes.isEmpty)
    }

    func testActiveCapacityIsEnforcedForCreateAndRestore() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        var tick = 0.0
        let store = try NoteStore(
            persistenceURL: fixture.notesURL,
            now: {
                defer { tick += 1 }
                return Date(timeIntervalSince1970: tick)
            }
        )
        let first = try store.createNote(content: "첫 메모")
        XCTAssertTrue(NoteColor.memoPalette.contains(first.color))
        XCTAssertNotEqual(first.color, .black)
        for index in 1..<NoteStore.maxActiveNotes { try store.createNote(content: "메모 \(index)") }

        XCTAssertThrowsError(try store.createNote(content: "거절될 메모")) { error in
            XCTAssertEqual(error as? NoteStoreError, .activeCapacityReached)
        }
        XCTAssertTrue(store.setActive(noteID: first.id, isActive: false))
        let replacement = try store.createNote(content: "새 활성 메모")
        XCTAssertFalse(store.setActive(noteID: first.id, isActive: true))
        XCTAssertTrue(store.setActive(noteID: replacement.id, isActive: false))
        XCTAssertTrue(store.setActive(noteID: first.id, isActive: true))
        XCTAssertEqual(store.activeNotes().count, NoteStore.maxActiveNotes)
    }

    func testCapacityRejectionDoesNotReuseAnOlderPersistenceError() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }
        let group = MemoEdgeGroup(edge: .right)
        let active = (0..<NoteStore.maxActiveNotes).map { index in
            MemoNote(
                title: "활성 \(index)",
                content: "본문 \(index)",
                placement: MemoPlacement(groupID: group.id, order: index)
            )
        }
        let archived = MemoNote(
            title: "보관",
            content: "보관 본문",
            isActive: false,
            placement: MemoPlacement(groupID: group.id, order: active.count)
        )
        try fixture.writeEnvelope(
            NoteStoreEnvelope(
                notes: active + [archived],
                edgeGroups: [group],
                defaultGroupID: group.id
            )
        )
        let store = try NoteStore(persistenceURL: fixture.notesURL)

        try FileManager.default.removeItem(at: fixture.notesURL)
        try FileManager.default.createDirectory(at: fixture.notesURL, withIntermediateDirectories: false)
        store.updateContent(noteID: active[0].id, content: "저장 실패 유도")
        XCTAssertNotNil(store.lastPersistenceError)

        XCTAssertFalse(store.setActive(noteID: archived.id, isActive: true))
        XCTAssertNil(store.lastPersistenceError)
    }

    func testUndoingToPersistedContentClearsAnOlderPersistenceError() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }
        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let note = try store.createNote(content: "원래 본문")

        try FileManager.default.removeItem(at: fixture.notesURL)
        try FileManager.default.createDirectory(at: fixture.notesURL, withIntermediateDirectories: false)
        store.updateContent(noteID: note.id, content: "저장 실패 본문")
        XCTAssertNotNil(store.lastPersistenceError)

        store.updateContent(noteID: note.id, content: note.content)
        XCTAssertNil(store.lastPersistenceError)
    }

    func testReloadPreservesV3FieldsAndRemovesLegacyPosition() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let note = try store.createNote(
            title: "재로딩확인",
            content: "본문",
            color: .green,
            aspectRatio: .square,
            opacity: 0.43,
            attachments: [MemoAttachment(fileName: "stored-image.png", originalName: "image.png")]
        )
        XCTAssertTrue(
            store.placeNote(
                noteID: note.id,
                edge: .top,
                normalizedCenter: 0.7,
                mergeInto: nil,
                order: 0
            )
        )
        store.updateAppearance(
            noteID: note.id,
            color: .purple,
            textColorHex: "#123456",
            aspectRatio: .portrait,
            opacity: 0.6
        )
        store.updatePanelWidth(noteID: note.id, width: 512)

        let reloaded = try NoteStore(persistenceURL: fixture.notesURL)
        let saved = try XCTUnwrap(reloaded.note(withID: note.id))
        XCTAssertEqual(reloaded.group(withID: saved.placement.groupID)?.edge, .top)
        XCTAssertEqual(saved.aspectRatio, .portrait)
        XCTAssertEqual(saved.opacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(saved.color, .purple)
        XCTAssertEqual(saved.textColorHex, "#123456")
        XCTAssertEqual(saved.panelSize?.cgSize.width ?? 0, 512, accuracy: 0.001)
        XCTAssertEqual(saved.panelSize?.cgSize.height ?? 0, MemoPanelSize.minimum.height, accuracy: 0.001)
        XCTAssertTrue(saved.isTitleExplicit)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.notesURL)) as? [String: Any]
        )
        let encodedNote = try XCTUnwrap((json["notes"] as? [[String: Any]])?.first)
        XCTAssertNotNil(encodedNote["placement"])
        XCTAssertNotNil(encodedNote["panelSize"])
        XCTAssertEqual(encodedNote["isTitleExplicit"] as? Bool, true)
        XCTAssertNil(encodedNote["handlePosition"])
        XCTAssertNotNil(json["edgeGroups"])
        XCTAssertNotNil(json["defaultGroupID"])
    }

    func testLegacyAspectRatioChangeKeepsManualIceWidth() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }

        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let note = try store.createNote(content: "크기 재설정")
        store.updatePanelWidth(noteID: note.id, width: 520)
        XCTAssertNotNil(store.note(withID: note.id)?.panelSize)

        store.updateAppearance(noteID: note.id, aspectRatio: .square)

        XCTAssertEqual(store.note(withID: note.id)?.panelSize?.cgSize.width, 520)
        XCTAssertEqual(store.note(withID: note.id)?.aspectRatio, .square)
    }

    func testAttachToDefaultRemovesUnusedManualGroup() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }
        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let note = try store.createNote(content: "이동")

        XCTAssertTrue(store.placeNote(noteID: note.id, edge: .left, normalizedCenter: 0.2, mergeInto: nil, order: 0))
        let manualID = try XCTUnwrap(store.note(withID: note.id)?.placement.groupID)
        XCTAssertNotEqual(manualID, store.defaultGroupID)
        XCTAssertTrue(store.attachToDefaultGroup(noteID: note.id))
        XCTAssertEqual(store.note(withID: note.id)?.placement.groupID, store.defaultGroupID)
        XCTAssertNotNil(store.group(withID: manualID))
        XCTAssertLessThanOrEqual(store.edgeGroups.filter { $0.edge == .left }.count, 1)
    }

    func testGlobalIndexOrderFlattensActiveNotesWithoutChangingContent() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }
        let store = try NoteStore(persistenceURL: fixture.notesURL)
        let first = try store.createNote(title: "첫째", content: "첫 본문")
        let second = try store.createNote(title: "둘째", content: "둘째 본문")
        let third = try store.createNote(title: "셋째", content: "셋째 본문")
        XCTAssertTrue(store.placeNote(noteID: second.id, edge: .top, normalizedCenter: 0.5, mergeInto: nil, order: 0))

        XCTAssertTrue(store.setGlobalIndexOrder([third.id, first.id, second.id]))

        let ordered = store.activeNotes().sorted { $0.placement.order < $1.placement.order }
        XCTAssertEqual(ordered.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(ordered.map(\.content), ["셋째 본문", "첫 본문", "둘째 본문"])
        XCTAssertTrue(ordered.allSatisfy { $0.placement.groupID == store.defaultGroupID })
        XCTAssertNotEqual(store.defaultGroup.edge, .top)
    }

    func testTitleDerivationAndMeaningfulContentDetection() {
        XCTAssertEqual(
            MemoNote.deriveTitle(from: "\n  \n### **오늘 할 일 정리**", fallbackIndex: 3),
            "오늘 할 일 정리"
        )
        let legacyTitle = MemoNote(
            title: "메모돌멩 수",
            content: "# [메모돌멩 수정사항]\n본문",
            placement: MemoPlacement(groupID: UUID(), order: 0)
        )
        XCTAssertEqual(legacyTitle.displayTitle, "메모돌멩 수정사항")

        let explicitTitle = MemoNote(
            title: "메모돌멩 수",
            isTitleExplicit: true,
            content: "# [메모돌멩 수정사항]\n본문",
            placement: MemoPlacement(groupID: UUID(), order: 0)
        )
        XCTAssertEqual(explicitTitle.displayTitle, "메모돌멩 수")
        XCTAssertEqual(MemoNote.deriveTitle(from: "```\n---", fallbackIndex: 3), "메모3")
        XCTAssertFalse(MemoNote.hasMeaningfulContent(" \n\t\u{200B}"))
        XCTAssertTrue(MemoNote.hasMeaningfulContent("- [ ]"))
        XCTAssertTrue(MemoNote.hasMeaningfulContent("![이미지](memodolmaeng-asset://id/image.png)"))
    }

    func testRandomMemoColorUsesVisiblePaletteAndExcludesRequestedColor() {
        for _ in 0..<50 {
            let color = NoteColor.randomMemoColor(excluding: .yellow)
            XCTAssertTrue(NoteColor.memoPalette.contains(color))
            XCTAssertNotEqual(color, .yellow)
            XCTAssertNotEqual(color, .black)
            XCTAssertNotEqual(color, .white)
        }
    }

    func testInitializerThrowsForUnreadablePersistenceData() throws {
        let fixture = try TemporaryStoreFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.notesURL)
        XCTAssertThrowsError(try NoteStore(persistenceURL: fixture.notesURL))
    }
}

private struct V2NoteFixture: Codable {
    let id: UUID
    let title: String
    let content: String
    let color: NoteColor
    let textColorHex: String
    let isActive: Bool
    let handlePosition: Double
    let aspectRatio: MemoAspectRatio
    let opacity: Double
    let attachments: [MemoAttachment]
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        color: NoteColor = .black,
        textColorHex: String = "#FFFFFF",
        isActive: Bool = true,
        handlePosition: Double = 0.5,
        aspectRatio: MemoAspectRatio = .portrait,
        opacity: Double = 1,
        attachments: [MemoAttachment] = [],
        createdAt: Date = Date(timeIntervalSince1970: 1_600_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.color = color
        self.textColorHex = textColorHex
        self.isActive = isActive
        self.handlePosition = handlePosition
        self.aspectRatio = aspectRatio
        self.opacity = opacity
        self.attachments = attachments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct V2EnvelopeFixture: Codable {
    let schemaVersion: Int
    let notes: [V2NoteFixture]

    init(notes: [V2NoteFixture]) {
        schemaVersion = 2
        self.notes = notes
    }
}

private struct LegacyNoteFixture: Codable {
    let id: UUID
    var content: String
    var frame: NoteFrame
    var isVisible: Bool
    var color: NoteColor
    var floatsOnTop: Bool
    var isTranslucent: Bool
    var usesAutomaticHeight: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        frame: NoteFrame = NoteFrame(x: 100, y: 100, width: 300, height: 400),
        isVisible: Bool = true,
        color: NoteColor = .black,
        floatsOnTop: Bool = false,
        isTranslucent: Bool = false,
        usesAutomaticHeight: Bool = true,
        createdAt: Date = Date(timeIntervalSince1970: 1_600_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.id = id
        self.content = content
        self.frame = frame
        self.isVisible = isVisible
        self.color = color
        self.floatsOnTop = floatsOnTop
        self.isTranslucent = isTranslucent
        self.usesAutomaticHeight = usesAutomaticHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func empty(updatedAt: Date) -> LegacyNoteFixture {
        LegacyNoteFixture(content: " \n\t", isVisible: false, updatedAt: updatedAt)
    }
}

private final class TemporaryStoreFixture {
    let directory: URL
    let notesURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengTests-\(UUID().uuidString)", isDirectory: true)
        notesURL = directory.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func writeLegacy(_ notes: [LegacyNoteFixture]) throws -> Data {
        try write(notes)
    }

    @discardableResult
    func writeV2(_ notes: [V2NoteFixture]) throws -> Data {
        try write(V2EnvelopeFixture(notes: notes))
    }

    func writeEnvelope(_ envelope: NoteStoreEnvelope) throws {
        _ = try write(envelope)
    }

    func readEnvelope() throws -> NoteStoreEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NoteStoreEnvelope.self, from: Data(contentsOf: notesURL))
    }

    func backups() throws -> [URL] {
        let directory = directory.appendingPathComponent("Backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: notesURL)
        return data
    }
}
