import CoreGraphics
import Foundation

struct EdgeLayoutSnapshot: Equatable {
    var handleFrames: [UUID: CGRect]
    var groupFrames: [UUID: CGRect]

    static let empty = EdgeLayoutSnapshot(handleFrames: [:], groupFrames: [:])
}

enum EdgeLayoutEngine {
    static let sideHandleHeight: CGFloat = 26
    static let topHandleHeight: CGFloat = 26
    static let groupGap: CGFloat = 6
    static let mergeDistance: CGFloat = 12
    static let edgeDropDistance: CGFloat = 28
    static let panelWidth: CGFloat = 340
    static let panelRevealDuration: TimeInterval = 0.22
    static let panelHideDuration: TimeInterval = 0.18
    static let panelSwitchDuration: TimeInterval = 0.14
    static let contentSwitchDuration: TimeInterval = 0.10
    static let indexRevealDuration: TimeInterval = 0.16
    static let indexHideDuration: TimeInterval = 0.12
    static let indexSlideDistance: CGFloat = 14
    static let panelCornerRadius: CGFloat = 10
    static let handleCornerRadius: CGFloat = 9
    static let edgeControlSize = CGSize(width: 34, height: 26)
    static let deleteDropSize = CGSize(width: 76, height: 54)

    static func sideHandleWidth(for title: String) -> CGFloat {
        let count = max(1, min(MemoNote.maxTitleLength, title.count))
        return max(64, min(320, CGFloat(count * 11 + 24)))
    }

    static func topHandleWidth(for title: String) -> CGFloat {
        max(64, min(240, CGFloat(max(1, min(MemoNote.maxTitleLength, title.count)) * 11 + 20)))
    }

    static func edgeControlFrame(
        edge: EdgeDock,
        handleFrames: [CGRect],
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = edgeControlSize
        switch edge {
        case .left, .right:
            let x = edge == .right ? screenFrame.maxX - size.width : screenFrame.minX
            guard let union = handleFrames.first.map({ first in
                handleFrames.dropFirst().reduce(first) { $0.union($1) }
            }) else {
                return CGRect(x: x, y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
            }
            let below = union.minY - groupGap - size.height
            let y = below >= visibleFrame.minY
                ? below
                : min(visibleFrame.maxY - size.height, union.maxY + groupGap)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        case .top:
            guard let union = handleFrames.first.map({ first in
                handleFrames.dropFirst().reduce(first) { $0.union($1) }
            }) else {
                return CGRect(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.maxY - size.height,
                    width: size.width,
                    height: size.height
                )
            }
            let after = union.maxX + groupGap
            let x = after + size.width <= visibleFrame.maxX
                ? after
                : max(visibleFrame.minX, union.minX - groupGap - size.width)
            return CGRect(x: x, y: visibleFrame.maxY - size.height, width: size.width, height: size.height)
        }
    }

    static func deleteDropFrame(visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - deleteDropSize.width / 2,
            y: visibleFrame.minY + 18,
            width: deleteDropSize.width,
            height: deleteDropSize.height
        )
    }

    static func layout(
        notes: [MemoNote],
        groups: [MemoEdgeGroup],
        defaultGroupID: UUID,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeLayoutSnapshot {
        let activeNotes = notes.filter(\.isActive)
        guard !activeNotes.isEmpty else { return .empty }

        var handleFrames: [UUID: CGRect] = [:]
        var groupFrames: [UUID: CGRect] = [:]

        for edge in EdgeDock.allCases {
            let edgeGroups = groups
                .filter { group in
                    group.edge == edge && activeNotes.contains { $0.placement.groupID == group.id }
                }
                .sorted {
                    if $0.id == defaultGroupID { return false }
                    if $1.id == defaultGroupID { return true }
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            let axisRange = usableAxisRange(edge: edge, visibleFrame: visibleFrame)
            let edgeNotes = activeNotes.filter { note in
                edgeGroups.contains { $0.id == note.placement.groupID }
            }
            let fittedLengthByNoteID = fittedLengths(
                for: edgeNotes,
                edge: edge,
                available: axisRange.upperBound - axisRange.lowerBound,
                groupCount: edgeGroups.count
            )
            var occupied: [ClosedRange<CGFloat>] = []

            for group in edgeGroups {
                let groupNotes = activeNotes
                    .filter { $0.placement.groupID == group.id }
                    .sorted {
                        if $0.placement.order != $1.placement.order {
                            return $0.placement.order < $1.placement.order
                        }
                        return $0.createdAt < $1.createdAt
                    }
                guard !groupNotes.isEmpty else { continue }

                var lengths = groupNotes.map { fittedLengthByNoteID[$0.id] ?? 1 }
                var totalLength = lengths.reduce(0, +)
                let desiredCenter = axisRange.lowerBound
                    + CGFloat(group.normalizedCenter) * (axisRange.upperBound - axisRange.lowerBound)
                var desiredOrigin = desiredCenter - totalLength / 2
                var origin = resolvedOrigin(
                    desired: desiredOrigin,
                    length: totalLength,
                    axisRange: axisRange,
                    occupied: occupied
                )
                if origin == nil,
                   let segment = availableSegments(axisRange: axisRange, occupied: occupied)
                    .filter({ $0.upperBound - $0.lowerBound >= CGFloat(lengths.count) })
                    .max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) {
                    lengths = compressedLengths(
                        lengths,
                        available: segment.upperBound - segment.lowerBound
                    )
                    totalLength = lengths.reduce(0, +)
                    desiredOrigin = desiredCenter - totalLength / 2
                    origin = resolvedOrigin(
                        desired: desiredOrigin,
                        length: totalLength,
                        axisRange: axisRange,
                        occupied: occupied
                    )
                }
                guard let origin else { continue }
                occupied.append(origin...(origin + totalLength))

                if edge == .top {
                    var x = origin
                    for (note, width) in zip(groupNotes, lengths) {
                        handleFrames[note.id] = CGRect(
                            x: x,
                            y: visibleFrame.maxY - topHandleHeight,
                            width: width,
                            height: topHandleHeight
                        )
                        x += width
                    }
                } else {
                    var y = origin + totalLength
                    for (note, height) in zip(groupNotes, lengths) {
                        y -= height
                        let width = sideHandleWidth(for: note.displayTitle)
                        let x = edge == .right
                            ? screenFrame.maxX - width
                            : screenFrame.minX
                        handleFrames[note.id] = CGRect(x: x, y: y, width: width, height: height)
                    }
                }

                let frames = groupNotes.compactMap { handleFrames[$0.id] }
                if let first = frames.first {
                    groupFrames[group.id] = frames.dropFirst().reduce(first) { $0.union($1) }
                }
            }
        }

        return EdgeLayoutSnapshot(handleFrames: handleFrames, groupFrames: groupFrames)
    }

    static func panelFrame(
        adjacentTo handleFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock,
        aspectRatio: CGFloat,
        panelSize: MemoPanelSize? = nil
    ) -> CGRect {
        let maximumWidth = max(1, min(MemoPanelSize.maximum.width, visibleFrame.width))
        let minimumWidth = min(MemoPanelSize.minimum.width, maximumWidth)
        let requestedWidth = panelSize?.cgSize.width ?? panelWidth
        let width = min(maximumWidth, max(minimumWidth, requestedWidth))

        let maximumHeight = max(1, min(MemoPanelSize.maximum.height, visibleFrame.height))
        let minimumHeight = min(MemoPanelSize.minimum.height, maximumHeight)
        let requestedHeight = panelSize?.cgSize.height ?? width / max(0.1, aspectRatio)
        let height = min(maximumHeight, max(minimumHeight, requestedHeight))

        switch edge {
        case .right:
            let y = min(max(handleFrame.maxY - height, visibleFrame.minY), visibleFrame.maxY - height)
            return CGRect(x: handleFrame.minX - width, y: y, width: width, height: height)
        case .left:
            let y = min(max(handleFrame.maxY - height, visibleFrame.minY), visibleFrame.maxY - height)
            return CGRect(x: handleFrame.maxX, y: y, width: width, height: height)
        case .top:
            let x = min(
                max(handleFrame.midX - width / 2, visibleFrame.minX),
                visibleFrame.maxX - width
            )
            let y = max(visibleFrame.minY, handleFrame.minY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    static func unifiedSurfaceFrame(bodyFrame: CGRect, handleFrame: CGRect) -> CGRect {
        bodyFrame.union(handleFrame)
    }

    static func bodySize(
        fromSurfaceSize surfaceSize: CGSize,
        handleSize: CGSize,
        edge: EdgeDock
    ) -> CGSize {
        let rawSize: CGSize
        switch edge {
        case .left, .right:
            rawSize = CGSize(
                width: surfaceSize.width - handleSize.width,
                height: surfaceSize.height
            )
        case .top:
            rawSize = CGSize(
                width: surfaceSize.width,
                height: surfaceSize.height - handleSize.height
            )
        }
        return CGSize(
            width: min(MemoPanelSize.maximum.width, max(MemoPanelSize.minimum.width, rawSize.width)),
            height: min(MemoPanelSize.maximum.height, max(MemoPanelSize.minimum.height, rawSize.height))
        )
    }

    static func collapsedPanelFrame(
        for frame: CGRect,
        edge: EdgeDock,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        switch edge {
        case .right:
            return CGRect(
                x: screenFrame.maxX + 8,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        case .left:
            return CGRect(
                x: screenFrame.minX - frame.width - 8,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        case .top:
            return CGRect(
                x: frame.minX,
                y: visibleFrame.maxY + 8,
                width: frame.width,
                height: frame.height
            )
        }
    }

    static func panelRevealAnchorRect(
        panelFrame: CGRect,
        handleFrame: CGRect,
        edge: EdgeDock
    ) -> CGRect {
        let localHandle = handleFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)

        switch edge {
        case .right:
            let height = min(panelFrame.height, max(1, handleFrame.height))
            let y = min(max(0, localHandle.minY), panelFrame.height - height)
            return CGRect(x: max(0, panelFrame.width - 2), y: y, width: 2, height: height)
        case .left:
            let height = min(panelFrame.height, max(1, handleFrame.height))
            let y = min(max(0, localHandle.minY), panelFrame.height - height)
            return CGRect(x: 0, y: y, width: 2, height: height)
        case .top:
            let width = min(panelFrame.width, max(1, handleFrame.width))
            let x = min(max(0, localHandle.minX), panelFrame.width - width)
            return CGRect(x: x, y: max(0, panelFrame.height - 2), width: width, height: 2)
        }
    }

    static func hiddenHandleFrame(for frame: CGRect, edge: EdgeDock) -> CGRect {
        switch edge {
        case .left:
            frame.offsetBy(dx: -indexSlideDistance, dy: 0)
        case .right:
            frame.offsetBy(dx: indexSlideDistance, dy: 0)
        case .top:
            frame.offsetBy(dx: 0, dy: indexSlideDistance)
        }
    }

    static func dock(
        at point: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeDock? {
        let candidates: [(EdgeDock, CGFloat)] = [
            (.left, abs(point.x - screenFrame.minX)),
            (.right, abs(point.x - screenFrame.maxX)),
            (.top, abs(point.y - visibleFrame.maxY))
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= edgeDropDistance else {
            return nil
        }
        return nearest.0
    }

    static func normalizedCenter(
        at point: CGPoint,
        edge: EdgeDock,
        visibleFrame: CGRect
    ) -> Double {
        let value: CGFloat
        switch edge {
        case .left, .right:
            value = (point.y - visibleFrame.minY) / max(1, visibleFrame.height)
        case .top:
            value = (point.x - visibleFrame.minX) / max(1, visibleFrame.width)
        }
        return Double(max(0, min(1, value)))
    }

    static func mergeTarget(
        at point: CGPoint,
        edge: EdgeDock,
        excluding groupID: UUID?,
        groups: [MemoEdgeGroup],
        snapshot: EdgeLayoutSnapshot
    ) -> UUID? {
        groups
            .filter { $0.edge == edge && $0.id != groupID }
            .compactMap { group -> (UUID, CGFloat)? in
                guard let frame = snapshot.groupFrames[group.id] else { return nil }
                let expanded = frame.insetBy(dx: -mergeDistance, dy: -mergeDistance)
                guard expanded.contains(point) else { return nil }
                return (group.id, distance(from: point, to: frame))
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    static func insertionOrder(
        at point: CGPoint,
        edge: EdgeDock,
        notes: [MemoNote],
        groupID: UUID,
        snapshot: EdgeLayoutSnapshot
    ) -> Int {
        let ordered = notes
            .filter { $0.isActive && $0.placement.groupID == groupID }
            .sorted { $0.placement.order < $1.placement.order }
        for (index, note) in ordered.enumerated() {
            guard let frame = snapshot.handleFrames[note.id] else { continue }
            let before = edge == .top ? point.x < frame.midX : point.y > frame.midY
            if before { return index }
        }
        return ordered.count
    }

    private static func fittedLengths(
        for notes: [MemoNote],
        edge: EdgeDock,
        available: CGFloat,
        groupCount: Int
    ) -> [UUID: CGFloat] {
        let natural = Dictionary(uniqueKeysWithValues: notes.map { note in
            let length = edge == .top ? topHandleWidth(for: note.displayTitle) : sideHandleHeight
            return (note.id, length)
        })
        let total = natural.values.reduce(0, +)
        let gapBudget = groupGap * CGFloat(max(0, groupCount - 1))
        let contentBudget = max(CGFloat(notes.count), available - gapBudget)
        guard total > contentBudget, total > 0 else { return natural }
        let scale = contentBudget / total
        return natural.mapValues { max(1, floor($0 * scale)) }
    }

    private static func usableAxisRange(edge: EdgeDock, visibleFrame: CGRect) -> ClosedRange<CGFloat> {
        switch edge {
        case .left, .right:
            visibleFrame.minY...visibleFrame.maxY
        case .top:
            visibleFrame.minX...visibleFrame.maxX
        }
    }

    private static func resolvedOrigin(
        desired: CGFloat,
        length: CGFloat,
        axisRange: ClosedRange<CGFloat>,
        occupied: [ClosedRange<CGFloat>]
    ) -> CGFloat? {
        availableSegments(axisRange: axisRange, occupied: occupied)
            .filter { $0.upperBound - $0.lowerBound >= length }
            .map { segment in
                max(segment.lowerBound, min(segment.upperBound - length, desired))
            }
            .min(by: { abs($0 - desired) < abs($1 - desired) })
    }

    private static func availableSegments(
        axisRange: ClosedRange<CGFloat>,
        occupied: [ClosedRange<CGFloat>]
    ) -> [ClosedRange<CGFloat>] {
        let sorted = occupied.sorted { $0.lowerBound < $1.lowerBound }
        var segments: [ClosedRange<CGFloat>] = []
        var cursor = axisRange.lowerBound
        for range in sorted {
            let end = min(axisRange.upperBound, range.lowerBound - groupGap)
            if end > cursor { segments.append(cursor...end) }
            cursor = max(cursor, range.upperBound + groupGap)
        }
        if axisRange.upperBound > cursor { segments.append(cursor...axisRange.upperBound) }
        return segments
    }

    private static func compressedLengths(_ lengths: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = lengths.reduce(0, +)
        guard total > available, total > 0 else { return lengths }
        let scale = available / total
        return lengths.map { max(1, floor($0 * scale)) }
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return hypot(dx, dy)
    }
}
