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
    @Published private(set) var presentationState: EdgePresentationState = .closed
    @Published private(set) var indexVisibility: EdgeIndexVisibilityState = .hidden

    let store: NoteStore
    let preferences: EdgePreferences

    var onShowLibrary: (() -> Void)?
    var onPresentationChange: ((Bool) -> Void)?

    private let attachmentService: AttachmentService
    private let panelController: MemoPanelController
    private let hotZoneController = EdgeHotZoneController()
    private var handleControllers: [UUID: EdgeHandlePanelController] = [:]
    private var layoutSnapshot: EdgeLayoutSnapshot = .empty
    private var pointerInsideHandles: Set<UUID> = []
    private var pointerInsideHotZones: Set<EdgeDock> = []
    private var pointerInsidePanel = false
    private var pendingEmptyNoteIDs: Set<UUID> = []
    private var draftNote: MemoNote?
    private var draftGroup: MemoEdgeGroup?
    private var draggingNoteID: UUID?
    private var dropTargetGroupID: UUID?
    private var revealTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var foldTask: Task<Void, Never>?
    private var hoverPreviewTask: Task<Void, Never>?
    private var hoveredNoteID: UUID?
    private var collapsingNoteID: UUID?
    private var observers: [NSObjectProtocol] = []

    init(store: NoteStore, preferences: EdgePreferences = .shared) {
        self.store = store
        self.preferences = preferences
        notes = store.notes

        let storageDirectory = store.persistenceURL.deletingLastPathComponent()
        attachmentService = AttachmentService(storageDirectory: storageDirectory)
        attachmentService.reconcileStagedDeletions(existingNoteIDs: Set(store.notes.map(\.id)))
        panelController = MemoPanelController(
            assetRootURL: storageDirectory.appendingPathComponent("attachments", isDirectory: true)
        )

        panelController.onFold = { [weak self] in self?.closeMemo() }
        panelController.onRequestIce = { [weak self] in self?.promotePeekToIce() }
        panelController.onPointerChange = { [weak self] inside in
            self?.pointerInsidePanel = inside
            self?.updatePeekDismissal()
        }
        panelController.onImageUpload = { [weak self] noteID, data, originalName in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try self.importImage(
                noteID: noteID,
                data: data,
                originalName: originalName
            )
        }
        panelController.onCycle = { [weak self] direction in self?.cycleNote(direction: direction) }
        panelController.onSelectIndex = { [weak self] index in self?.selectNote(at: index) }
        panelController.onResize = { [weak self] noteID, size in
            self?.handlePanelResize(noteID: noteID, size: size)
        }
        hotZoneController.onPointerChange = { [weak self] edge, inside in
            self?.handleHotZonePointer(edge: edge, inside: inside)
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
        foldTask?.cancel()
        hoverPreviewTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        store.setDefaultEdge(preferences.defaultEdge)
        reloadNotes()
        refreshLayout()
    }

    func prepareForTermination() {
        if let noteID = presentationState.noteID { finalizeTransientState(noteID: noteID) }
        for noteID in Array(pendingEmptyNoteIDs) { finalizeTransientState(noteID: noteID) }
        store.save()
    }

    func createNote() {
        guard activeNotes.count < NoteStore.maxActiveNotes else {
            showCapacityAlert()
            return
        }
        if let current = presentationState.noteID { finalizeTransientState(noteID: current) }

        let defaultAspect = MemoAspectRatio(rawValue: preferences.defaultAspectRawValue) ?? .square
        let timestamp = Date()
        draftNote = MemoNote(
            title: "새 메모",
            content: "",
            color: NoteColor.randomMemoColor(
                excluding: store.notes.max(by: { $0.updatedAt < $1.updatedAt })?.color
            ),
            isActive: true,
            placement: MemoPlacement(
                groupID: store.defaultGroupID,
                order: nextOrder(in: store.defaultGroupID)
            ),
            aspectRatio: defaultAspect,
            opacity: preferences.defaultOpacity,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        draftGroup = nil
        reloadNotes()
        refreshLayout()
        if let draftNote { open(noteID: draftNote.id, ice: true) }
    }

    func handleClick(noteID: UUID) {
        let nextState = EdgePresentationReducer.reduce(state: presentationState, action: .click(noteID))
        if nextState == .closed { closeMemo() } else { open(noteID: noteID, ice: nextState.isIce) }
    }

    func handleDoubleClick(noteID: UUID) {
        let nextState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .doubleClick(noteID)
        )
        open(noteID: noteID, ice: nextState.isIce)
    }

    func toggleRecent() {
        if presentationState != .closed {
            closeMemo()
            return
        }
        let candidate = preferences.lastNoteID.flatMap(note(withID:)) ?? orderedActiveNotes.first
        if let candidate { open(noteID: candidate.id, ice: false) }
    }

    func toggleMode() {
        let nextState = EdgePresentationReducer.reduce(state: presentationState, action: .toggleMode)
        guard let noteID = nextState.noteID else { return }
        open(noteID: noteID, ice: nextState.isIce)
    }

    func closeMemo() {
        let closingID = presentationState.noteID
        foldTask?.cancel()
        foldTask = nil
        collapsingNoteID = closingID
        presentationState = .closed
        if let closingID,
           pointerInsideHotZones.isEmpty,
           pointerInsideHandles.isEmpty {
            indexVisibility = .transitioning(closingID)
        }
        refreshHandleSelection()
        panelController.fold { [weak self] in
            guard let self, self.collapsingNoteID == closingID else { return }
            self.collapsingNoteID = nil
            self.refreshHandleSelection()
            if self.pointerInsideHotZones.isEmpty,
               self.pointerInsideHandles.isEmpty,
               self.draggingNoteID == nil {
                self.indexVisibility = .hidden
                self.applyIndexVisibility()
            }
        }
        if let closingID { finalizeTransientState(noteID: closingID) }
        onPresentationChange?(false)
    }

    func cycleNote(direction: Int) {
        let ordered = orderedActiveNotes
        guard !ordered.isEmpty else { return }
        let currentIndex = presentationState.noteID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let next = (currentIndex + direction + ordered.count) % ordered.count
        open(noteID: ordered[next].id, ice: presentationState.isIce)
    }

    func selectNote(at index: Int) {
        let ordered = orderedActiveNotes
        guard ordered.indices.contains(index) else { return }
        open(noteID: ordered[index].id, ice: presentationState.isIce)
    }

    func openFromLibrary(noteID: UUID) {
        guard note(withID: noteID)?.isActive == true else { return }
        open(noteID: noteID, ice: true)
    }

    func archive(noteID: UUID) {
        if pendingEmptyNoteIDs.contains(noteID) || draftNote?.id == noteID {
            if presentationState.noteID == noteID {
                presentationState = .closed
                panelController.fold()
                onPresentationChange?(false)
            }
            finalizeTransientState(noteID: noteID)
            return
        }
        if presentationState.noteID == noteID { closeMemo() }
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
        if presentationState.noteID == noteID {
            presentationState = .closed
            panelController.fold()
            onPresentationChange?(false)
        }
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

    func attachToDefaultGroup(noteID: UUID) {
        if var draft = draftNote, draft.id == noteID {
            draft.placement = MemoPlacement(groupID: store.defaultGroupID, order: nextOrder(in: store.defaultGroupID))
            draftNote = draft
            draftGroup = nil
            reloadNotes()
            refreshLayout()
            return
        }
        guard store.attachToDefaultGroup(noteID: noteID) else {
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
            return
        }
        reloadNotes()
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
            if let aspectRatio {
                draft.aspectRatio = aspectRatio
                draft.panelSize = nil
            }
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
        guard let note = note(withID: noteID) else { return nil }
        return allGroups.first { $0.id == note.placement.groupID }?.edge
    }

    var activeNotes: [MemoNote] { notes.filter(\.isActive) }

    private var allGroups: [MemoEdgeGroup] {
        guard let draftGroup,
              !store.edgeGroups.contains(where: { $0.id == draftGroup.id })
        else { return store.edgeGroups }
        return store.edgeGroups + [draftGroup]
    }

    private var orderedActiveNotes: [MemoNote] {
        let groups = allGroups.sorted {
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

    private func open(noteID: UUID, ice: Bool) {
        collapsingNoteID = nil
        if let current = presentationState.noteID, current != noteID {
            finalizeTransientState(noteID: current)
        }
        guard let note = note(withID: noteID), note.isActive else { return }
        foldTask?.cancel()
        foldTask = nil
        refreshLayoutSnapshot()

        guard let handleFrame = layoutSnapshot.handleFrames[noteID],
              let edge = edge(for: noteID)
        else { return }
        let screen = targetScreen()
        let panelFrame = EdgeLayoutEngine.panelFrame(
            adjacentTo: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            aspectRatio: note.aspectRatio.value,
            panelSize: note.panelSize
        )

        presentationState = ice ? .ice(noteID) : .peek(noteID)
        preferences.lastNoteID = noteID
        panelController.show(
            note: note,
            frame: panelFrame,
            handleFrame: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            isIce: ice,
            focusEditor: ice,
            onTitleChange: { [weak self] title in
                self?.handlePanelTitleChange(noteID: noteID, title: title)
            }
        ) { [weak self] content in
            self?.handleContentChange(noteID: noteID, content: content)
        }
        refreshHandleSelection()
        onPresentationChange?(true)
        updatePeekDismissal()
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
                _ = try store.commitDraft(draft, adding: draftGroup)
                draftNote = nil
                draftGroup = nil
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
            draft.panelSize = MemoPanelSize(size)
            draftNote = draft
        } else {
            store.updatePanelSize(noteID: noteID, size: size)
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
        }
        reloadNotes()
        refreshLayout()
    }

    private func promotePeekToIce() {
        guard case let .peek(noteID) = presentationState else { return }
        open(noteID: noteID, ice: true)
    }

    private func repositionOpenPanel(noteID: UUID) {
        guard presentationState.noteID == noteID,
              let note = note(withID: noteID),
              let handleFrame = layoutSnapshot.handleFrames[noteID],
              let edge = edge(for: noteID)
        else { return }
        let screen = targetScreen()
        let frame = EdgeLayoutEngine.panelFrame(
            adjacentTo: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            aspectRatio: note.aspectRatio.value,
            panelSize: note.panelSize
        )
        panelController.reposition(
            frame: frame,
            handleFrame: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge
        )
    }

    private func refreshLayout() {
        let screen = targetScreen()
        hotZoneController.update(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        refreshLayoutSnapshot()
        refreshHandles()

        guard let noteID = presentationState.noteID,
              let note = note(withID: noteID),
              let handleFrame = layoutSnapshot.handleFrames[noteID],
              let edge = edge(for: noteID)
        else { return }
        let panelFrame = EdgeLayoutEngine.panelFrame(
            adjacentTo: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            aspectRatio: note.aspectRatio.value,
            panelSize: note.panelSize
        )
        panelController.show(
            note: note,
            frame: panelFrame,
            handleFrame: handleFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: edge,
            isIce: presentationState.isIce,
            focusEditor: false,
            onTitleChange: { [weak self] title in
                self?.handlePanelTitleChange(noteID: noteID, title: title)
            }
        ) { [weak self] content in
            self?.handleContentChange(noteID: noteID, content: content)
        }
    }

    private func refreshLayoutSnapshot() {
        let screen = targetScreen()
        layoutSnapshot = EdgeLayoutEngine.layout(
            notes: activeNotes,
            groups: allGroups,
            defaultGroupID: store.defaultGroupID,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func refreshHandles() {
        let activeIDs = Set(activeNotes.map(\.id))
        for (id, controller) in handleControllers where !activeIDs.contains(id) {
            controller.close()
            handleControllers.removeValue(forKey: id)
            pointerInsideHandles.remove(id)
        }

        for note in activeNotes {
            guard let frame = layoutSnapshot.handleFrames[note.id],
                  let edge = edge(for: note.id)
            else { continue }
            if let controller = handleControllers[note.id] {
                controller.update(
                    note: note,
                    frame: frame,
                    edge: edge,
                    isSelected: presentationState.noteID == note.id || collapsingNoteID == note.id,
                    isDropTarget: note.placement.groupID == dropTargetGroupID
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
        applyIndexVisibility()
    }

    private func refreshHandleSelection() {
        for note in activeNotes where note.id != draggingNoteID {
            guard let frame = layoutSnapshot.handleFrames[note.id],
                  let edge = edge(for: note.id)
            else { continue }
            handleControllers[note.id]?.update(
                note: note,
                frame: frame,
                edge: edge,
                isSelected: presentationState.noteID == note.id || collapsingNoteID == note.id,
                isDropTarget: note.placement.groupID == dropTargetGroupID
            )
        }
        applyIndexVisibility()
    }

    private func handleHotZonePointer(edge: EdgeDock, inside: Bool) {
        if inside {
            pointerInsideHotZones.insert(edge)
            hideTask?.cancel()
            scheduleReveal(edge: edge)
        } else {
            pointerInsideHotZones.remove(edge)
            revealTask?.cancel()
            scheduleHideIndices()
        }
        updatePeekDismissal()
    }

    private func handleIndexPointer(noteID: UUID, inside: Bool) {
        if inside {
            pointerInsideHandles.insert(noteID)
            hoveredNoteID = noteID
            hideTask?.cancel()
            scheduleHoverPreview(noteID: noteID)
        } else {
            pointerInsideHandles.remove(noteID)
            if hoveredNoteID == noteID {
                hoveredNoteID = nil
                hoverPreviewTask?.cancel()
            }
            scheduleHideIndices()
        }
        updatePeekDismissal()
    }

    private func scheduleHoverPreview(noteID: UUID) {
        guard draggingNoteID == nil, !presentationState.isIce else { return }
        hoverPreviewTask?.cancel()
        let delay = presentationState.noteID == nil ? 0.10 : 0.04
        hoverPreviewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.draggingNoteID == nil,
                      !self.presentationState.isIce,
                      self.hoveredNoteID == noteID,
                      self.pointerInsideHandles.contains(noteID)
                else { return }
                let nextState = EdgePresentationReducer.reduce(
                    state: self.presentationState,
                    action: .hover(noteID)
                )
                guard nextState.noteID == noteID else { return }
                self.open(noteID: noteID, ice: false)
            }
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
                self.indexVisibility = .visible(edge)
                self.applyIndexVisibility()
            }
        }
    }

    private func scheduleHideIndices() {
        guard draggingNoteID == nil,
              collapsingNoteID == nil,
              !isPeekPresented
        else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(preferences.hideDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.pointerInsideHotZones.isEmpty,
                      self.pointerInsideHandles.isEmpty,
                      self.collapsingNoteID == nil,
                      !self.isPeekPresented
                else { return }
                self.indexVisibility = .hidden
                self.applyIndexVisibility()
            }
        }
    }

    private func applyIndexVisibility() {
        for note in activeNotes {
            guard let controller = handleControllers[note.id], let edge = edge(for: note.id) else { continue }
            let shouldShow: Bool
            switch indexVisibility {
            case .hidden:
                shouldShow = false
            case let .visible(visibleEdge):
                shouldShow = edge == visibleEdge
            case let .transitioning(noteID):
                shouldShow = note.id == noteID
            case .dragging:
                shouldShow = true
            }
            if shouldShow { controller.show() } else { controller.hide() }
        }
    }

    private func beginDrag(noteID: UUID) {
        revealTask?.cancel()
        hideTask?.cancel()
        hoverPreviewTask?.cancel()
        hoveredNoteID = nil
        draggingNoteID = noteID
        indexVisibility = .dragging(noteID)
        hotZoneController.setDragging(true)
        applyIndexVisibility()
    }

    private func continueDrag(noteID: UUID, point: NSPoint) {
        guard draggingNoteID == noteID, let note = note(withID: noteID) else { return }
        let screen = targetScreen()
        let targetDock = EdgeLayoutEngine.dock(at: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        hotZoneController.setDragging(true, targetEdge: targetDock)
        dropTargetGroupID = targetDock.flatMap {
            EdgeLayoutEngine.mergeTarget(
                at: point,
                edge: $0,
                excluding: nil,
                groups: allGroups,
                snapshot: layoutSnapshot
            )
        }
        for candidate in activeNotes where candidate.id != note.id {
            guard let frame = layoutSnapshot.handleFrames[candidate.id],
                  let candidateEdge = edge(for: candidate.id)
            else { continue }
            handleControllers[candidate.id]?.update(
                note: candidate,
                frame: frame,
                edge: candidateEdge,
                isSelected: presentationState.noteID == candidate.id,
                isDropTarget: candidate.placement.groupID == dropTargetGroupID
            )
        }
    }

    private func finishDrag(noteID: UUID, point: NSPoint) {
        defer {
            draggingNoteID = nil
            dropTargetGroupID = nil
            hotZoneController.setDragging(false)
        }
        guard note(withID: noteID) != nil else {
            indexVisibility = .hidden
            refreshLayout()
            return
        }
        let screen = targetScreen()
        guard let edge = EdgeLayoutEngine.dock(
            at: point,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        ) else {
            indexVisibility = .hidden
            refreshLayout()
            return
        }

        let targetGroupID = EdgeLayoutEngine.mergeTarget(
            at: point,
            edge: edge,
            excluding: nil,
            groups: allGroups,
            snapshot: layoutSnapshot
        )
        let order = targetGroupID.map {
            EdgeLayoutEngine.insertionOrder(
                at: point,
                edge: edge,
                notes: activeNotes.filter { $0.id != noteID },
                groupID: $0,
                snapshot: layoutSnapshot
            )
        } ?? 0
        let center = EdgeLayoutEngine.normalizedCenter(at: point, edge: edge, visibleFrame: screen.visibleFrame)

        if var draft = draftNote, draft.id == noteID {
            if let targetGroupID {
                draft.placement = MemoPlacement(groupID: targetGroupID, order: order)
                draftGroup = nil
            } else {
                let group: MemoEdgeGroup
                if let existing = draftGroup {
                    var updated = existing
                    updated.edge = edge
                    updated.normalizedCenter = center
                    group = updated
                } else {
                    group = MemoEdgeGroup(edge: edge, normalizedCenter: center)
                }
                draftGroup = group
                draft.placement = MemoPlacement(groupID: group.id, order: 0)
            }
            draftNote = draft
        } else if !store.placeNote(
            noteID: noteID,
            edge: edge,
            normalizedCenter: center,
            mergeInto: targetGroupID,
            order: order
        ), let error = store.lastPersistenceError {
            showPersistenceAlert(error)
        }

        reloadNotes()
        indexVisibility = .visible(edge)
        refreshLayout()
        scheduleHideIndices()
    }

    private func updatePeekDismissal() {
        foldTask?.cancel()
        foldTask = nil
        guard case .peek = presentationState,
              !pointerInsidePanel,
              pointerInsideHandles.isEmpty,
              pointerInsideHotZones.isEmpty
        else { return }

        foldTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(preferences.peekDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard case .peek = self.presentationState,
                      !self.pointerInsidePanel,
                      self.pointerInsideHandles.isEmpty,
                      self.pointerInsideHotZones.isEmpty
                else { return }
                self.closeMemo()
            }
        }
    }

    private var isPeekPresented: Bool {
        if case .peek = presentationState { return true }
        return false
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
            draftGroup = nil
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
