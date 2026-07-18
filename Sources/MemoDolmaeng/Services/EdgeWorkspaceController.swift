import AppKit
import Combine
import Foundation

private struct RuntimeIceLane {
    let id: UUID
    let openedSequence: Int
    let motherNoteID: UUID
    var noteIDs: [UUID]
    var edge: EdgeDock
    var displayID: UInt32?
    var anchorY: CGFloat
    var horizontalAnchorNoteID: UUID
    var horizontalAnchorX: CGFloat?
    var motherColor: NoteColor
}

private struct RuntimeAdjacentInsertionKey: Hashable {
    let laneID: UUID
    let sourceNoteID: UUID
    let direction: MemoAdjacentDirection
}

private struct RuntimeAdjacentInsertionDescriptor {
    let key: RuntimeAdjacentInsertionKey
    let frame: CGRect
    let accessibilityLabel: String
}

private struct ReconciledIceEviction {
    let noteID: UUID
    let edge: EdgeDock
    let screen: NSScreen
}

@MainActor
final class EdgeWorkspaceController: ObservableObject {
    @Published private(set) var notes: [MemoNote]
    @Published private(set) var presentationState = EdgePresentationState()
    @Published private(set) var indexVisibility: EdgeIndexVisibilityState = .hidden

    let store: NoteStore
    let preferences: EdgePreferences

    var onPresentationChange: ((Bool) -> Void)?

    private let attachmentService: AttachmentService
    private let assetRootURL: URL
    private let hotZoneController = EdgeHotZoneController()
    private let deleteDropZoneController = DeleteDropZoneController()
    private var panelControllers: [UUID: MemoPanelController] = [:]
    private var adjacentInsertionControllers: [RuntimeAdjacentInsertionKey: AdjacentMemoInsertionPanelController] = [:]
    private var handleControllers: [UUID: EdgeHandlePanelController] = [:]
    private var controlControllers: [EdgeDock: EdgeControlPanelController] = [:]
    private var layoutSnapshot: EdgeLayoutSnapshot = .empty
    private var pointerInsideHandles: Set<UUID> = []
    private var pointerInsideHotZones: Set<EdgeHotZoneID> = []
    private var pointerInsideControls: Set<EdgeDock> = []
    private var visibleHotZoneID: EdgeHotZoneID?
    private var pendingEmptyNoteIDs: Set<UUID> = []
    private var pendingUnsavedContent: [UUID: String] = [:]
    private var iceEdges: [UUID: EdgeDock] = [:]
    private var iceLanes: [UUID: RuntimeIceLane] = [:]
    private var iceLaneIDByNoteID: [UUID: UUID] = [:]
    private var nextIceLaneSequence = 0
    private var hoveredAdjacentInsertion: RuntimeAdjacentInsertionKey?
    private var adjacentHoverGeneration = 0
    private var launcherEdge: EdgeDock = .right
    private var interactionDisplayID: UInt32?
    private var launcherAnchorY: [EdgeDock: CGFloat] = [:]
    private var draftNotes: [UUID: MemoNote] = [:]
    private var draggingNoteID: UUID?
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
        hotZoneController.onPointerChange = { [weak self] zoneID, inside in
            self?.handleHotZonePointer(zoneID: zoneID, inside: inside)
        }
        hotZoneController.onZonesRemoved = { [weak self] zoneIDs in
            self?.handleHotZonesRemoved(zoneIDs)
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
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        store.setDefaultEdge(preferences.defaultEdge)
        reloadNotes()
        refreshLayout()
    }

    func prepareForTermination() -> Bool {
        for controller in Array(panelControllers.values) {
            controller.flushPendingInput()
        }
        let presentedIDs = Set(presentationState.iceNoteIDs)
            .union(pendingEmptyNoteIDs)
            .union(pendingUnsavedContent.keys)
        for noteID in presentedIDs where !prepareContentForClosure(noteID: noteID) {
            return false
        }
        for noteID in presentedIDs { finalizeTransientState(noteID: noteID) }
        store.save()
        return true
    }

    func createNote() {
        createNote(on: preferences.defaultEdge)
    }

    func createNote(on edge: EdgeDock) {
        let side = edge.interactiveSide
        let draft = makeDraftNote()
        draftNotes[draft.id] = draft
        reloadNotes()
        refreshLayout()
        open(noteID: draft.id, on: side, focusEditor: true)
    }

    func createAdjacentMemo(to sourceNoteID: UUID, direction: MemoAdjacentDirection) {
        guard presentationState.isIce(sourceNoteID),
              let laneID = iceLaneIDByNoteID[sourceNoteID],
              var lane = iceLanes[laneID],
              let sourceIndex = lane.noteIDs.firstIndex(of: sourceNoteID)
        else { return }

        let screen = screen(for: lane)
        guard canAddAdjacentMemo(in: lane, on: screen) else { return }
        let sourceFrame = resolvedIcePanelFrames(
            on: screen,
            expandingHoveredGap: false
        )[sourceNoteID] ?? panelControllers[sourceNoteID]?.window?.frame
        guard let sourceFrame else { return }

        hoveredAdjacentInsertion = nil
        adjacentInsertionControllers.values.forEach { $0.resetHover() }
        let draft = makeDraftNote(color: lane.motherColor)
        draftNotes[draft.id] = draft
        let insertionIndex = direction == .left ? sourceIndex : sourceIndex + 1
        lane.noteIDs.insert(draft.id, at: insertionIndex)
        lane.horizontalAnchorNoteID = sourceNoteID
        lane.horizontalAnchorX = sourceFrame.minX
        iceLanes[laneID] = lane
        iceLaneIDByNoteID[draft.id] = laneID
        iceEdges[draft.id] = lane.edge
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .open(draft.id)
        )
        preferences.lastNoteID = draft.id
        indexVisibility = .hidden
        visibleHotZoneID = nil
        reloadNotes()
        refreshLayoutSnapshot()

        let finalFrame = resolvedIcePanelFrames(on: screen)[draft.id]
            ?? CGRect(
                x: sourceFrame.minX,
                y: sourceFrame.minY,
                width: min(EdgeLayoutEngine.panelWidth, screen.frame.width),
                height: EdgeLayoutEngine.fixedIcePanelHeight(visibleFrame: screen.visibleFrame)
            )
        let originX = direction == .left ? sourceFrame.minX : sourceFrame.maxX - EdgeLayoutEngine.sideHandleHeight
        let revealOrigin = CGRect(
            x: originX,
            y: sourceFrame.midY - EdgeLayoutEngine.sideHandleHeight / 2,
            width: EdgeLayoutEngine.sideHandleHeight,
            height: EdgeLayoutEngine.sideHandleHeight
        )
        let controller = panelController(for: draft.id)
        controller.show(
            note: draft,
            frame: finalFrame,
            handleFrame: revealOrigin,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            edge: lane.edge,
            focusEditor: true,
            onTitleChange: { [weak self] title in
                self?.handlePanelTitleChange(noteID: draft.id, title: title)
            }
        ) { [weak self] content in
            self?.handleContentChange(noteID: draft.id, content: content)
        }
        controller.setCollapseTargetFrame(collapseTargetFrame(for: draft, edge: lane.edge, screen: screen))
        refreshLayout(excludingPanelID: draft.id)
        onPresentationChange?(true)
    }

    func handleClick(noteID: UUID, on edge: EdgeDock? = nil) {
        if presentationState.isIce(noteID) {
            closeHorizontalLane(containing: noteID)
        } else {
            open(noteID: noteID, on: edge ?? launcherEdge, focusEditor: true)
        }
    }

    func handleDoubleClick(noteID: UUID, on edge: EdgeDock? = nil) {
        open(noteID: noteID, on: edge ?? launcherEdge, focusEditor: true)
    }

    func toggleRecent() {
        if let noteID = presentationState.focusedIceNoteID {
            closeHorizontalLane(containing: noteID)
            return
        }
        let candidate = preferences.lastNoteID.flatMap(note(withID:)) ?? orderedNotes.first
        if let candidate { open(noteID: candidate.id, on: preferences.defaultEdge, focusEditor: true) }
    }

    func toggleMode() {
        if let noteID = presentationState.focusedIceNoteID {
            closeHorizontalLane(containing: noteID)
        }
    }

    func closeMemo(noteID requestedNoteID: UUID? = nil) {
        if requestedNoteID == nil,
           let focusedID = presentationState.focusedIceNoteID {
            closeHorizontalLane(containing: focusedID)
            return
        }
        guard let closingID = requestedNoteID
            ?? presentationState.focusedIceNoteID
        else { return }
        guard prepareContentForClosure(noteID: closingID) else { return }
        let closingEdge = iceEdges[closingID] ?? preferences.defaultEdge.interactiveSide
        launcherEdge = closingEdge
        collapsingNoteIDs.insert(closingID)
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .close(closingID)
        )
        removeFromIceLane(noteID: closingID)
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
            if case .transitioning(closingID) = self.indexVisibility {
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

    private func closeHorizontalLane(containing noteID: UUID) {
        guard let laneID = iceLaneIDByNoteID[noteID],
              let lane = iceLanes[laneID]
        else {
            closeMemo(noteID: noteID)
            return
        }
        let closingIDs = lane.noteIDs.filter(presentationState.isIce)
        guard closingIDs.count > 1 else {
            closeMemo(noteID: noteID)
            return
        }

        for closingID in closingIDs {
            panelControllers[closingID]?.flushPendingInput()
        }
        guard closingIDs.allSatisfy({ prepareContentForClosure(noteID: $0) }) else { return }

        launcherEdge = lane.edge
        adjacentHoverGeneration += 1
        hoveredAdjacentInsertion = nil
        for closingID in closingIDs {
            collapsingNoteIDs.insert(closingID)
            presentationState = EdgePresentationReducer.reduce(
                state: presentationState,
                action: .close(closingID)
            )
        }
        removeIceLane(laneID: laneID)
        refreshLayout()
        refreshHandleSelection()

        for closingID in closingIDs {
            let controller = panelControllers[closingID]
            let targetFrame = layoutSnapshot.handleFrames[closingID]
            controller?.fold(to: targetFrame, completion: { [weak self, weak controller] in
                guard let self else { return }
                self.collapsingNoteIDs.remove(closingID)
                if self.panelControllers[closingID] === controller {
                    self.panelControllers.removeValue(forKey: closingID)
                }
                self.iceEdges.removeValue(forKey: closingID)
                self.refreshHandleSelection()
            })
            if controller == nil {
                collapsingNoteIDs.remove(closingID)
                iceEdges.removeValue(forKey: closingID)
            }
        }
        for closingID in closingIDs {
            finalizeTransientState(noteID: closingID)
        }
        onPresentationChange?(presentationState.hasOpenPanels)
    }

    func cycleNote(direction: Int) {
        let ordered = orderedNotes
        guard !ordered.isEmpty else { return }
        let currentIndex = presentationState.currentNoteID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        let next = (currentIndex + direction + ordered.count) % ordered.count
        let side = presentationState.currentNoteID.flatMap { iceEdges[$0] } ?? preferences.defaultEdge
        open(noteID: ordered[next].id, on: side, focusEditor: true)
    }

    func selectNote(at index: Int) {
        let ordered = orderedNotes
        guard ordered.indices.contains(index) else { return }
        let side = presentationState.currentNoteID.flatMap { iceEdges[$0] } ?? preferences.defaultEdge
        open(noteID: ordered[index].id, on: side, focusEditor: true)
    }

    func delete(noteID: UUID) {
        if draftNotes[noteID] != nil || pendingEmptyNoteIDs.contains(noteID) {
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
        if var draft = draftNotes[noteID] {
            draft.title = title
            draft.isTitleExplicit = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draftNotes[noteID] = draft
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
        var individualColor = color
        if let color,
           let laneID = runtimeLaneIDSharingColor(with: noteID) {
            guard updateMotherColor(in: laneID, color: color) else { return }
            individualColor = nil
        }
        guard individualColor != nil
                || textColorHex != nil
                || aspectRatio != nil
                || opacity != nil
        else { return }

        if var draft = draftNotes[noteID] {
            if let individualColor { draft.color = individualColor }
            if let textColorHex { draft.textColorHex = textColorHex }
            if let aspectRatio { draft.aspectRatio = aspectRatio }
            if let opacity { draft.opacity = opacity }
            draftNotes[noteID] = draft
            reloadNotes()
        } else {
            store.updateAppearance(
                noteID: noteID,
                color: individualColor,
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

    private var orderedNotes: [MemoNote] {
        // Keep the last visible legacy order until the user explicitly reorders the shared tray.
        let groups = store.edgeGroups.sorted {
            if $0.id == store.defaultGroupID { return true }
            if $1.id == store.defaultGroupID { return false }
            if $0.edge != $1.edge { return $0.edge.rawValue < $1.edge.rawValue }
            return $0.createdAt < $1.createdAt
        }
        let groupOrder = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
        return notes.sorted {
            let lhsGroup = groupOrder[$0.placement.groupID] ?? Int.max
            let rhsGroup = groupOrder[$1.placement.groupID] ?? Int.max
            if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
            return $0.placement.order < $1.placement.order
        }
    }

    var availableIndexNotes: [MemoNote] {
        orderedNotes.filter { !presentationState.isIce($0.id) }
    }

    private func open(
        noteID: UUID,
        on requestedEdge: EdgeDock? = nil,
        focusEditor: Bool = false
    ) {
        guard let note = note(withID: noteID) else { return }
        if presentationState.isIce(noteID) {
            focusIce(noteID: noteID)
            return
        }
        let edge = (requestedEdge ?? launcherEdge).interactiveSide
        let screen = targetScreen()
        let sameEdgeLanes = orderedLaneIDs(on: edge, displayID: screen.memoDisplayID)
        let evictedLaneID = sameEdgeLanes.count >= EdgeLayoutEngine.maxIcePerEdge
            ? sameEdgeLanes.first
            : nil
        let evictedIDs = evictedLaneID.flatMap { iceLanes[$0]?.noteIDs } ?? []
        collapsingNoteIDs.remove(noteID)
        launcherEdge = edge
        refreshLayoutSnapshot()

        guard let handleFrame = layoutSnapshot.handleFrames[noteID] else { return }
        for evictedID in evictedIDs {
            guard prepareContentForClosure(noteID: evictedID) else { return }
        }
        for evictedID in evictedIDs {
            collapsingNoteIDs.insert(evictedID)
            presentationState = EdgePresentationReducer.reduce(
                state: presentationState,
                action: .close(evictedID)
            )
        }
        if let evictedLaneID { removeIceLane(laneID: evictedLaneID) }

        let laneID = UUID()
        iceLanes[laneID] = RuntimeIceLane(
            id: laneID,
            openedSequence: nextIceLaneSequence,
            motherNoteID: noteID,
            noteIDs: [noteID],
            edge: edge,
            displayID: screen.memoDisplayID,
            anchorY: handleFrame.maxY,
            horizontalAnchorNoteID: noteID,
            horizontalAnchorX: nil,
            motherColor: note.color
        )
        nextIceLaneSequence += 1
        iceLaneIDByNoteID[noteID] = laneID
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .open(noteID)
        )
        iceEdges[noteID] = edge
        launcherEdge = edge
        indexVisibility = .hidden
        visibleHotZoneID = nil
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
        for evictedID in evictedIDs {
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
        controller.onFold = { [weak self] in self?.closeHorizontalLane(containing: noteID) }
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
        controller.onDidBecomeKey = { [weak self] requestedNoteID in
            self?.handlePanelFocus(noteID: requestedNoteID)
        }
        panelControllers[noteID] = controller
        return controller
    }

    private func refreshAdjacentInsertionControls() {
        var descriptors: [RuntimeAdjacentInsertionKey: RuntimeAdjacentInsertionDescriptor] = [:]
        for lane in iceLanes.values {
            let screen = screen(for: lane)
            guard canAddAdjacentMemo(in: lane, on: screen) else { continue }
            let frames = resolvedIcePanelFrames(on: screen)
            let noteIDs = lane.noteIDs.filter {
                presentationState.isIce($0) && frames[$0] != nil
            }
            guard let firstID = noteIDs.first,
                  let lastID = noteIDs.last,
                  let firstFrame = frames[firstID],
                  let lastFrame = frames[lastID]
            else { continue }

            let outerWidth = EdgeLayoutEngine.adjacentInsertionOuterWidth
            let leadingKey = RuntimeAdjacentInsertionKey(
                laneID: lane.id,
                sourceNoteID: firstID,
                direction: .left
            )
            descriptors[leadingKey] = RuntimeAdjacentInsertionDescriptor(
                key: leadingKey,
                frame: CGRect(
                    x: firstFrame.minX - outerWidth,
                    y: firstFrame.minY,
                    width: outerWidth,
                    height: firstFrame.height
                ),
                accessibilityLabel: "왼쪽에 메모 추가"
            )

            for (index, sourceID) in noteIDs.enumerated() {
                guard let sourceFrame = frames[sourceID] else { continue }
                let key = RuntimeAdjacentInsertionKey(
                    laneID: lane.id,
                    sourceNoteID: sourceID,
                    direction: .right
                )
                let descriptor: RuntimeAdjacentInsertionDescriptor
                if index == noteIDs.count - 1 {
                    descriptor = RuntimeAdjacentInsertionDescriptor(
                        key: key,
                        frame: CGRect(
                            x: lastFrame.maxX,
                            y: lastFrame.minY,
                            width: outerWidth,
                            height: lastFrame.height
                        ),
                        accessibilityLabel: "오른쪽에 메모 추가"
                    )
                } else if let nextFrame = frames[noteIDs[index + 1]] {
                    descriptor = RuntimeAdjacentInsertionDescriptor(
                        key: key,
                        frame: CGRect(
                            x: sourceFrame.maxX,
                            y: sourceFrame.minY,
                            width: max(1, nextFrame.minX - sourceFrame.maxX),
                            height: min(sourceFrame.height, nextFrame.height)
                        ),
                        accessibilityLabel: "두 메모 사이에 추가"
                    )
                } else {
                    continue
                }
                descriptors[key] = descriptor
            }
        }

        let desiredKeys = Set(descriptors.keys)
        for (key, controller) in adjacentInsertionControllers where !desiredKeys.contains(key) {
            controller.close()
            adjacentInsertionControllers.removeValue(forKey: key)
        }
        if let hoveredAdjacentInsertion, !desiredKeys.contains(hoveredAdjacentInsertion) {
            self.hoveredAdjacentInsertion = nil
        }

        for descriptor in descriptors.values {
            let controller: AdjacentMemoInsertionPanelController
            if let existing = adjacentInsertionControllers[descriptor.key] {
                controller = existing
            } else {
                let key = descriptor.key
                controller = AdjacentMemoInsertionPanelController(
                    accessibilityLabel: descriptor.accessibilityLabel,
                    onInsert: { [weak self] in
                        self?.createAdjacentMemo(
                            to: key.sourceNoteID,
                            direction: key.direction
                        )
                    },
                    onPointerChange: { [weak self] inside in
                        self?.handleAdjacentInsertionPointer(key: key, inside: inside)
                    }
                )
                controller.window?.identifier = NSUserInterfaceItemIdentifier(
                    "adjacent-insertion-\(key.laneID.uuidString)-\(key.sourceNoteID.uuidString)-\(key.direction == .left ? "left" : "right")"
                )
                adjacentInsertionControllers[key] = controller
            }
            controller.update(frame: descriptor.frame)
        }
    }

    private func handleAdjacentInsertionPointer(
        key: RuntimeAdjacentInsertionKey,
        inside: Bool
    ) {
        guard let lane = iceLanes[key.laneID],
              let sourceIndex = lane.noteIDs.firstIndex(of: key.sourceNoteID)
        else { return }
        let isInternalSeam = key.direction == .right && sourceIndex < lane.noteIDs.count - 1
        guard isInternalSeam else { return }

        if inside {
            adjacentHoverGeneration += 1
            guard hoveredAdjacentInsertion != key else { return }
            let previousLaneID = hoveredAdjacentInsertion?.laneID
            hoveredAdjacentInsertion = key
            refreshHorizontalLanePresentation(
                laneIDs: Set([previousLaneID, key.laneID].compactMap { $0 })
            )
        } else if hoveredAdjacentInsertion == key {
            adjacentHoverGeneration += 1
            let generation = adjacentHoverGeneration
            let delay: Duration = EdgeMotionPolicy.current.reduceMotion
                ? .zero
                : .milliseconds(90)
            Task { @MainActor [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard let self,
                      self.adjacentHoverGeneration == generation,
                      self.hoveredAdjacentInsertion == key
                else { return }
                self.hoveredAdjacentInsertion = nil
                self.refreshHorizontalLanePresentation(laneIDs: [key.laneID])
            }
        }
    }

    private func refreshHorizontalLanePresentation(laneIDs: Set<UUID>) {
        for laneID in laneIDs {
            guard let lane = iceLanes[laneID] else { continue }
            let screen = screen(for: lane)
            let frames = resolvedIcePanelFrames(on: screen)
            for noteID in lane.noteIDs {
                guard let note = note(withID: noteID),
                      let frame = frames[noteID]
                else { continue }
                let handleFrame = collapseTargetFrame(for: note, edge: lane.edge, screen: screen)
                panelControllers[noteID]?.reposition(
                    frame: frame,
                    handleFrame: handleFrame,
                    screenFrame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    edge: lane.edge,
                    animatedDuration: EdgeLayoutEngine.adjacentInsertionMotionDuration
                )
            }
        }
        refreshAdjacentInsertionControls()
    }

    private func prepareIndexHandoff(noteID: UUID) {
        collapsingNoteIDs.remove(noteID)
        guard case .transitioning(noteID) = indexVisibility else { return }
        refreshHandleSelection()
        handleControllers[noteID]?.show(animated: false)
    }

    private func focusIce(noteID: UUID) {
        guard presentationState.isIce(noteID) else { return }
        handlePanelFocus(noteID: noteID)
        panelControllers[noteID]?.window?.makeKeyAndOrderFront(nil)
    }

    private func handlePanelFocus(noteID: UUID) {
        guard presentationState.isIce(noteID) else { return }
        presentationState = EdgePresentationReducer.reduce(
            state: presentationState,
            action: .focus(noteID)
        )
        preferences.lastNoteID = noteID
    }

    private func handleContentChange(noteID: UUID, content: String) {
        if var draft = draftNotes[noteID] {
            draft.content = content
            draft.updatedAt = Date()
            draftNotes[noteID] = draft
            guard MemoNote.hasMeaningfulContent(content) else {
                reloadNotes()
                return
            }
            do {
                _ = try store.commitDraft(draft)
                draftNotes.removeValue(forKey: noteID)
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
            if let error = store.lastPersistenceError {
                let wasAlreadyPending = pendingUnsavedContent[noteID] != nil
                pendingUnsavedContent[noteID] = content
                reloadNotes()
                if !wasAlreadyPending { showPersistenceAlert(error) }
                return
            }
            pendingUnsavedContent.removeValue(forKey: noteID)
            reloadNotes()
        } else {
            pendingUnsavedContent.removeValue(forKey: noteID)
            pendingEmptyNoteIDs.insert(noteID)
            reloadNotes()
            if let index = notes.firstIndex(where: { $0.id == noteID }) {
                notes[index].content = ""
            }
        }
    }

    private func handlePanelTitleChange(noteID: UUID, title: String) {
        if var draft = draftNotes[noteID] {
            draft.title = title
            draft.isTitleExplicit = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draftNotes[noteID] = draft
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
        if var draft = draftNotes[noteID] {
            let storedHeight = draft.panelSize?.cgSize.height ?? MemoPanelSize.minimum.height
            draft.panelSize = MemoPanelSize(width: size.width, height: storedHeight)
            draftNotes[noteID] = draft
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
        let screen = screen(forNoteID: noteID)
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
        hotZoneController.update(screens: hotZoneScreens())
        let reconciledEvictions = reconcileIceLaneDisplays()
        refreshLayoutSnapshot()
        refreshHandles()

        for noteID in presentationState.iceNoteIDs {
            guard noteID != excludingPanelID else { continue }
            guard let note = note(withID: noteID),
                  let edge = iceEdges[noteID]
            else { continue }
            let screen = screen(forNoteID: noteID)
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
        refreshAdjacentInsertionControls()
        for eviction in reconciledEvictions {
            foldEvictedIce(
                noteID: eviction.noteID,
                edge: eviction.edge,
                screen: eviction.screen
            )
        }
        if !reconciledEvictions.isEmpty {
            onPresentationChange?(presentationState.hasOpenPanels)
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
        resolvedIcePanelFrames(on: screen)[note.id]
            ?? EdgeLayoutEngine.panelFrame(
                adjacentTo: handleFrame,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                edge: edge,
                aspectRatio: note.aspectRatio.value,
                panelSize: note.panelSize
            )
    }

    private func resolvedIcePanelFrames(
        on screen: NSScreen,
        expandingHoveredGap: Bool = true
    ) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for edge in EdgeDock.interactiveCases {
            let laneIDs = orderedLaneIDs(on: edge, displayID: screen.memoDisplayID)
            let items = laneIDs.compactMap { laneID -> EdgeIceLaneLayoutItem? in
                guard let lane = iceLanes[laneID] else { return nil }
                return EdgeIceLaneLayoutItem(id: lane.id, preferredTopY: lane.anchorY)
            }
            let verticalFrames = EdgeLayoutEngine.iceLaneFrames(
                edge: edge,
                items: items,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )

            for laneID in laneIDs {
                guard let lane = iceLanes[laneID],
                      let verticalFrame = verticalFrames[laneID]
                else { continue }
                let laneNotes = lane.noteIDs.compactMap(note(withID:))
                guard !laneNotes.isEmpty else { continue }
                let horizontalBounds = screen.visibleFrame.insetBy(
                    dx: min(
                        EdgeLayoutEngine.adjacentInsertionOuterWidth
                            + EdgeHotZoneSpatialResolver.activationThickness,
                        max(0, screen.visibleFrame.width / 4)
                    ),
                    dy: 0
                )
                let expandedGapAfterID: UUID?
                if expandingHoveredGap,
                   let hoveredAdjacentInsertion,
                   hoveredAdjacentInsertion.laneID == laneID,
                   hoveredAdjacentInsertion.direction == .right,
                   let sourceIndex = lane.noteIDs.firstIndex(of: hoveredAdjacentInsertion.sourceNoteID),
                   sourceIndex < lane.noteIDs.count - 1 {
                    expandedGapAfterID = hoveredAdjacentInsertion.sourceNoteID
                } else {
                    expandedGapAfterID = nil
                }
                let horizontalFrames = EdgeLayoutEngine.horizontalLaneFrames(
                    items: laneNotes.map {
                        EdgeHorizontalLaneLayoutItem(
                            id: $0.id,
                            requestedWidth: requestedPanelWidth(for: $0, screen: screen)
                        )
                    },
                    edge: edge,
                    horizontalBounds: horizontalBounds,
                    y: verticalFrame.minY,
                    height: verticalFrame.height,
                    anchorID: lane.horizontalAnchorNoteID,
                    anchorMinX: lane.horizontalAnchorX,
                    expandedGapAfterID: expandedGapAfterID
                )
                result.merge(horizontalFrames) { _, new in new }
            }
        }
        return result
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
        let noteIDs = Set(notes.map(\.id))
        for (id, controller) in handleControllers where !noteIDs.contains(id) {
            controller.close()
            handleControllers.removeValue(forKey: id)
            pointerInsideHandles.remove(id)
        }
        for (id, controller) in panelControllers where !noteIDs.contains(id)
            && !collapsingNoteIDs.contains(id) {
            controller.close()
            panelControllers.removeValue(forKey: id)
        }

        for note in notes {
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
        for note in notes where note.id != draggingNoteID {
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

    private func handleHotZonePointer(zoneID: EdgeHotZoneID, inside: Bool) {
        if inside {
            guard draggingNoteID == nil,
                  pointerInsideHotZones.insert(zoneID).inserted
            else { return }
            switch EdgeHotZoneToggleResolver.action(
                visibleZone: visibleHotZoneID,
                enteredZone: zoneID
            ) {
            case let .show(target), let .move(target):
                if visibleHotZoneID != nil { hideTrayImmediately() }
                let side = target.interactiveSide
                interactionDisplayID = target.displayID
                launcherAnchorY[side] = NSEvent.mouseLocation.y
                launcherEdge = side
                visibleHotZoneID = target
                indexVisibility = .visible(side)
                refreshLayout()
            case .hide:
                visibleHotZoneID = nil
                indexVisibility = .hidden
                applyIndexVisibility()
            }
        } else {
            pointerInsideHotZones.remove(zoneID)
        }
    }

    private func handleHotZonesRemoved(_ zoneIDs: Set<EdgeHotZoneID>) {
        pointerInsideHotZones.subtract(zoneIDs)
        guard let visibleHotZoneID, zoneIDs.contains(visibleHotZoneID) else { return }
        self.visibleHotZoneID = nil
        if interactionDisplayID == visibleHotZoneID.displayID {
            interactionDisplayID = nil
        }
        indexVisibility = .hidden
        applyIndexVisibility()
    }

    private func handleControlPointer(edge: EdgeDock, inside: Bool) {
        if inside {
            pointerInsideControls.insert(edge)
        } else {
            pointerInsideControls.remove(edge)
        }
    }

    private func handleIndexPointer(noteID: UUID, inside: Bool) {
        if inside {
            pointerInsideHandles.insert(noteID)
        } else {
            pointerInsideHandles.remove(noteID)
        }
    }

    private func applyIndexVisibility() {
        for note in notes {
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
        for candidate in notes where candidate.id != note.id {
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

        let remaining = orderedNotes.filter {
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
        let mergedOrder = orderedNotes.compactMap { note -> UUID? in
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

        if var draft = draftNotes[noteID] {
            draft.attachments.append(attachment)
            draft.updatedAt = Date()
            draftNotes[noteID] = draft
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
        if let draft = draftNotes[noteID] {
            for attachment in draft.attachments {
                attachmentService.removeImportedAttachment(
                    noteID: noteID,
                    fileName: attachment.fileName
                )
            }
            draftNotes.removeValue(forKey: noteID)
            reloadNotes()
            refreshLayout()
            return
        }
        if pendingEmptyNoteIDs.remove(noteID) != nil {
            permanentDelete(noteID: noteID)
        }
    }

    private func prepareContentForClosure(noteID: UUID) -> Bool {
        if let draft = draftNotes[noteID],
           MemoNote.hasMeaningfulContent(draft.content) || !draft.attachments.isEmpty {
            do {
                _ = try store.commitDraft(draft)
                draftNotes.removeValue(forKey: noteID)
                reloadNotes()
            } catch {
                showPersistenceAlert(error)
                return false
            }
        }

        if let pendingContent = pendingUnsavedContent[noteID] {
            store.updateContent(noteID: noteID, content: pendingContent)
            if let error = store.lastPersistenceError {
                showPersistenceAlert(error)
                return false
            }
            pendingUnsavedContent.removeValue(forKey: noteID)
            reloadNotes()
        }
        return true
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

    private func runtimeLaneIDSharingColor(with noteID: UUID) -> UUID? {
        if let laneID = iceLaneIDByNoteID[noteID] { return laneID }
        return iceLanes.values.first(where: { $0.motherNoteID == noteID })?.id
    }

    @discardableResult
    private func updateMotherColor(in laneID: UUID, color: NoteColor) -> Bool {
        guard var lane = iceLanes[laneID] else { return false }
        let relatedIDs = Set(lane.noteIDs + [lane.motherNoteID])
        let storedIDs = Set(store.notes.map(\.id)).intersection(relatedIDs)
        guard store.updateColor(noteIDs: storedIDs, color: color) else {
            if let error = store.lastPersistenceError { showPersistenceAlert(error) }
            return false
        }

        for noteID in relatedIDs {
            guard var draft = draftNotes[noteID] else { continue }
            draft.color = color
            draftNotes[noteID] = draft
        }
        lane.motherColor = color
        iceLanes[laneID] = lane
        reloadNotes()
        refreshLayout()
        return true
    }

    private func makeDraftNote(color: NoteColor? = nil) -> MemoNote {
        let timestamp = Date()
        let placementGroupID = store.defaultGroupID
        return MemoNote(
            title: "새 메모",
            content: "",
            color: color ?? NoteColor.randomMemoColor(
                excluding: notes.max(by: { $0.updatedAt < $1.updatedAt })?.color
            ),
            placement: MemoPlacement(
                groupID: placementGroupID,
                order: nextOrder(in: placementGroupID)
            ),
            aspectRatio: .portrait,
            opacity: preferences.defaultOpacity,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func orderedLaneIDs(on edge: EdgeDock, displayID: UInt32?) -> [UUID] {
        iceLanes.values
            .filter { lane in
                lane.edge == edge
                    && lane.displayID == displayID
                    && lane.noteIDs.contains(where: presentationState.isIce)
            }
            .sorted { $0.openedSequence < $1.openedSequence }
            .map(\.id)
    }

    private func removeFromIceLane(noteID: UUID) {
        guard let laneID = iceLaneIDByNoteID.removeValue(forKey: noteID),
              var lane = iceLanes[laneID]
        else { return }
        if hoveredAdjacentInsertion?.laneID == laneID {
            hoveredAdjacentInsertion = nil
        }
        lane.noteIDs.removeAll { $0 == noteID }
        guard !lane.noteIDs.isEmpty else {
            iceLanes.removeValue(forKey: laneID)
            return
        }
        if lane.horizontalAnchorNoteID == noteID {
            lane.horizontalAnchorNoteID = lane.noteIDs[0]
            lane.horizontalAnchorX = panelControllers[lane.noteIDs[0]]?.window?.frame.minX
        }
        iceLanes[laneID] = lane
    }

    private func removeIceLane(laneID: UUID) {
        guard let lane = iceLanes.removeValue(forKey: laneID) else { return }
        if hoveredAdjacentInsertion?.laneID == laneID {
            hoveredAdjacentInsertion = nil
        }
        for noteID in lane.noteIDs {
            iceLaneIDByNoteID.removeValue(forKey: noteID)
        }
    }

    private func requestedPanelWidth(for note: MemoNote, screen: NSScreen) -> CGFloat {
        min(
            min(MemoPanelSize.maximum.width, screen.frame.width),
            max(MemoPanelSize.minimum.width, note.panelSize?.cgSize.width ?? EdgeLayoutEngine.panelWidth)
        )
    }

    private func canAddAdjacentMemo(in lane: RuntimeIceLane, on screen: NSScreen) -> Bool {
        let currentWidths = lane.noteIDs.compactMap(note(withID:)).map {
            requestedPanelWidth(for: $0, screen: screen)
        }
        let requestedNewWidth = min(EdgeLayoutEngine.panelWidth, screen.frame.width)
        let total = currentWidths.reduce(0, +)
            + requestedNewWidth
            + EdgeLayoutEngine.laneGap * CGFloat(currentWidths.count)
        let horizontalInset = min(
            EdgeLayoutEngine.adjacentInsertionOuterWidth
                + EdgeHotZoneSpatialResolver.activationThickness,
            max(0, screen.visibleFrame.width / 4)
        )
        return total <= screen.visibleFrame.width - horizontalInset * 2 + 0.001
    }

    private func nextOrder(in groupID: UUID) -> Int {
        (notes.filter { $0.placement.groupID == groupID }.map(\.placement.order).max() ?? -1) + 1
    }

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        let candidates = screens.map {
            EdgeScreenCandidate(displayID: $0.memoDisplayID, frame: $0.frame, isMain: $0 == NSScreen.main)
        }
        let index = EdgeScreenSelector.selectedIndex(
            candidates: candidates,
            preferredDisplayID: preferences.targetDisplayID ?? interactionDisplayID,
            pointer: NSEvent.mouseLocation
        ) ?? 0
        return screens[index]
    }

    private func screen(for lane: RuntimeIceLane) -> NSScreen {
        if let displayID = lane.displayID,
           let screen = NSScreen.screens.first(where: { $0.memoDisplayID == displayID }) {
            return screen
        }
        return targetScreen()
    }

    private func screen(forNoteID noteID: UUID) -> NSScreen {
        guard let laneID = iceLaneIDByNoteID[noteID],
              let lane = iceLanes[laneID]
        else { return targetScreen() }
        return screen(for: lane)
    }

    private func reconcileIceLaneDisplays() -> [ReconciledIceEviction] {
        let availableDisplayIDs = Set(NSScreen.screens.compactMap(\.memoDisplayID))
        guard !iceLanes.isEmpty else { return [] }
        let fallbackDisplayID = targetScreen().memoDisplayID
        for (laneID, var lane) in iceLanes {
            if let displayID = lane.displayID, availableDisplayIDs.contains(displayID) { continue }
            lane.displayID = fallbackDisplayID
            iceLanes[laneID] = lane
        }

        var evictions: [ReconciledIceEviction] = []
        let displayIDs = Set(iceLanes.values.map(\.displayID))
        for displayID in displayIDs {
            for edge in EdgeDock.interactiveCases {
                let lanes = iceLanes.values
                    .filter {
                        $0.displayID == displayID
                            && $0.edge == edge
                            && $0.noteIDs.contains(where: presentationState.isIce)
                    }
                    .sorted { $0.openedSequence < $1.openedSequence }
                let overflowCount = max(0, lanes.count - EdgeLayoutEngine.maxIcePerEdge)
                for lane in lanes.prefix(overflowCount) {
                    let noteIDs = lane.noteIDs.filter(presentationState.isIce)
                    guard noteIDs.allSatisfy({ prepareContentForClosure(noteID: $0) }) else {
                        continue
                    }
                    let fallbackScreen = screen(for: lane)
                    for noteID in noteIDs {
                        collapsingNoteIDs.insert(noteID)
                        presentationState = EdgePresentationReducer.reduce(
                            state: presentationState,
                            action: .close(noteID)
                        )
                        evictions.append(
                            ReconciledIceEviction(
                                noteID: noteID,
                                edge: edge,
                                screen: fallbackScreen
                            )
                        )
                    }
                    removeIceLane(laneID: lane.id)
                }
            }
        }
        return evictions
    }

    private func hotZoneScreens() -> [EdgeHotZoneScreen] {
        let screens = NSScreen.screens
        let eligible: [NSScreen]
        if let fixedDisplayID = preferences.targetDisplayID,
           let fixedScreen = screens.first(where: { $0.memoDisplayID == fixedDisplayID }) {
            eligible = [fixedScreen]
        } else {
            eligible = screens
        }
        return eligible.enumerated().map { index, screen in
            EdgeHotZoneScreen(
                identifier: screen.memoDisplayID.map(String.init) ?? "fallback-\(index)",
                displayID: screen.memoDisplayID,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private func reloadNotes() {
        notes = store.notes
        for (noteID, content) in pendingUnsavedContent {
            if let index = notes.firstIndex(where: { $0.id == noteID }) {
                notes[index].content = content
            }
        }
        for noteID in pendingEmptyNoteIDs {
            if let index = notes.firstIndex(where: { $0.id == noteID }) { notes[index].content = "" }
        }
        notes.append(contentsOf: draftNotes.values.sorted { $0.createdAt < $1.createdAt })
    }

    private func showPersistenceAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "메모를 저장하지 못했어"
        alert.informativeText = "기존 저장 파일은 유지했어.\n\n오류: \(error.localizedDescription)"
        alert.runModal()
    }
}
