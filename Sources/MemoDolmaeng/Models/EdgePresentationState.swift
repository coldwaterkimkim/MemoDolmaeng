import Foundation

enum EdgeDock: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case top

    var id: String { rawValue }

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

struct EdgePresentationState: Equatable {
    var iceNoteIDs: [UUID]

    init(iceNoteIDs: [UUID] = []) {
        self.iceNoteIDs = iceNoteIDs.reduce(into: []) { result, noteID in
            if !result.contains(noteID) { result.append(noteID) }
        }
    }

    var focusedIceNoteID: UUID? { iceNoteIDs.last }
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
            } else {
                next.iceNoteIDs.append(noteID)
            }
        case let .open(noteID):
            next.iceNoteIDs.removeAll { $0 == noteID }
            next.iceNoteIDs.append(noteID)
        case let .close(noteID):
            next.iceNoteIDs.removeAll { $0 == noteID }
        case let .focus(noteID):
            guard next.isIce(noteID) else { return next }
            next.iceNoteIDs.removeAll { $0 == noteID }
            next.iceNoteIDs.append(noteID)
        }
        return next
    }
}
