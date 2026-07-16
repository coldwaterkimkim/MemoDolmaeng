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
    private var restingLayoutSnapshot: EdgeLayoutSnapshot = .empty
    private var pointerInsideHandles: Set<UUID> = []
    private var pointerInsideHotZones: Set<EdgeDock> = []
    private var pointerInsideControls: Set<EdgeDock> = []
    private var pendingEmptyNoteIDs: Set<UUID> = []
    private var draftNote: MemoNote?
    private var draftGroup: MemoEdgeGroup?
    private var draggingNoteID: UUID?
    private var dropTargetGroupID: UUID?
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
        for edge in EdgeDock.allCases {
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
        if let draftNote {
            open(noteID: draftNote.id)
            return
        }
        guard activeNotes.count < NoteStore.maxActiveNotes else {
            showCapacityAlert()
            return
        }

        let timestamp = Date()
        let edgeGroup = store.group(for: edge)
        let placementGroupID: UUID
        if let edgeGroup {
            draftGroup = nil
            placementGroupID = edgeGroup.id
        } else {
            let group = MemoEdgeGroup(
                edge: edge,
                normalizedCenter: edge == .top ? 0.5 : 1,
                createdAt: timestamp
            )
            draftGroup = group
            placementGroupID = group.id
        }
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
        if let draftNote { open(noteID: draftNote.id) }
    }

    func handleClick(noteID: UUID) {
        if presentationState.isIce(noteID) {
            closeMemo(noteID: noteID)
        } else {
            open(noteID: noteID)
        }
    }

    func handleDoubleClick(noteID: UUID) {
        open(noteID: noteID)
    }

    func toggleRecent() {
        if let noteID = presentationState.focusedIceNoteID {
            closeMemo(noteID: noteID)
            return
        }
        let candidate = preferences.lastNoteID.flatMap(note(withID:)) ?? orderedActiveNotes.first
        if let candidate { open(noteID: candidate.id) }
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
        }
        finalizeTransientState(noteID: closingID)
        onPresentationChange?(presentationState.hasOpenPanels)
    }

    func cycleNote(direction: Int) {
        let ordered = orderedActiveNotes
        guard !ordered.isEmpty else { return }
        let currentIndex = presentationState.currentNoteID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let next = (currentIndex + direction + ordered.count) % ordered.count
        open(noteID: ordered[next].id)
    }

    func selectNote(at index: Int) {
        let ordered = orderedActiveNotes
        guard ordered.indices.contains(index) else { return }
        open(noteID: ordered[index].id)
    }

    func openFromLibrary(noteID: UUID) {
        guard note(withID: noteID)?.isActive == true else { return }
        open(noteID: noteID)
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

    private func open(noteID: UUID) {
        guard let note = note(withID: noteID), note.isActive else { return }
        if presentationState.isIce(noteID) {
            focusIce(noteID: noteID)
            return
        }
        guard let edge = edge(for: noteID) else { return }
        let sameEdge = presentationState.iceNoteIDs.filter { self.edge(for: $0) == edge }
        if sameEdge.count >= EdgeLayoutEngine.maxIcePerEdge,
           let oldest = sameEdge.first {
            closeMemo(noteID: oldest)
        }
        collapsingNoteIDs.remove(noteID)
        refreshLayoutSnapshot()

        guard let handleFrame = layoutSnapshot.handleFrames[noteID] else { return }
        let screen = targetScreen()

        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .open(noteID)
        )
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
            focusEditor: true,
            onTitleChange: { [weak self] title in
                self?.handlePanelTitleChange(noteID: noteID, title: title)
            }
        ) { [weak self] content in
            self?.handleContentChange(noteID: noteID, content: content)
        }
        refreshLayout()
        onPresentationChange?(true)
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
              let edge = edge(for: noteID)
        else { return }
        guard let handleFrame = restingLayoutSnapshot.handleFrames[noteID] else { return }
        let screen = targetScreen()
        let frame = panelFrame(for: note, handleFrame: handleFrame, edge: edge, screen: screen)
        panelControllers[noteID]?.reposition(
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

        for noteID in presentationState.iceNoteIDs {
            guard let note = note(withID: noteID),
                  let edge = edge(for: noteID)
            else { continue }
            guard let handleFrame = restingLayoutSnapshot.handleFrames[noteID] else { continue }
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
        restingLayoutSnapshot = EdgeLayoutEngine.layout(
            notes: activeNotes,
            groups: allGroups,
            defaultGroupID: store.defaultGroupID,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        layoutSnapshot = EdgeLayoutEngine.layout(
            notes: activeNotes.filter { !presentationState.isIce($0.id) },
            groups: allGroups,
            defaultGroupID: store.defaultGroupID,
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
            .filter { self.edge(for: $0) == edge }
            .reversed())
        let slot = newestFirst.firstIndex(of: note.id) ?? 0
        let groupFrame = allGroups
            .first { $0.edge == edge }
            .flatMap { layoutSnapshot.groupFrames[$0.id] }
        return EdgeLayoutEngine.icePanelFrame(
            edge: edge,
            slot: slot,
            indexGroupFrame: groupFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            storedWidth: note.panelSize?.cgSize.width
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
            guard let frame = layoutSnapshot.handleFrames[note.id],
                  let edge = edge(for: note.id)
            else { continue }
            if let controller = handleControllers[note.id] {
                controller.update(
                    note: note,
                    frame: frame,
                    edge: edge,
                    isSelected: presentationState.isPresented(note.id) || collapsingNoteIDs.contains(note.id),
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
        refreshControlFrames()
        applyIndexVisibility()
    }

    private func refreshControlFrames() {
        let screen = targetScreen()
        for edge in EdgeDock.allCases {
            let frames = activeNotes.compactMap { note -> CGRect? in
                guard self.edge(for: note.id) == edge else { return nil }
                return layoutSnapshot.handleFrames[note.id]
            }
            let frame = EdgeLayoutEngine.edgeControlFrame(
                edge: edge,
                handleFrames: frames,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
            controlControllers[edge]?.update(frame: frame)
        }
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
                isSelected: presentationState.isPresented(note.id) || collapsingNoteIDs.contains(note.id),
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
                self.indexVisibility = .visible(edge)
                self.applyIndexVisibility()
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
            guard let controller = handleControllers[note.id], let edge = edge(for: note.id) else { continue }
            let isAvailableAsIndex = !presentationState.isPresented(note.id)
                && !collapsingNoteIDs.contains(note.id)
            let requestedByVisibility: Bool
            switch indexVisibility {
            case .hidden:
                requestedByVisibility = false
            case let .visible(visibleEdge):
                requestedByVisibility = edge == visibleEdge
            case let .transitioning(noteID):
                requestedByVisibility = note.id == noteID
            case .dragging:
                requestedByVisibility = true
            }
            let shouldShow = requestedByVisibility && isAvailableAsIndex
            if shouldShow { controller.show() } else { controller.hide() }
        }
        for edge in EdgeDock.allCases {
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
        let screen = targetScreen()
        let overDeleteTarget = deleteDropZoneController.contains(point)
        deleteDropZoneController.setHighlighted(overDeleteTarget)
        let targetDock = EdgeLayoutEngine.dock(at: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        hotZoneController.setDragging(true, targetEdge: overDeleteTarget ? nil : targetDock)
        dropTargetGroupID = overDeleteTarget
            ? nil
            : targetDock.flatMap { edge in allGroups.first { $0.edge == edge }?.id }
        for candidate in activeNotes where candidate.id != note.id {
            guard let frame = layoutSnapshot.handleFrames[candidate.id],
                  let candidateEdge = edge(for: candidate.id)
            else { continue }
            handleControllers[candidate.id]?.update(
                note: candidate,
                frame: frame,
                edge: candidateEdge,
                isSelected: presentationState.isPresented(candidate.id),
                isDropTarget: candidate.placement.groupID == dropTargetGroupID
            )
        }
    }

    private func finishDrag(noteID: UUID, point: NSPoint) {
        if deleteDropZoneController.contains(point) {
            let restoreEdge = edge(for: noteID) ?? preferences.defaultEdge
            endDragInteraction()
            indexVisibility = .visible(restoreEdge)
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

        let targetGroupID = allGroups.first { $0.edge == edge }?.id
        let order = targetGroupID.map {
            EdgeLayoutEngine.insertionOrder(
                at: point,
                edge: edge,
                notes: activeNotes.filter { $0.id != noteID },
                groupID: $0,
                snapshot: layoutSnapshot
            )
        } ?? 0
        if var draft = draftNote, draft.id == noteID {
            if let targetGroupID {
                draft.placement = MemoPlacement(groupID: targetGroupID, order: order)
                draftGroup = nil
            } else {
                let group: MemoEdgeGroup
                if let existing = draftGroup {
                    var updated = existing
                    updated.edge = edge
                    updated.normalizedCenter = edge == .top ? 0.5 : 1
                    group = updated
                } else {
                    group = MemoEdgeGroup(edge: edge, normalizedCenter: edge == .top ? 0.5 : 1)
                }
                draftGroup = group
                draft.placement = MemoPlacement(groupID: group.id, order: 0)
            }
            draftNote = draft
        } else if !store.placeNote(
            noteID: noteID,
            edge: edge,
            normalizedCenter: edge == .top ? 0.5 : 1,
            mergeInto: targetGroupID,
            order: order
        ), let error = store.lastPersistenceError {
            showPersistenceAlert(error)
        }

        reloadNotes()
        indexVisibility = .visible(edge)
        refreshLayout()
    }

    private func endDragInteraction() {
        draggingNoteID = nil
        dropTargetGroupID = nil
        hotZoneController.setDragging(false)
        deleteDropZoneController.hide()
    }

    private func confirmDragDeletion(noteID: UUID) {
        guard let note = note(withID: noteID) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "‘\(note.displayTitle)’ 메모를 삭제할까?"
        alert.informativeText = "본문과 메모에 복사된 이미지가 함께 영구 삭제되며 되돌릴 수 없어."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
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
