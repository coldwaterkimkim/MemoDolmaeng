import Foundation

@MainActor
final class NoteStore {
    private(set) var notes: [MemoNote] = []
    let persistenceURL: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storageDirectory = applicationSupport.appendingPathComponent("MemoDolmaeng", isDirectory: true)

        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        persistenceURL = storageDirectory.appendingPathComponent("notes.json")
        load()
    }

    @discardableResult
    func createNote(frame: NoteFrame, color: NoteColor = .black, usesAutomaticHeight: Bool = true) -> MemoNote {
        let note = MemoNote(frame: frame, color: color, usesAutomaticHeight: usesAutomaticHeight)
        notes.append(note)
        save()
        return note
    }

    func note(withID id: UUID) -> MemoNote? {
        notes.first { $0.id == id }
    }

    func visibleNotes() -> [MemoNote] {
        notes.filter(\.isVisible)
    }

    func updateContent(noteID: UUID, content: String) {
        update(noteID: noteID) { note in
            guard note.content != content else { return }
            note.content = content
            note.updatedAt = Date()
        }
    }

    func updateRichContent(noteID: UUID, content: String, richTextData: Data?) {
        update(noteID: noteID) { note in
            guard note.content != content || note.richTextData != richTextData else { return }
            note.content = content
            note.richTextData = richTextData
            note.updatedAt = Date()
        }
    }

    func updateFrame(noteID: UUID, frame: NoteFrame) {
        update(noteID: noteID) { note in
            guard note.frame != frame else { return }
            note.frame = frame
            note.updatedAt = Date()
        }
    }

    func setVisibility(noteID: UUID, isVisible: Bool) {
        update(noteID: noteID) { note in
            guard note.isVisible != isVisible else { return }
            note.isVisible = isVisible
            note.updatedAt = Date()
        }
    }

    func setColor(noteID: UUID, color: NoteColor) {
        update(noteID: noteID) { note in
            guard note.color != color else { return }
            note.color = color
            note.updatedAt = Date()
        }
    }

    func setFloatsOnTop(noteID: UUID, floatsOnTop: Bool) {
        update(noteID: noteID) { note in
            guard note.floatsOnTop != floatsOnTop else { return }
            note.floatsOnTop = floatsOnTop
            note.updatedAt = Date()
        }
    }

    func setTranslucent(noteID: UUID, isTranslucent: Bool) {
        update(noteID: noteID) { note in
            guard note.isTranslucent != isTranslucent else { return }
            note.isTranslucent = isTranslucent
            note.updatedAt = Date()
        }
    }

    func setUsesAutomaticHeight(noteID: UUID, usesAutomaticHeight: Bool) {
        update(noteID: noteID) { note in
            guard note.usesAutomaticHeight != usesAutomaticHeight else { return }
            note.usesAutomaticHeight = usesAutomaticHeight
            note.updatedAt = Date()
        }
    }

    func deleteNote(noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes.remove(at: index)
        save()
    }

    func showAll() {
        guard notes.contains(where: { !$0.isVisible }) else { return }

        for index in notes.indices {
            notes[index].isVisible = true
            notes[index].updatedAt = Date()
        }

        save()
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(notes)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            NSLog("MemoDolmaeng failed to save notes: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            notes = []
            return
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([MemoNote].self, from: data)
        } catch {
            NSLog("MemoDolmaeng failed to load notes: \(error.localizedDescription)")
            notes = []
        }
    }

    private func update(noteID: UUID, mutation: (inout MemoNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        mutation(&notes[index])
        save()
    }
}
