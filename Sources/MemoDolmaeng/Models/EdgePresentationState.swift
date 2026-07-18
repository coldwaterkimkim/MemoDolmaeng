import Foundation

enum EdgeDock: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case top

    var id: String { rawValue }

    static let interactiveCases: [EdgeDock] = [.left, .right]

    var interactiveSide: EdgeDock {
        self == .left ? .left : .right
    }

    var title: String {
        switch self {
        case .left: "왼쪽"
        case .right: "오른쪽"
        case .top: "상단"
        }
    }
}

enum EdgeIndexVisibilityState: Equatable {
    case hidden
    case visible(EdgeDock)
    case transitioning(UUID)
    case dragging(UUID)
}

struct EdgeHotZoneID: Hashable {
    let screenIdentifier: String
    let displayID: UInt32?
    let edge: EdgeDock

    var interactiveSide: EdgeDock { edge.interactiveSide }
}

enum EdgeHotZoneToggleAction: Equatable {
    case show(EdgeHotZoneID)
    case hide
    case move(EdgeHotZoneID)
}

enum EdgeHotZoneToggleResolver {
    static func action(
        visibleZone: EdgeHotZoneID?,
        enteredZone: EdgeHotZoneID
    ) -> EdgeHotZoneToggleAction {
        guard let visibleZone else { return .show(enteredZone) }
        return visibleZone == enteredZone ? .hide : .move(enteredZone)
    }
}

enum MemoAdjacentDirection: Equatable {
    case left
    case right
}

struct EdgePresentationState: Equatable {
    var iceNoteIDs: [UUID]
    var focusedIceNoteID: UUID?

    init(iceNoteIDs: [UUID] = [], focusedIceNoteID: UUID? = nil) {
        self.iceNoteIDs = iceNoteIDs.reduce(into: []) { result, noteID in
            if !result.contains(noteID) { result.append(noteID) }
        }
        self.focusedIceNoteID = focusedIceNoteID.flatMap { self.iceNoteIDs.contains($0) ? $0 : nil }
            ?? self.iceNoteIDs.last
    }

    var currentNoteID: UUID? { focusedIceNoteID }
    var hasOpenPanels: Bool { !iceNoteIDs.isEmpty }

    func isIce(_ noteID: UUID) -> Bool {
        iceNoteIDs.contains(noteID)
    }

    func isPresented(_ noteID: UUID) -> Bool {
        isIce(noteID)
    }
}

enum EdgePresentationAction: Equatable {
    case click(UUID)
    case open(UUID)
    case close(UUID)
    case focus(UUID)
}

enum EdgePresentationReducer {
    static func reduce(
        state: EdgePresentationState,
        action: EdgePresentationAction
    ) -> EdgePresentationState {
        var next = state
        switch action {
        case let .click(noteID):
            if let index = next.iceNoteIDs.firstIndex(of: noteID) {
                next.iceNoteIDs.remove(at: index)
                if next.focusedIceNoteID == noteID {
                    next.focusedIceNoteID = next.iceNoteIDs.last
                }
            } else {
                next.iceNoteIDs.append(noteID)
                next.focusedIceNoteID = noteID
            }
        case let .open(noteID):
            next.iceNoteIDs.removeAll { $0 == noteID }
            next.iceNoteIDs.append(noteID)
            next.focusedIceNoteID = noteID
        case let .close(noteID):
            next.iceNoteIDs.removeAll { $0 == noteID }
            if next.focusedIceNoteID == noteID {
                next.focusedIceNoteID = next.iceNoteIDs.last
            }
        case let .focus(noteID):
            guard next.isIce(noteID) else { return next }
            next.focusedIceNoteID = noteID
        }
        if next.iceNoteIDs.isEmpty { next.focusedIceNoteID = nil }
        return next
    }
}
