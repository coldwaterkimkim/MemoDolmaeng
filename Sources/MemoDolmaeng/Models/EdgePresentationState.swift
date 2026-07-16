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
    var peekNoteID: UUID?
    var iceNoteIDs: [UUID]

    init(peekNoteID: UUID? = nil, iceNoteIDs: [UUID] = []) {
        self.peekNoteID = peekNoteID
        self.iceNoteIDs = iceNoteIDs.reduce(into: []) { result, noteID in
            if !result.contains(noteID) { result.append(noteID) }
        }
    }

    var focusedIceNoteID: UUID? { iceNoteIDs.last }
    var currentNoteID: UUID? { peekNoteID ?? focusedIceNoteID }
    var hasOpenPanels: Bool { peekNoteID != nil || !iceNoteIDs.isEmpty }

    func isIce(_ noteID: UUID) -> Bool {
        iceNoteIDs.contains(noteID)
    }

    func isPresented(_ noteID: UUID) -> Bool {
        peekNoteID == noteID || isIce(noteID)
    }
}

enum EdgePresentationAction: Equatable {
    case hover(UUID)
    case click(UUID)
    case doubleClick(UUID)
    case toggleMode
    case close(UUID)
    case focus(UUID)
    case clearPeek
}

enum EdgePresentationReducer {
    static func reduce(
        state: EdgePresentationState,
        action: EdgePresentationAction
    ) -> EdgePresentationState {
        var next = state
        switch action {
        case let .hover(noteID):
            guard !next.isIce(noteID) else { return next }
            next.peekNoteID = noteID
        case let .click(noteID):
            next.peekNoteID = nil
            if let index = next.iceNoteIDs.firstIndex(of: noteID) {
                next.iceNoteIDs.remove(at: index)
            } else {
                next.iceNoteIDs.append(noteID)
            }
        case let .doubleClick(noteID):
            next.peekNoteID = nil
            next.iceNoteIDs.removeAll { $0 == noteID }
            next.iceNoteIDs.append(noteID)
        case .toggleMode:
            if let noteID = next.peekNoteID {
                next.peekNoteID = nil
                next.iceNoteIDs.removeAll { $0 == noteID }
                next.iceNoteIDs.append(noteID)
            } else if let noteID = next.iceNoteIDs.popLast() {
                next.peekNoteID = noteID
            }
        case let .close(noteID):
            if next.peekNoteID == noteID { next.peekNoteID = nil }
            next.iceNoteIDs.removeAll { $0 == noteID }
        case let .focus(noteID):
            guard next.isIce(noteID) else { return next }
            next.iceNoteIDs.removeAll { $0 == noteID }
            next.iceNoteIDs.append(noteID)
        case .clearPeek:
            next.peekNoteID = nil
        }
        return next
    }
}
