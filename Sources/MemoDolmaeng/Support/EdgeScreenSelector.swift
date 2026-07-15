import CoreGraphics
import Foundation

struct EdgeScreenCandidate: Equatable {
    let displayID: UInt32?
    let frame: CGRect
    let isMain: Bool
}

enum EdgeScreenSelector {
    static func selectedIndex(
        candidates: [EdgeScreenCandidate],
        preferredDisplayID: UInt32?,
        pointer: CGPoint
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let preferredDisplayID,
           let index = candidates.firstIndex(where: { $0.displayID == preferredDisplayID }) {
            return index
        }
        if let index = candidates.firstIndex(where: { $0.frame.contains(pointer) }) {
            return index
        }
        return candidates.firstIndex(where: \.isMain) ?? candidates.indices.first
    }
}
