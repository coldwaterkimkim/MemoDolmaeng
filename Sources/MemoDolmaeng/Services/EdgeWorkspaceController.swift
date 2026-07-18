import AppKit
import Combine
import Foundation

enum MemoRestoreResult: Equatable {
    case restored
    case capacityReached
    case failed
}

@MainActor
final class EdgeWorkspaceController: ObservableObject {
    @Published private(set) var notes: [MemoNote]
    @Published private(set) var presentationState = EdgePresentationState()
    @Published private(set) var indexVisibility: EdgeIndexVisibilityState = .hidden

    let store: NoteStore
    let preferences: EdgePreferences

    var onShowLibrary: (() -> Void)?
    var onPresentationChange: ((Bool) -> Void)?

    private let attachmentService: AttachmentService
    private let assetRootURL: URL
    private let hotZoneController = EdgeHotZoneController()
    private let deleteDropZoneController = DeleteDropZoneController()
    private var panelControllers: [UUID: MemoPanelController] = [:]
    private var handleControllers: [UUID: EdgeHandlePanelController] = [:]
    private var controlControllers: [EdgeDock: EdgeControlPanelController] = [:]
    private var layoutSnapshot: EdgeLayoutSnapshot = .empty
    private var pointerInsideHandles: Set<UUID> = []
    private var pointerInsideHotZones: Set<EdgeDock> = []
    private var pointerInsideControls: Set<EdgeDock> = []
    private var pendingEmptyNoteIDs: Set<UUID> = []
    private var iceEdges: [UUID: EdgeDock] = [:]
    private var launcherEdge: EdgeDock = .right
    private var launcherAnchorY: [EdgeDock: CGFloat] = [:]
    private var draftNote: MemoNote?
    private var draggingNoteID: UUID?
    private var revealTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var collapsingNoteIDs: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []

    init(store: NoteStore, preferences: EdgePreferences = .shared) {
        self.store = store
        self.preferences = preferences
        notes = store.notes

        let storageDirectory = store.persistenceURL.deletingLastPathComponent()
        attachmentService = AttachmentService(storageDirectory: storageDirectory)
        assetRootURL = storageDirectory.appendingPathComponent("attachments", isDirectory: true)
        attachmentService.reconcileStagedDeletions(existingNoteIDs: Set(store.notes.map(\.id)))
        hotZoneController.onPointerChange = { [weak self] edge, inside in
            self?.handleHotZonePointer(edge: edge, inside: inside)
        }
        launcherEdge = preferences.defaultEdge.interactiveSide
        for edge in EdgeDock.interactiveCases {
            controlControllers[edge] = EdgeControlPanelController(
                edge: edge,
                onCreate: { [weak self] in self?.createNote(on: edge) },
                onPointerChange: { [weak self] inside in
                    self?.handleControlPointer(edge: edge, inside: inside)
                }
            )
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshLayout() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .memoDolmaengEdgePreferencesChanged,
                object: preferences,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.setDefaultEdge(self.preferences.defaultEdge)
                    self.reloadNotes()
                    self.refreshLayout()
                }
            }
        )
    }

    deinit {
        revealTask?.cancel()
        hideTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        store.setDefaultEdge(preferences.defaultEdge)
        reloadNotes()
        refreshLayout()
    }

    func prepareForTermination() {
        let presentedIDs = Set(presentationState.iceNoteIDs).union(pendingEmptyNoteIDs)
        for noteID in presentedIDs { finalizeTransientState(noteID: noteID) }
        store.save()
    }

    func createNote() {
        createNote(on: preferences.defaultEdge)
    }

    func createNote(on edge: EdgeDock) {
        let side = edge.interactiveSide
        if let draftNote {
            open(noteID: draftNote.id, on: side, focusEditor: true)
            return
        }
        guard activeNotes.count < NoteStore.maxActiveNotes else {
            showCapacityAlert()
            return
        }

        let timestamp = Date()
        let placementGroupID = store.defaultGroupID
        draftNote = MemoNote(
            title: "새 메모",
            content: "",
            color: NoteColor.randomMemoColor(
                excluding: store.notes.max(by: { $0.updatedAt < $1.updatedAt })?.color
            ),
            isActive: true,
            placement: MemoPlacement(
                groupID: placementGroupID,
                order: nextOrder(in: placementGroupID)
            ),
            aspectRatio: .portrait,
            opacity: preferences.defaultOpacity,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        reloadNotes()
        refreshLayout()
        if let draftNote { open(noteID: draftNote.id, on: side, focusEditor: true) }
    }

    func handleClick(noteID: UUID, on edge: EdgeDock? = nil) {
        if presentationState.isIce(noteID) {
            closeMemo(noteID: noteID)
        } else {
            open(noteID: noteID, on: edge ?? launcherEdge, focusEditor: true)
        }
    }

    func handleDoubleClick(noteID: UUID, on edge: EdgeDock? = nil) {
        open(noteID: noteID, on: edge ?? launcherEdge, focusEditor: true)
    }

    func toggleRecent() {
        if let noteID = presentationState.focusedIceNoteID {
            closeMemo(noteID: noteID)
            return
        }
        let candidate = preferences.lastNoteID.flatMap(note(withID:)) ?? orderedActiveNotes.first
        if let candidate { open(noteID: candidate.id, on: preferences.defaultEdge, focusEditor: true) }
    }

    func toggleMode() {
        if let noteID = presentationState.focusedIceNoteID {
            closeMemo(noteID: noteID)
        }
    }

    func closeMemo(noteID requestedNoteID: UUID? = nil) {
        guard let closingID = requestedNoteID
            ?? presentationState.focusedIceNoteID
        else { return }
        let closingEdge = iceEdges[closingID] ?? preferences.defaultEdge.interactiveSide
        launcherEdge = closingEdge
        collapsingNoteIDs.insert(closingID)
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .close(closingID)
        )
        refreshLayout()
        if pointerInsideHotZones.isEmpty,
           pointerInsideHandles.isEmpty {
            indexVisibility = .transitioning(closingID)
        }
        refreshHandleSelection()
        let controller = panelControllers[closingID]
        controller?.fold(to: layoutSnapshot.handleFrames[closingID], beforeOrderOut: { [weak self] in
            self?.prepareIndexHandoff(noteID: closingID)
        }) { [weak self, weak controller] in
            guard let self else { return }
            self.collapsingNoteIDs.remove(closingID)
            if self.panelControllers[closingID] === controller {
                self.panelControllers.removeValue(forKey: closingID)
            }
            self.iceEdges.removeValue(forKey: closingID)
            self.refreshHandleSelection()
            if self.pointerInsideHotZones.isEmpty,
               self.pointerInsideHandles.isEmpty,
               self.pointerInsideControls.isEmpty,
               self.draggingNoteID == nil {
                self.indexVisibility = .hidden
                self.applyIndexVisibility()
            }
        }
        if controller == nil {
            collapsingNoteIDs.remove(closingID)
            iceEdges.removeValue(forKey: closingID)
        }
        finalizeTransientState(noteID: closingID)
        onPresentationChange?(presentationState.hasOpenPanels)
    }

    func cycleNote(direction: Int) {
        let ordered = orderedActiveNotes
        guard !ordered.isEmpty else { return }
        let currentIndex = presentationState.currentNoteID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let next = (currentIndex + direction + ordered.count) % ordered.count
        let side = presentationState.currentNoteID.flatMap { iceEdges[$0] } ?? preferences.defaultEdge
        open(noteID: ordered[next].id, on: side, focusEditor: true)
    }

    func selectNote(at index: Int) {
        let ordered = orderedActiveNotes
        guard ordered.indices.contains(index) else { return }
        let side = presentationState.currentNoteID.flatMap { iceEdges[$0] } ?? preferences.defaultEdge
        open(noteID: ordered[index].id, on: side, focusEditor: true)
    }

    func openFromLibrary(noteID: UUID) {
        guard note(withID: noteID)?.isActive == true else { return }
        open(noteID: noteID, on: preferences.defaultEdge, focusEditor: true)
    }

    func archive(noteID: UUID) {
        if pendingEmptyNoteIDs.contains(noteID) || draftNote?.id == noteID {
            if presentationState.isPresented(noteID) {
                closeMemo(noteID: noteID)
            } else {
                finalizeTransientState(noteID: noteID)
            }
            return
        }
        if presentationState.isPresented(noteID) { closeMemo(noteID: noteID) }
        guard store.setActive(noteID: noteID, isActive: false) else {
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
            return
        }
        reloadNotes()
        refreshLayout()
    }

    func restore(noteID: UUID) -> MemoRestoreResult {
        guard store.setActive(noteID: noteID, isActive: true) else {
            if let error = store.lastPersistenceError {
                showPersistenceAlert(error)
                return .failed
            }
            return .capacityReached
        }
        reloadNotes()
        refreshLayout()
        return .restored
    }

    func delete(noteID: UUID) {
        if draftNote?.id == noteID || pendingEmptyNoteIDs.contains(noteID) {
            if presentationState.isPresented(noteID) {
                closeMemo(noteID: noteID)
            } else {
                finalizeTransientState(noteID: noteID)
            }
            return
        }
        if presentationState.isPresented(noteID) { closeMemo(noteID: noteID) }
        permanentDelete(noteID: noteID)
    }

    func updateTitle(noteID: UUID, title: String) {
        if var draft = draftNote, draft.id == noteID {
            draft.title = title
            draft.isTitleExplicit = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draftNote = draft
            reloadNotes()
        } else {
            store.updateTitle(noteID: noteID, title: title)
            reloadNotes()
        }
        refreshLayout()
    }

    func updateAppearance(
        noteID: UUID,
        color: NoteColor? = nil,
        textColorHex: String? = nil,
        aspectRatio: MemoAspectRatio? = nil,
        opacity: Double? = nil
    ) {
        if var draft = draftNote, draft.id == noteID {
            if let color { draft.color = color }
            if let textColorHex { draft.textColorHex = textColorHex }
            if let aspectRatio { draft.aspectRatio = aspectRatio }
            if let opacity { draft.opacity = opacity }
            draftNote = draft
            reloadNotes()
        } else {
            store.updateAppearance(
                noteID: noteID,
                color: color,
                textColorHex: textColorHex,
                aspectRatio: aspectRatio,
                opacity: opacity
            )
            reloadNotes()
        }
        refreshLayout()
    }

    func note(withID id: UUID) -> MemoNote? {
        notes.first { $0.id == id }
    }

    func edge(for noteID: UUID) -> EdgeDock? {
        guard note(withID: noteID) != nil else { return nil }
        return iceEdges[noteID] ?? launcherEdge
    }

    var activeNotes: [MemoNote] { notes.filter(\.isActive) }

    private var orderedActiveNotes: [MemoNote] {
        // Keep the last visible legacy order until the user explicitly reorders the shared tray.
        let groups = store.edgeGroups.sorted {
            if $0.id == store.defaultGroupID { return true }
            if $1.id == store.defaultGroupID { return false }
            if $0.edge != $1.edge { return $0.edge.rawValue < $1.edge.rawValue }
            return $0.createdAt < $1.createdAt
        }
        let groupOrder = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
        return activeNotes.sorted {
            let lhsGroup = groupOrder[$0.placement.groupID] ?? Int.max
            let rhsGroup = groupOrder[$1.placement.groupID] ?? Int.max
            if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
            return $0.placement.order < $1.placement.order
        }
    }

    var availableIndexNotes: [MemoNote] {
        orderedActiveNotes.filter { !presentationState.isIce($0.id) }
    }

    private func open(
        noteID: UUID,
        on requestedEdge: EdgeDock? = nil,
        focusEditor: Bool = false
    ) {
        guard let note = note(withID: noteID), note.isActive else { return }
        if presentationState.isIce(noteID) {
            focusIce(noteID: noteID)
            return
        }
        let edge = (requestedEdge ?? launcherEdge).interactiveSide
        let sameEdge = presentationState.iceNoteIDs.filter { iceEdges[$0] == edge }
        let evictedID = sameEdge.count >= EdgeLayoutEngine.maxIcePerEdge
            ? sameEdge.first
            : nil
        collapsingNoteIDs.remove(noteID)
        launcherEdge = edge
        refreshLayoutSnapshot()

        guard let handleFrame = layoutSnapshot.handleFrames[noteID] else { return }
        let screen = targetScreen()

        if let evictedID {
            collapsingNoteIDs.insert(evictedID)
            presentationState = EdgePresentationReducer.reduce(
                state: presentationState,
                action: .close(evictedID)
            )
        }
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .open(noteID)
        )
        iceEdges[noteID] = edge
        launcherEdge = edge
        indexVisibility = .hidden
        handleControllers[noteID]?.hide(animated: false)
        refreshLayoutSnapshot()
        let panelFrame = panelFrame(for: note, handleFrame: handleFrame, edge: edge, screen: screen)
        preferences.lastNoteID = noteID
        panelController(for: noteID).show(
            note: note,
            frame: panelFrame,
            handleFrame: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            focusEditor: focusEditor,
            onTitleChange: { [weak self] title in
                self?.handlePanelTitleChange(noteID: noteID, title: title)
            }
        ) { [weak self] content in
            self?.handleContentChange(noteID: noteID, content: content)
        }
        refreshLayout(excludingPanelID: noteID)
        if let evictedID {
            foldEvictedIce(noteID: evictedID, edge: edge, screen: screen)
        }
        onPresentationChange?(true)
    }

    private func foldEvictedIce(noteID: UUID, edge: EdgeDock, screen: NSScreen) {
        let targetFrame: CGRect
        if let frame = layoutSnapshot.handleFrames[noteID] {
            targetFrame = frame
        } else if let note = note(withID: noteID) {
            targetFrame = collapseTargetFrame(for: note, edge: edge, screen: screen)
        } else {
            targetFrame = .zero
        }

        let controller = panelControllers[noteID]
        controller?.fold(to: targetFrame, completion: { [weak self, weak controller] in
            guard let self else { return }
            self.collapsingNoteIDs.remove(noteID)
            if self.panelControllers[noteID] === controller {
                self.panelControllers.removeValue(forKey: noteID)
            }
            self.iceEdges.removeValue(forKey: noteID)
            self.refreshHandleSelection()
        })
        if controller == nil {
            collapsingNoteIDs.remove(noteID)
            iceEdges.removeValue(forKey: noteID)
        }
        finalizeTransientState(noteID: noteID)
    }

    private func panelController(for noteID: UUID) -> MemoPanelController {
        if let controller = panelControllers[noteID] { return controller }

        let controller = MemoPanelController(assetRootURL: assetRootURL)
        controller.onFold = { [weak self] in self?.closeMemo(noteID: noteID) }
        controller.onImageUpload = { [weak self] requestedNoteID, data, originalName in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try self.importImage(
                noteID: requestedNoteID,
                data: data,
                originalName: originalName
            )
        }
        controller.onCycle = { [weak self] direction in
            self?.focusIce(noteID: noteID)
            self?.cycleNote(direction: direction)
        }
        controller.onSelectIndex = { [weak self] index in
            self?.focusIce(noteID: noteID)
            self?.selectNote(at: index)
        }
        controller.onResize = { [weak self] requestedNoteID, size in
            self?.handlePanelResize(noteID: requestedNoteID, size: size)
        }
        panelControllers[noteID] = controller
        return controller
    }

    private func prepareIndexHandoff(noteID: UUID) {
        collapsingNoteIDs.remove(noteID)
        let pointerOverIndex = layoutSnapshot.handleFrames[noteID]?.contains(NSEvent.mouseLocation) == true
        if pointerOverIndex, let edge = edge(for: noteID) {
            indexVisibility = .visible(edge)
        } else if pointerInsideHotZones.isEmpty,
                  pointerInsideHandles.isEmpty,
                  pointerInsideControls.isEmpty {
            indexVisibility = .hidden
        }
        refreshHandleSelection()
        if pointerOverIndex {
            handleControllers[noteID]?.show(animated: false)
        }
    }

    private func focusIce(noteID: UUID) {
        guard presentationState.isIce(noteID) else { return }
        preferences.lastNoteID = noteID
        panelControllers[noteID]?.window?.makeKeyAndOrderFront(nil)
    }

    private func handleContentChange(noteID: UUID, content: String) {
        if var draft = draftNote, draft.id == noteID {
            draft.content = content
            draft.updatedAt = Date()
            draftNote = draft
            guard MemoNote.hasMeaningfulContent(content) else {
                reloadNotes()
                return
            }
            do {
                _ = try store.commitDraft(draft)
                draftNote = nil
                reloadNotes()
                refreshLayout()
            } catch {
                showPersistenceAlert(error)
            }
            return
        }

        guard store.note(withID: noteID) != nil else { return }
        if MemoNote.hasMeaningfulContent(content) {
            pendingEmptyNoteIDs.remove(noteID)
            store.updateContent(noteID: noteID, content: content)
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
            reloadNotes()
        } else {
            pendingEmptyNoteIDs.insert(noteID)
            reloadNotes()
            if let index = notes.firstIndex(where: { $0.id == noteID }) {
                notes[index].content = ""
            }
        }
    }

    private func handlePanelTitleChange(noteID: UUID, title: String) {
        if var draft = draftNote, draft.id == noteID {
            draft.title = title
            draft.isTitleExplicit = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draftNote = draft
        } else {
            store.updateTitle(noteID: noteID, title: title)
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
        }
        reloadNotes()
        refreshLayoutSnapshot()
        refreshHandles()
        repositionOpenPanel(noteID: noteID)
    }

    private func handlePanelResize(noteID: UUID, size: CGSize) {
        if var draft = draftNote, draft.id == noteID {
            let storedHeight = draft.panelSize?.cgSize.height ?? MemoPanelSize.minimum.height
            draft.panelSize = MemoPanelSize(width: size.width, height: storedHeight)
            draftNote = draft
        } else {
            store.updatePanelWidth(noteID: noteID, width: size.width)
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
        }
        reloadNotes()
        refreshLayout()
    }

    private func repositionOpenPanel(noteID: UUID) {
        guard presentationState.isPresented(noteID),
              let note = note(withID: noteID),
              let edge = iceEdges[noteID]
        else { return }
        let screen = targetScreen()
        let handleFrame = collapseTargetFrame(for: note, edge: edge, screen: screen)
        let frame = panelFrame(for: note, handleFrame: handleFrame, edge: edge, screen: screen)
        panelControllers[noteID]?.reposition(
            frame: frame,
            handleFrame: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge
        )
    }

    private func refreshLayout(excludingPanelID: UUID? = nil) {
        let screen = targetScreen()
        hotZoneController.update(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        refreshLayoutSnapshot()
        refreshHandles()

        for noteID in presentationState.iceNoteIDs {
            guard noteID != excludingPanelID else { continue }
            guard let note = note(withID: noteID),
                  let edge = iceEdges[noteID]
            else { continue }
            let handleFrame = collapseTargetFrame(for: note, edge: edge, screen: screen)
            let panelFrame = panelFrame(for: note, handleFrame: handleFrame, edge: edge, screen: screen)
            panelController(for: noteID).show(
                note: note,
                frame: panelFrame,
                handleFrame: handleFrame,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                edge: edge,
                focusEditor: false,
                onTitleChange: { [weak self] title in
                    self?.handlePanelTitleChange(noteID: noteID, title: title)
                }
            ) { [weak self] content in
                self?.handleContentChange(noteID: noteID, content: content)
            }
        }
    }

    private func refreshLayoutSnapshot() {
        let screen = targetScreen()
        let availableNotes = availableIndexNotes
        let anchorY = launcherAnchorY[launcherEdge] ?? screen.visibleFrame.midY
        layoutSnapshot = EdgeLayoutEngine.launcherLayout(
            notes: availableNotes,
            edge: launcherEdge,
            anchorY: anchorY,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func panelFrame(
        for note: MemoNote,
        handleFrame: CGRect,
        edge: EdgeDock,
        screen: NSScreen
    ) -> CGRect {
        let newestFirst = Array(presentationState.iceNoteIDs
            .filter { iceEdges[$0] == edge }
            .reversed())
        let slot = newestFirst.firstIndex(of: note.id) ?? 0
        return EdgeLayoutEngine.icePanelFrame(
            edge: edge,
            slot: slot,
            indexGroupFrame: nil,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            storedWidth: note.panelSize?.cgSize.width
        )
    }

    private func collapseTargetFrame(for note: MemoNote, edge: EdgeDock, screen: NSScreen) -> CGRect {
        let anchorY = launcherAnchorY[edge] ?? screen.visibleFrame.midY
        let snapshot = EdgeLayoutEngine.launcherLayout(
            notes: [note],
            edge: edge,
            anchorY: anchorY,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        return snapshot.handleFrames[note.id] ?? CGRect(
            x: edge == .left ? screen.frame.minX : screen.frame.maxX - 100,
            y: anchorY - EdgeLayoutEngine.sideHandleHeight / 2,
            width: 100,
            height: EdgeLayoutEngine.sideHandleHeight
        )
    }

    private func refreshHandles() {
        let activeIDs = Set(activeNotes.map(\.id))
        for (id, controller) in handleControllers where !activeIDs.contains(id) {
            controller.close()
            handleControllers.removeValue(forKey: id)
            pointerInsideHandles.remove(id)
        }
        for (id, controller) in panelControllers where !activeIDs.contains(id)
            && !collapsingNoteIDs.contains(id) {
            controller.close()
            panelControllers.removeValue(forKey: id)
        }

        for note in activeNotes {
            guard let frame = layoutSnapshot.handleFrames[note.id] else { continue }
            let edge = launcherEdge
            if let controller = handleControllers[note.id] {
                controller.update(
                    note: note,
                    frame: frame,
                    edge: edge,
                    isSelected: presentationState.isPresented(note.id) || collapsingNoteIDs.contains(note.id),
                    isDropTarget: false
                )
            } else {
                let noteID = note.id
                let controller = EdgeHandlePanelController(
                    note: note,
                    frame: frame,
                    edge: edge,
                    onClick: { [weak self] in self?.handleClick(noteID: noteID) },
                    onDoubleClick: { [weak self] in self?.handleDoubleClick(noteID: noteID) },
                    onPointerChange: { [weak self] inside in self?.handleIndexPointer(noteID: noteID, inside: inside) },
                    onDragBegan: { [weak self] in self?.beginDrag(noteID: noteID) },
                    onDragChanged: { [weak self] point in self?.continueDrag(noteID: noteID, point: point) },
                    onDragFinished: { [weak self] point in self?.finishDrag(noteID: noteID, point: point) }
                )
                handleControllers[note.id] = controller
            }
        }
        refreshControlFrames()
        applyIndexVisibility()
    }

    private func refreshControlFrames() {
        let screen = targetScreen()
        for edge in EdgeDock.interactiveCases {
            let frames = edge == launcherEdge ? Array(layoutSnapshot.handleFrames.values) : []
            let frame = EdgeLayoutEngine.launcherControlFrame(
                edge: edge,
                anchorY: launcherAnchorY[edge] ?? screen.visibleFrame.midY,
                handleFrames: frames,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
            controlControllers[edge]?.update(frame: frame)
        }
    }

    private func refreshHandleSelection() {
        for note in activeNotes where note.id != draggingNoteID {
            guard let frame = layoutSnapshot.handleFrames[note.id] else { continue }
            handleControllers[note.id]?.update(
                note: note,
                frame: frame,
                edge: launcherEdge,
                isSelected: presentationState.isPresented(note.id) || collapsingNoteIDs.contains(note.id),
                isDropTarget: false
            )
        }
        applyIndexVisibility()
    }

    private func handleHotZonePointer(edge: EdgeDock, inside: Bool) {
        if inside {
            let side = edge.interactiveSide
            pointerInsideHotZones.insert(side)
            launcherAnchorY[side] = NSEvent.mouseLocation.y
            hideTask?.cancel()
            scheduleReveal(edge: side)
        } else {
            pointerInsideHotZones.remove(edge.interactiveSide)
            revealTask?.cancel()
            scheduleHideIndices()
        }
    }

    private func handleControlPointer(edge: EdgeDock, inside: Bool) {
        if inside {
            pointerInsideControls.insert(edge)
            hideTask?.cancel()
        } else {
            pointerInsideControls.remove(edge)
            scheduleHideIndices()
        }
    }

    private func handleIndexPointer(noteID: UUID, inside: Bool) {
        if inside {
            pointerInsideHandles.insert(noteID)
            hideTask?.cancel()
        } else {
            pointerInsideHandles.remove(noteID)
            scheduleHideIndices()
        }
    }

    private func scheduleReveal(edge: EdgeDock) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(preferences.revealDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.pointerInsideHotZones.contains(edge), self.draggingNoteID == nil else { return }
                if self.launcherEdge != edge.interactiveSide {
                    self.hideTrayImmediately()
                }
                self.launcherEdge = edge.interactiveSide
                self.indexVisibility = .visible(edge)
                self.refreshLayout()
            }
        }
    }

    private func scheduleHideIndices() {
        guard draggingNoteID == nil,
              collapsingNoteIDs.isEmpty
        else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(preferences.hideDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.pointerInsideHotZones.isEmpty,
                      self.pointerInsideHandles.isEmpty,
                      self.pointerInsideControls.isEmpty,
                      self.collapsingNoteIDs.isEmpty
                else { return }
                self.indexVisibility = .hidden
                self.applyIndexVisibility()
            }
        }
    }

    private func applyIndexVisibility() {
        for note in activeNotes {
            guard let controller = handleControllers[note.id] else { continue }
            let isAvailableAsIndex = !presentationState.isPresented(note.id)
                && !collapsingNoteIDs.contains(note.id)
            let requestedByVisibility: Bool
            switch indexVisibility {
            case .hidden:
                requestedByVisibility = false
            case let .visible(visibleEdge):
                requestedByVisibility = launcherEdge == visibleEdge
            case let .transitioning(noteID):
                requestedByVisibility = note.id == noteID
            case .dragging:
                requestedByVisibility = true
            }
            let shouldShow = requestedByVisibility && isAvailableAsIndex
            if shouldShow { controller.show() } else { controller.hide() }
        }
        for edge in EdgeDock.interactiveCases {
            let shouldShow: Bool
            if case let .visible(visibleEdge) = indexVisibility {
                shouldShow = visibleEdge == edge
            } else {
                shouldShow = false
            }
            if shouldShow {
                controlControllers[edge]?.show()
            } else {
                controlControllers[edge]?.hide()
            }
        }
    }

    private func hideTrayImmediately() {
        for controller in handleControllers.values {
            controller.hide(animated: false)
        }
        for controller in controlControllers.values {
            controller.hide(animated: false)
        }
    }

    private func beginDrag(noteID: UUID) {
        revealTask?.cancel()
        hideTask?.cancel()
        draggingNoteID = noteID
        indexVisibility = .dragging(noteID)
        let screen = targetScreen()
        hotZoneController.setDragging(true)
        deleteDropZoneController.show(visibleFrame: screen.visibleFrame)
        applyIndexVisibility()
    }

    private func continueDrag(noteID: UUID, point: NSPoint) {
        guard draggingNoteID == noteID, let note = note(withID: noteID) else { return }
        let overDeleteTarget = deleteDropZoneController.contains(point)
        deleteDropZoneController.setHighlighted(overDeleteTarget)
        hotZoneController.setDragging(true)
        for candidate in activeNotes where candidate.id != note.id {
            guard let frame = layoutSnapshot.handleFrames[candidate.id] else { continue }
            handleControllers[candidate.id]?.update(
                note: candidate,
                frame: frame,
                edge: launcherEdge,
                isSelected: presentationState.isPresented(candidate.id),
                isDropTarget: false
            )
        }
    }

    private func finishDrag(noteID: UUID, point: NSPoint) {
        if deleteDropZoneController.contains(point) {
            endDragInteraction()
            indexVisibility = .visible(launcherEdge)
            refreshLayout()
            confirmDragDeletion(noteID: noteID)
            return
        }
        defer {
            endDragInteraction()
            if case .visible = indexVisibility {
                scheduleHideIndices()
            }
        }
        guard note(withID: noteID) != nil else {
            indexVisibility = .hidden
            refreshLayout()
            return
        }
        let frames = layoutSnapshot.handleFrames.values
        guard let firstFrame = frames.first else {
            indexVisibility = .visible(launcherEdge)
            refreshLayout()
            return
        }
        let trayFrame = frames.dropFirst().reduce(firstFrame) { $0.union($1) }
        guard trayFrame.insetBy(dx: -80, dy: -20).contains(point) else {
            indexVisibility = .visible(launcherEdge)
            refreshLayout()
            return
        }

        let remaining = orderedActiveNotes.filter {
            $0.id != noteID && !presentationState.isIce($0.id)
        }
        let insertion = EdgeLayoutEngine.launcherInsertionOrder(
            at: point,
            orderedNotes: remaining,
            snapshot: layoutSnapshot
        )
        var reorderedVisibleIDs = remaining.map(\.id)
        reorderedVisibleIDs.insert(noteID, at: min(insertion, reorderedVisibleIDs.count))

        var visibleIterator = reorderedVisibleIDs.makeIterator()
        let mergedOrder = orderedActiveNotes.compactMap { note -> UUID? in
            presentationState.isIce(note.id) ? note.id : visibleIterator.next()
        }
        if !store.setGlobalIndexOrder(mergedOrder), let error = store.lastPersistenceError {
            showPersistenceAlert(error)
        }

        reloadNotes()
        indexVisibility = .visible(launcherEdge)
        refreshLayout()
    }

    private func endDragInteraction() {
        draggingNoteID = nil
        hotZoneController.setDragging(false)
        deleteDropZoneController.hide()
    }

    private func confirmDragDeletion(noteID: UUID) {
        guard let note = note(withID: noteID) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "‘\(note.displayTitle)’ 메모를 삭제할까?"
        alert.informativeText = "본문과 메모에 복사된 이미지가 함께 영구 삭제되며 되돌릴 수 없어."
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "삭제").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            delete(noteID: noteID)
        } else {
            refreshLayout()
            scheduleHideIndices()
        }
    }

    private func importImage(noteID: UUID, data: Data, originalName: String) throws -> URL {
        let imported = try attachmentService.importImage(
            data: data,
            originalName: originalName,
            noteID: noteID
        )
        let attachment = MemoAttachment(
            id: imported.id,
            fileName: imported.fileName,
            originalName: imported.originalName
        )

        if var draft = draftNote, draft.id == noteID {
            draft.attachments.append(attachment)
            draft.updatedAt = Date()
            draftNote = draft
        } else {
            store.appendAttachment(noteID: noteID, attachment: attachment)
            if let error = store.lastPersistenceError {
                attachmentService.removeImportedAttachment(noteID: noteID, fileName: imported.fileName)
                throw error
            }
            reloadNotes()
        }
        return imported.assetURL
    }

    private func finalizeTransientState(noteID: UUID) {
        if let draft = draftNote, draft.id == noteID {
            for attachment in draft.attachments {
                attachmentService.removeImportedAttachment(
                    noteID: noteID,
                    fileName: attachment.fileName
                )
            }
            draftNote = nil
            reloadNotes()
            refreshLayout()
            return
        }
        if pendingEmptyNoteIDs.remove(noteID) != nil {
            permanentDelete(noteID: noteID)
        }
    }

    private func permanentDelete(noteID: UUID) {
        let staged: StagedAttachmentDeletion?
        do {
            staged = try attachmentService.stageDeletion(noteID: noteID)
        } catch {
            showPersistenceAlert(error)
            return
        }

        guard store.deleteNote(noteID: noteID) else {
            if let staged { try? attachmentService.restoreDeletion(staged) }
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
            return
        }
        attachmentService.finalizeDeletion(staged)
        pendingEmptyNoteIDs.remove(noteID)
        reloadNotes()
        refreshLayout()
    }

    private func nextOrder(in groupID: UUID) -> Int {
        (activeNotes.filter { $0.placement.groupID == groupID }.map(\.placement.order).max() ?? -1) + 1
    }

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        let candidates = screens.map {
            EdgeScreenCandidate(displayID: $0.memoDisplayID, frame: $0.frame, isMain: $0 == NSScreen.main)
        }
        let index = EdgeScreenSelector.selectedIndex(
            candidates: candidates,
            preferredDisplayID: preferences.targetDisplayID,
            pointer: NSEvent.mouseLocation
        ) ?? 0
        return screens[index]
    }

    private func reloadNotes() {
        notes = store.notes
        for noteID in pendingEmptyNoteIDs {
            if let index = notes.firstIndex(where: { $0.id == noteID }) { notes[index].content = "" }
        }
        if let draftNote { notes.append(draftNote) }
    }

    private func showCapacityAlert() {
        let alert = NSAlert()
        alert.messageText = "활성 메모가 10개야"
        alert.informativeText = "보관함에서 메모 하나를 보관한 뒤 새 메모를 만들 수 있어."
        alert.addButton(withTitle: "보관함 보기")
        alert.addButton(withTitle: "확인")
        if alert.runModal() == .alertFirstButtonReturn { onShowLibrary?() }
    }

    private func showPersistenceAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "메모를 저장하지 못했어"
        alert.informativeText = "기존 저장 파일은 유지했어.\n\n오류: \(error.localizedDescription)"
        alert.runModal()
    }
}
