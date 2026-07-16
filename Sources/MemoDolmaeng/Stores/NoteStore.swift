import Foundation

struct NoteStoreEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    var notes: [MemoNote]
    var edgeGroups: [MemoEdgeGroup]
    var defaultGroupID: UUID

    init(
        schemaVersion: Int = currentSchemaVersion,
        notes: [MemoNote],
        edgeGroups: [MemoEdgeGroup],
        defaultGroupID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.edgeGroups = edgeGroups
        self.defaultGroupID = defaultGroupID
    }
}

enum NoteStoreError: Error, Equatable {
    case activeCapacityReached
    case emptyNoteCannotBePersisted
    case unsupportedSchemaVersion(Int)
}

@MainActor
final class NoteStore {
    static let maxActiveNotes = 10

    private(set) var notes: [MemoNote] = []
    private(set) var edgeGroups: [MemoEdgeGroup] = []
    private(set) var defaultGroupID = UUID()
    private(set) var lastPersistenceError: Error?
    let persistenceURL: URL

    private let fileManager: FileManager
    private let now: () -> Date

    convenience init(fileManager: FileManager = .default) throws {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storageDirectory = applicationSupport.appendingPathComponent("MemoDolmaeng", isDirectory: true)
        try self.init(
            persistenceURL: storageDirectory.appendingPathComponent("notes.json"),
            fileManager: fileManager
        )
    }

    convenience init(storageURL: URL, fileManager: FileManager = .default) throws {
        try self.init(persistenceURL: storageURL, fileManager: fileManager)
    }

    init(
        persistenceURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.persistenceURL = persistenceURL
        self.fileManager = fileManager
        self.now = now

        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try load()
    }

    func note(withID id: UUID) -> MemoNote? {
        notes.first { $0.id == id }
    }

    func group(withID id: UUID) -> MemoEdgeGroup? {
        edgeGroups.first { $0.id == id }
    }

    var defaultGroup: MemoEdgeGroup {
        edgeGroups.first { $0.id == defaultGroupID }
            ?? MemoEdgeGroup(id: defaultGroupID, edge: .right, createdAt: now())
    }

    func activeNotes() -> [MemoNote] {
        notes.filter(\.isActive)
    }

    @discardableResult
    func createNote(
        id: UUID = UUID(),
        title: String? = nil,
        content: String,
        color: NoteColor? = nil,
        textColorHex: String? = nil,
        placement: MemoPlacement? = nil,
        aspectRatio: MemoAspectRatio = .portrait,
        opacity: Double = 1,
        attachments: [MemoAttachment] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) throws -> MemoNote {
        guard activeNotes().count < Self.maxActiveNotes else {
            throw NoteStoreError.activeCapacityReached
        }
        guard MemoNote.hasMeaningfulContent(content) else {
            throw NoteStoreError.emptyNoteCannotBePersisted
        }

        let timestamp = createdAt ?? now()
        let resolvedPlacement = placement ?? MemoPlacement(
            groupID: defaultGroupID,
            order: nextOrder(in: defaultGroupID)
        )
        let note = MemoNote(
            id: id,
            title: title ?? MemoNote.deriveTitle(from: content, fallbackIndex: nextFallbackTitleIndex()),
            isTitleExplicit: title != nil,
            content: content,
            color: color ?? NoteColor.randomMemoColor(excluding: notes.last?.color),
            textColorHex: textColorHex,
            isActive: true,
            placement: resolvedPlacement,
            aspectRatio: aspectRatio,
            opacity: opacity,
            attachments: attachments,
            createdAt: timestamp,
            updatedAt: updatedAt ?? timestamp
        )
        guard commit(notes: notes + [note], groups: edgeGroups, defaultGroupID: defaultGroupID) else {
            throw lastPersistenceError ?? CocoaError(.fileWriteUnknown)
        }
        return note
    }

    @discardableResult
    func commitDraft(_ note: MemoNote, adding group: MemoEdgeGroup? = nil) throws -> MemoNote {
        guard activeNotes().count < Self.maxActiveNotes else {
            throw NoteStoreError.activeCapacityReached
        }
        guard MemoNote.hasMeaningfulContent(note.content) else {
            throw NoteStoreError.emptyNoteCannotBePersisted
        }
        guard self.note(withID: note.id) == nil else { return note }
        var groups = edgeGroups
        if let group, !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        guard commit(notes: notes + [note], groups: groups, defaultGroupID: defaultGroupID) else {
            throw lastPersistenceError ?? CocoaError(.fileWriteUnknown)
        }
        return note
    }

    func updateContent(noteID: UUID, content: String) {
        guard MemoNote.hasMeaningfulContent(content) else { return }
        mutate(noteID: noteID) { note in
            guard note.content != content else { return false }
            note.content = content
            note.updatedAt = now()
            return true
        }
    }

    func updateTitle(noteID: UUID, title: String) {
        mutate(noteID: noteID) { note in
            var updated = note
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.title = trimmed.isEmpty
                ? MemoNote.deriveTitle(from: note.content, fallbackIndex: 1)
                : trimmed
            updated.isTitleExplicit = !trimmed.isEmpty
            guard note.title != updated.title || note.isTitleExplicit != updated.isTitleExplicit else {
                return false
            }
            note = updated
            note.updatedAt = now()
            return true
        }
    }

    func updateAppearance(
        noteID: UUID,
        color: NoteColor? = nil,
        textColorHex: String? = nil,
        aspectRatio: MemoAspectRatio? = nil,
        opacity: Double? = nil
    ) {
        mutate(noteID: noteID) { note in
            var updated = note
            if let color { updated.color = color }
            if let textColorHex { updated.textColorHex = textColorHex }
            if let aspectRatio {
                updated.aspectRatio = aspectRatio
                updated.panelSize = nil
            }
            if let opacity { updated.opacity = opacity }
            guard updated != note else { return false }
            updated.updatedAt = now()
            note = updated
            return true
        }
    }

    func updatePanelSize(noteID: UUID, size: CGSize) {
        mutate(noteID: noteID) { note in
            var updated = note
            updated.panelSize = MemoPanelSize(size)
            guard updated != note else { return false }
            updated.updatedAt = now()
            note = updated
            return true
        }
    }

    func appendAttachment(noteID: UUID, attachment: MemoAttachment) {
        mutate(noteID: noteID) { note in
            guard !note.attachments.contains(where: { $0.id == attachment.id }) else { return false }
            note.attachments.append(attachment)
            note.updatedAt = now()
            return true
        }
    }

    @discardableResult
    func setActive(noteID: UUID, isActive: Bool) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        guard notes[index].isActive != isActive else { return true }
        if isActive && activeNotes().count >= Self.maxActiveNotes { return false }

        var updatedNotes = notes
        updatedNotes[index].isActive = isActive
        if isActive {
            if group(withID: updatedNotes[index].placement.groupID) == nil {
                updatedNotes[index].placement.groupID = defaultGroupID
            }
            updatedNotes[index].placement.order = nextOrder(
                in: updatedNotes[index].placement.groupID,
                notes: updatedNotes.filter { $0.id != noteID && $0.isActive }
            )
        }
        updatedNotes[index].updatedAt = now()
        return commit(notes: updatedNotes, groups: edgeGroups, defaultGroupID: defaultGroupID)
    }

    @discardableResult
    func deleteNote(noteID: UUID) -> Bool {
        guard notes.contains(where: { $0.id == noteID }) else { return false }
        return commit(
            notes: notes.filter { $0.id != noteID },
            groups: edgeGroups,
            defaultGroupID: defaultGroupID
        )
    }

    @discardableResult
    func placeNote(
        noteID: UUID,
        edge: EdgeDock,
        normalizedCenter: Double,
        mergeInto targetGroupID: UUID?,
        order: Int
    ) -> Bool {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        var updatedNotes = notes
        var updatedGroups = edgeGroups
        let sourceGroupID = updatedNotes[noteIndex].placement.groupID
        let targetGroup: MemoEdgeGroup

        if let targetGroupID,
           let existing = updatedGroups.first(where: { $0.id == targetGroupID && $0.edge == edge }) {
            targetGroup = existing
        } else if sourceGroupID != defaultGroupID,
                  updatedNotes.filter({ $0.placement.groupID == sourceGroupID }).count == 1,
                  let sourceIndex = updatedGroups.firstIndex(where: { $0.id == sourceGroupID }) {
            updatedGroups[sourceIndex].edge = edge
            updatedGroups[sourceIndex].normalizedCenter = normalizedCenter
            targetGroup = updatedGroups[sourceIndex]
        } else {
            let created = MemoEdgeGroup(
                edge: edge,
                normalizedCenter: normalizedCenter,
                createdAt: now()
            )
            updatedGroups.append(created)
            targetGroup = created
        }

        let insertionOrder = max(0, order)
        for index in updatedNotes.indices where updatedNotes[index].id != noteID
            && updatedNotes[index].placement.groupID == targetGroup.id
            && updatedNotes[index].placement.order >= insertionOrder {
            updatedNotes[index].placement.order += 1
        }
        updatedNotes[noteIndex].placement = MemoPlacement(groupID: targetGroup.id, order: insertionOrder)
        updatedNotes[noteIndex].updatedAt = now()

        return commit(notes: updatedNotes, groups: updatedGroups, defaultGroupID: defaultGroupID)
    }

    @discardableResult
    func attachToDefaultGroup(noteID: UUID) -> Bool {
        placeNote(
            noteID: noteID,
            edge: defaultGroup.edge,
            normalizedCenter: defaultGroup.normalizedCenter,
            mergeInto: defaultGroupID,
            order: nextOrder(in: defaultGroupID)
        )
    }

    func setDefaultEdge(_ edge: EdgeDock) {
        guard let index = edgeGroups.firstIndex(where: { $0.id == defaultGroupID }),
              edgeGroups[index].edge != edge
        else { return }
        var updatedGroups = edgeGroups
        updatedGroups[index].edge = edge
        _ = commit(notes: notes, groups: updatedGroups, defaultGroupID: defaultGroupID)
    }

    func save() {
        do {
            try writeEnvelope(currentEnvelope())
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
            NSLog("MemoDolmaeng failed to save notes: \(error.localizedDescription)")
        }
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: persistenceURL.path) else {
            installEmptyStore()
            return
        }

        let data = try Data(contentsOf: persistenceURL)
        let decoder = makeDecoder()

        if let header = try? decoder.decode(SchemaHeader.self, from: data) {
            switch header.schemaVersion {
            case NoteStoreEnvelope.currentSchemaVersion:
                let stored = try decoder.decode(NoteStoreEnvelope.self, from: data)
                let normalized = normalizedEnvelope(stored)
                install(normalized)
                if normalized != stored { try writeEnvelope(normalized) }
                return
            case 2:
                let stored = try decoder.decode(V2NoteStoreEnvelope.self, from: data)
                let migrated = migrateV2(stored.notes)
                try backupPreV3Data(data)
                try writeEnvelope(migrated)
                install(migrated)
                return
            default:
                throw NoteStoreError.unsupportedSchemaVersion(header.schemaVersion)
            }
        }

        let legacyNotes = try decoder.decode([LegacyMemoNote].self, from: data)
        let migrated = migrateLegacy(legacyNotes)
        try backupPreV3Data(data)
        try writeEnvelope(migrated)
        install(migrated)
    }

    private func installEmptyStore() {
        let group = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5, createdAt: now())
        notes = []
        edgeGroups = [group]
        defaultGroupID = group.id
    }

    private func migrateV2(_ storedNotes: [V2MemoNote]) -> NoteStoreEnvelope {
        let contentNotes = storedNotes.filter { MemoNote.hasMeaningfulContent($0.content) }
        let activeOrder = contentNotes
            .filter(\.isActive)
            .sorted {
                if $0.handlePosition != $1.handlePosition { return $0.handlePosition > $1.handlePosition }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        let orderedIDs = activeOrder.map(\.id) + contentNotes.filter { !$0.isActive }.map(\.id)
        let orderMap = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        let group = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5, createdAt: now())

        let migrated = contentNotes.map { note in
            MemoNote(
                id: note.id,
                title: note.title,
                content: note.content,
                color: note.color,
                textColorHex: note.textColorHex,
                isActive: note.isActive,
                placement: MemoPlacement(groupID: group.id, order: orderMap[note.id] ?? 0),
                aspectRatio: note.aspectRatio,
                opacity: note.opacity,
                attachments: note.attachments,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt
            )
        }
        return normalizedEnvelope(NoteStoreEnvelope(notes: migrated, edgeGroups: [group], defaultGroupID: group.id))
    }

    private func migrateLegacy(_ legacyNotes: [LegacyMemoNote]) -> NoteStoreEnvelope {
        let imported = legacyNotes.filter { MemoNote.hasMeaningfulContent($0.content) }
        let prioritized = imported.sorted {
            if $0.isVisible != $1.isVisible { return $0.isVisible && !$1.isVisible }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let active = Array(prioritized.prefix(Self.maxActiveNotes))
        let activeIDs = Set(active.map(\.id))
        let inactive = imported.filter { !activeIDs.contains($0.id) }
        let orderedIDs = active.map(\.id) + inactive.map(\.id)
        let orderMap = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        let group = MemoEdgeGroup(edge: .right, normalizedCenter: 0.5, createdAt: now())

        let migrated = imported.enumerated().map { index, legacyNote in
            let ratio = legacyNote.frame.height > 0
                ? legacyNote.frame.width / legacyNote.frame.height
                : 1
            return MemoNote(
                id: legacyNote.id,
                title: MemoNote.deriveTitle(from: legacyNote.content, fallbackIndex: index + 1),
                content: legacyNote.content,
                color: legacyNote.color,
                textColorHex: MemoNote.defaultTextColorHex(for: legacyNote.color),
                isActive: activeIDs.contains(legacyNote.id),
                placement: MemoPlacement(groupID: group.id, order: orderMap[legacyNote.id] ?? index),
                aspectRatio: .closest(to: ratio),
                opacity: legacyNote.isTranslucent ? MemoNote.translucentOpacity : 1,
                attachments: [],
                createdAt: legacyNote.createdAt,
                updatedAt: legacyNote.updatedAt
            )
        }
        return normalizedEnvelope(NoteStoreEnvelope(notes: migrated, edgeGroups: [group], defaultGroupID: group.id))
    }

    private func normalizedEnvelope(_ envelope: NoteStoreEnvelope) -> NoteStoreEnvelope {
        var groupsByID: [UUID: MemoEdgeGroup] = [:]
        for var group in envelope.edgeGroups where groupsByID[group.id] == nil {
            group.normalize()
            groupsByID[group.id] = group
        }

        let defaultID = envelope.defaultGroupID
        if groupsByID[defaultID] == nil {
            groupsByID[defaultID] = MemoEdgeGroup(
                id: defaultID,
                edge: .right,
                normalizedCenter: 0.5,
                createdAt: now()
            )
        }

        var result = envelope.notes.filter { MemoNote.hasMeaningfulContent($0.content) }
        for index in result.indices {
            result[index].normalize(fallbackIndex: index + 1)
            if groupsByID[result[index].placement.groupID] == nil {
                result[index].placement.groupID = defaultID
            }
        }

        let allowedActiveIDs = Set(
            result
                .filter(\.isActive)
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .prefix(Self.maxActiveNotes)
                .map(\.id)
        )
        for index in result.indices where result[index].isActive {
            result[index].isActive = allowedActiveIDs.contains(result[index].id)
        }

        for groupID in groupsByID.keys {
            let orderedIndices = result.indices
                .filter { result[$0].placement.groupID == groupID }
                .sorted {
                    let lhs = result[$0]
                    let rhs = result[$1]
                    if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                    if lhs.placement.order != rhs.placement.order { return lhs.placement.order < rhs.placement.order }
                    return lhs.createdAt < rhs.createdAt
                }
            for (order, index) in orderedIndices.enumerated() {
                result[index].placement.order = order
            }
        }

        let referencedGroupIDs = Set(result.map(\.placement.groupID)).union([defaultID])
        let groups = groupsByID.values
            .filter { referencedGroupIDs.contains($0.id) }
            .sorted {
                if $0.id == defaultID { return true }
                if $1.id == defaultID { return false }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        return NoteStoreEnvelope(notes: result, edgeGroups: groups, defaultGroupID: defaultID)
    }

    private func nextFallbackTitleIndex() -> Int {
        let used = Set(notes.compactMap { note -> Int? in
            guard note.title.hasPrefix("메모") else { return nil }
            return Int(note.title.dropFirst(2))
        })
        return (1...).first(where: { !used.contains($0) }) ?? notes.count + 1
    }

    private func nextOrder(in groupID: UUID, notes source: [MemoNote]? = nil) -> Int {
        let source = source ?? notes
        return (source.filter { $0.placement.groupID == groupID }.map(\.placement.order).max() ?? -1) + 1
    }

    private func mutate(noteID: UUID, mutation: (inout MemoNote) -> Bool) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        var updatedNotes = notes
        guard mutation(&updatedNotes[index]) else { return }
        updatedNotes[index].normalize(fallbackIndex: index + 1)
        _ = commit(notes: updatedNotes, groups: edgeGroups, defaultGroupID: defaultGroupID)
    }

    @discardableResult
    private func commit(notes: [MemoNote], groups: [MemoEdgeGroup], defaultGroupID: UUID) -> Bool {
        let normalized = normalizedEnvelope(
            NoteStoreEnvelope(notes: notes, edgeGroups: groups, defaultGroupID: defaultGroupID)
        )
        do {
            try writeEnvelope(normalized)
            install(normalized)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error
            NSLog("MemoDolmaeng failed to save notes: \(error.localizedDescription)")
            return false
        }
    }

    private func install(_ envelope: NoteStoreEnvelope) {
        notes = envelope.notes
        edgeGroups = envelope.edgeGroups
        defaultGroupID = envelope.defaultGroupID
    }

    private func currentEnvelope() -> NoteStoreEnvelope {
        NoteStoreEnvelope(notes: notes, edgeGroups: edgeGroups, defaultGroupID: defaultGroupID)
    }

    private func backupPreV3Data(_ data: Data) throws {
        let backupDirectory = persistenceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: now())
        var backupURL = backupDirectory.appendingPathComponent("notes-pre-edge-v3-\(timestamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: backupURL.path) {
            backupURL = backupDirectory.appendingPathComponent("notes-pre-edge-v3-\(timestamp)-\(suffix).json")
            suffix += 1
        }
        try data.write(to: backupURL, options: .atomic)
    }

    private func writeEnvelope(_ envelope: NoteStoreEnvelope) throws {
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try makeEncoder().encode(envelope)
        try data.write(to: persistenceURL, options: .atomic)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}

private struct V2NoteStoreEnvelope: Decodable {
    let schemaVersion: Int
    let notes: [V2MemoNote]
}

private struct V2MemoNote: Decodable {
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
}

private struct LegacyMemoNote: Decodable {
    let id: UUID
    let content: String
    let frame: NoteFrame
    let isVisible: Bool
    let color: NoteColor
    let isTranslucent: Bool
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case frame
        case isVisible
        case color
        case isTranslucent
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        frame = try container.decode(NoteFrame.self, forKey: .frame)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        color = try container.decodeIfPresent(NoteColor.self, forKey: .color) ?? .black
        isTranslucent = try container.decodeIfPresent(Bool.self, forKey: .isTranslucent) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
