import AppKit

@MainActor
final class WindowManager {
    private let store: NoteStore
    private var controllers: [UUID: NoteWindowController] = [:]
    private var isTerminating = false

    init(store: NoteStore) {
        self.store = store
    }

    func openInitialWindows() {
        if store.notes.isEmpty {
            createNote()
            return
        }

        let notesToOpen = store.visibleNotes().isEmpty ? Array(store.notes.prefix(1)) : store.visibleNotes()

        for note in notesToOpen {
            store.setVisibility(noteID: note.id, isVisible: true)
            open(noteID: note.id)
        }
    }

    func createNote() {
        let note = store.createNote(
            frame: nextDefaultFrame(),
            color: .black,
            usesAutomaticHeight: true
        )
        open(noteID: note.id)
    }

    func showAllNotes() {
        store.showAll()

        for note in store.notes {
            open(noteID: note.id)
        }
    }

    func bringVisibleNotesToFront() {
        for note in store.visibleNotes() {
            open(noteID: note.id)
        }

        let visibleControllers = store.visibleNotes().compactMap { controllers[$0.id] }
        for controller in visibleControllers.dropLast() {
            controller.bringToFront(makeKey: false)
        }

        visibleControllers.last?.bringToFront(makeKey: true)
    }

    func applyPreferencesToOpenWindows() {
        for controller in controllers.values {
            controller.applyPreferences()
        }
    }

    func closeCurrentNote() {
        currentController()?.closeNote()
    }

    func closeAllNotes() {
        for controller in Array(controllers.values) {
            controller.closeNote()
        }
    }

    func setCurrentNoteColor(_ color: NoteColor) {
        currentController()?.setColor(color)
    }

    func toggleCurrentNoteFloatOnTop() {
        currentController()?.toggleFloatsOnTop()
    }

    func toggleCurrentNoteTranslucent() {
        currentController()?.toggleTranslucent()
    }

    func currentNoteFloatsOnTop() -> Bool {
        currentController()?.floatsOnTop ?? false
    }

    func currentNoteIsTranslucent() -> Bool {
        currentController()?.isTranslucent ?? false
    }

    func currentNoteColor() -> NoteColor? {
        currentController()?.color
    }

    func prepareForTermination() {
        isTerminating = true
        store.save()
    }

    private func open(noteID: UUID) {
        if let controller = controllers[noteID] {
            controller.show()
            return
        }

        guard var note = store.note(withID: noteID) else { return }
        note.frame = normalizedFrame(for: compactedLegacyFrame(note.frame))

        let controller = NoteWindowController(
            note: note,
            store: store,
            onFrameChange: { [weak self] noteID, frame in
                self?.store.updateFrame(noteID: noteID, frame: NoteFrame(rect: frame))
            },
            onClose: { [weak self] noteID, frame in
                self?.handleClose(noteID: noteID, frame: frame)
            },
            onDelete: { [weak self] noteID in
                self?.handleDelete(noteID: noteID)
            },
            onFloatChange: { [weak self] noteID, floatsOnTop in
                self?.store.setFloatsOnTop(noteID: noteID, floatsOnTop: floatsOnTop)
            },
            onTranslucentChange: { [weak self] noteID, isTranslucent in
                self?.store.setTranslucent(noteID: noteID, isTranslucent: isTranslucent)
            },
            onAutomaticHeightChange: { [weak self] noteID, usesAutomaticHeight in
                self?.store.setUsesAutomaticHeight(noteID: noteID, usesAutomaticHeight: usesAutomaticHeight)
            }
        )

        controllers[noteID] = controller
        store.setVisibility(noteID: noteID, isVisible: true)
        store.updateFrame(noteID: noteID, frame: note.frame)
        controller.show()
    }

    private func handleClose(noteID: UUID, frame: CGRect) {
        store.updateFrame(noteID: noteID, frame: NoteFrame(rect: frame))

        if !isTerminating {
            store.setVisibility(noteID: noteID, isVisible: false)
        }

        controllers[noteID] = nil
    }

    private func handleDelete(noteID: UUID) {
        controllers[noteID] = nil
        store.deleteNote(noteID: noteID)
    }

    private func nextDefaultFrame() -> NoteFrame {
        let visibleFrame = activeScreen().visibleFrame
        let noteSize = CGSize(
            width: NoteWindowMetrics.automaticWidth,
            height: NoteWindowMetrics.minimumAutomaticHeight
        )
        let offset = CGFloat((store.notes.count % 8) * 22)
        let x = visibleFrame.minX + 48 + offset
        let y = visibleFrame.maxY - noteSize.height - 56 - offset

        return NoteFrame(x: x, y: y, width: noteSize.width, height: noteSize.height)
    }

    private func normalizedFrame(for frame: NoteFrame) -> NoteFrame {
        let rect = frame.rect
        let intersectsVisibleScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(rect)
        }

        if intersectsVisibleScreen {
            return frame
        }

        return nextDefaultFrame()
    }

    private func compactedLegacyFrame(_ frame: NoteFrame) -> NoteFrame {
        let wasMVPDefaultSize = (
            abs(frame.width - 360) < 1 && abs(frame.height - 300) < 1
        ) || (
            abs(frame.width - 280) < 1 && abs(frame.height - 220) < 1
        )

        guard wasMVPDefaultSize else {
            return frame
        }

        return NoteFrame(x: frame.x, y: frame.y - 237, width: 300, height: 457)
    }

    private func currentController() -> NoteWindowController? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.orderedWindows

        for window in candidateWindows {
            if let controller = window.windowController as? NoteWindowController {
                return controller
            }
        }

        return controllers.values.first
    }

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }

        if let mainScreen = NSScreen.main {
            return mainScreen
        }

        return NSScreen.screens[0]
    }
}
