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
    case dragging(UUID)
}

enum EdgePresentationState: Equatable {
    case closed
    case peek(UUID)
    case ice(UUID)

    var noteID: UUID? {
        switch self {
        case .closed:
            nil
        case let .peek(noteID), let .ice(noteID):
            noteID
        }
    }

    var isIce: Bool {
        if case .ice = self { return true }
        return false
    }
}

enum EdgePresentationAction: Equatable {
    case click(UUID)
    case doubleClick(UUID)
    case toggleMode
}

enum EdgePresentationReducer {
    static func reduce(
        state: EdgePresentationState,
        action: EdgePresentationAction
    ) -> EdgePresentationState {
        switch action {
        case let .click(noteID):
            if state.noteID == noteID { return .closed }
            return state.isIce ? .ice(noteID) : .peek(noteID)
        case let .doubleClick(noteID):
            return .ice(noteID)
        case .toggleMode:
            guard let noteID = state.noteID else { return .closed }
            return state.isIce ? .peek(noteID) : .ice(noteID)
        }
    }
}
