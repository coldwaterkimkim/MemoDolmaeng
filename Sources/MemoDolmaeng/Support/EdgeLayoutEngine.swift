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
    static let groupGap: CGFloat = 7
    static let mergeDistance: CGFloat = 12
    static let edgeDropDistance: CGFloat = 28
    static let panelWidth: CGFloat = 340
    static let maxIcePerEdge = 3
    static let panelRevealDuration: TimeInterval = 0.22
    static let panelHideDuration: TimeInterval = 0.18
    static let panelSwitchDuration: TimeInterval = 0.18
    static let contentSwitchDuration: TimeInterval = 0.10
    static let indexRevealDuration: TimeInterval = 0.16
    static let indexHideDuration: TimeInterval = 0.12
    static let indexSlideDistance: CGFloat = 14
    static let panelCornerRadius: CGFloat = 12
    static let handleCornerRadius: CGFloat = 9
    static let titleBarHeight: CGFloat = 38
    static let edgeControlSize = CGSize(width: 34, height: 26)
    static let deleteDropSize = CGSize(width: 116, height: 54)

    static func hotZoneFrame(
        edge: EdgeDock,
        thickness: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        switch edge {
        case .left:
            CGRect(
                x: screenFrame.minX,
                y: visibleFrame.minY,
                width: thickness,
                height: visibleFrame.height
            )
        case .right:
            CGRect(
                x: screenFrame.maxX - thickness,
                y: visibleFrame.minY,
                width: thickness,
                height: visibleFrame.height
            )
        case .top:
            .zero
        }
    }

    static func launcherLayout(
        notes: [MemoNote],
        edge: EdgeDock,
        anchorY: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeLayoutSnapshot {
        let side = edge.interactiveSide
        let ordered = notes
        guard !ordered.isEmpty else { return .empty }

        let height = min(sideHandleHeight, visibleFrame.height / CGFloat(ordered.count))
        let totalHeight = height * CGFloat(ordered.count)
        let centeredTop = anchorY + totalHeight / 2
        let top = min(
            visibleFrame.maxY,
            max(visibleFrame.minY + totalHeight, centeredTop)
        )
        var y = top
        var frames: [UUID: CGRect] = [:]
        for note in ordered {
            y -= height
            let width = sideHandleWidth(for: note.displayTitle)
            let x = side == .right ? screenFrame.maxX - width : screenFrame.minX
            frames[note.id] = CGRect(x: x, y: y, width: width, height: height)
        }
        return EdgeLayoutSnapshot(handleFrames: frames, groupFrames: [:])
    }

    static func launcherControlFrame(
        edge: EdgeDock,
        anchorY: CGFloat,
        handleFrames: [CGRect],
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let side = edge.interactiveSide
        let x = side == .right ? screenFrame.maxX - edgeControlSize.width : screenFrame.minX
        guard let first = handleFrames.first else {
            let y = min(
                visibleFrame.maxY - edgeControlSize.height,
                max(visibleFrame.minY, anchorY - edgeControlSize.height / 2)
            )
            return CGRect(origin: CGPoint(x: x, y: y), size: edgeControlSize)
        }
        let union = handleFrames.dropFirst().reduce(first) { $0.union($1) }
        let below = union.minY - groupGap - edgeControlSize.height
        let y = below >= visibleFrame.minY
            ? below
            : min(visibleFrame.maxY - edgeControlSize.height, union.maxY + groupGap)
        return CGRect(origin: CGPoint(x: x, y: y), size: edgeControlSize)
    }

    static func launcherInsertionOrder(
        at point: CGPoint,
        orderedNotes: [MemoNote],
        snapshot: EdgeLayoutSnapshot
    ) -> Int {
        for (index, note) in orderedNotes.enumerated() {
            guard let frame = snapshot.handleFrames[note.id] else { continue }
            if point.y > frame.midY { return index }
        }
        return orderedNotes.count
    }

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
        defaultGroupID _: UUID,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeLayoutSnapshot {
        guard !notes.isEmpty else { return .empty }

        var handleFrames: [UUID: CGRect] = [:]
        var groupFrames: [UUID: CGRect] = [:]
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })

        for edge in EdgeDock.allCases {
            let edgeNotes = notes
                .filter { groupsByID[$0.placement.groupID]?.edge == edge }
                .sorted {
                    if $0.placement.order != $1.placement.order {
                        return $0.placement.order < $1.placement.order
                    }
                    return $0.createdAt < $1.createdAt
                }
            guard !edgeNotes.isEmpty else { continue }

            if edge == .top {
                let requested = edgeNotes.map { topHandleWidth(for: $0.displayTitle) }
                let widths = compressedLengths(requested, available: visibleFrame.width)
                let totalWidth = widths.reduce(0, +)
                var x = visibleFrame.midX - totalWidth / 2
                for (note, width) in zip(edgeNotes, widths) {
                    handleFrames[note.id] = CGRect(
                        x: x,
                        y: visibleFrame.maxY - topHandleHeight,
                        width: width,
                        height: topHandleHeight
                    )
                    x += width
                }
            } else {
                let height = min(sideHandleHeight, visibleFrame.height / CGFloat(edgeNotes.count))
                var y = visibleFrame.maxY
                for note in edgeNotes {
                    y -= height
                    let width = sideHandleWidth(for: note.displayTitle)
                    let x = edge == .right ? screenFrame.maxX - width : screenFrame.minX
                    handleFrames[note.id] = CGRect(x: x, y: y, width: width, height: height)
                }
            }

            let frames = edgeNotes.compactMap { handleFrames[$0.id] }
            if let first = frames.first {
                let union = frames.dropFirst().reduce(first) { $0.union($1) }
                for groupID in Set(edgeNotes.map(\.placement.groupID)) {
                    groupFrames[groupID] = union
                }
            }
        }

        return EdgeLayoutSnapshot(handleFrames: handleFrames, groupFrames: groupFrames)
    }

    static func icePanelFrame(
        edge: EdgeDock,
        slot: Int,
        itemCount: Int,
        newestAnchorY: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        storedWidth: CGFloat?
    ) -> CGRect {
        let safeCount = min(maxIcePerEdge, max(1, itemCount))
        let safeSlot = min(safeCount - 1, max(0, slot))
        let requestedWidth = storedWidth ?? panelWidth
        let width = min(
            min(MemoPanelSize.maximum.width, visibleFrame.width),
            max(MemoPanelSize.minimum.width, requestedWidth)
        )
        let anchorTop = min(
            visibleFrame.maxY,
            max(visibleFrame.minY + titleBarHeight, newestAnchorY)
        )

        // Keep the newest ICE at the clicked index. Older ICE panels fill the
        // space below first, then spill above when the lower edge is full.
        // The shared height shrinks only as much as needed to keep every panel
        // visible and non-overlapping.
        let olderCount = safeCount - 1
        var belowCount = 0
        var panelHeight: CGFloat = 1
        for candidateBelow in 0...olderCount {
            let candidateAbove = olderCount - candidateBelow
            let belowHeight = (anchorTop - visibleFrame.minY) / CGFloat(candidateBelow + 1)
            let aboveHeight = candidateAbove == 0
                ? .greatestFiniteMagnitude
                : (visibleFrame.maxY - anchorTop) / CGFloat(candidateAbove)
            let candidateHeight = min(visibleFrame.height / CGFloat(maxIcePerEdge), belowHeight, aboveHeight)
            if candidateHeight > panelHeight + 0.5
                || (abs(candidateHeight - panelHeight) <= 0.5 && candidateBelow > belowCount) {
                panelHeight = candidateHeight
                belowCount = candidateBelow
            }
        }

        let slotTop: CGFloat
        let slotBottom: CGFloat
        if safeSlot == 0 {
            slotTop = anchorTop
            slotBottom = anchorTop - panelHeight
        } else if safeSlot <= belowCount {
            slotTop = anchorTop - panelHeight * CGFloat(safeSlot)
            slotBottom = anchorTop - panelHeight * CGFloat(safeSlot + 1)
        } else {
            let aboveOffset = safeSlot - belowCount - 1
            slotBottom = anchorTop + panelHeight * CGFloat(aboveOffset)
            slotTop = slotBottom + panelHeight
        }
        let roundedTop = slotTop.rounded()
        let roundedBottom = slotBottom.rounded()
        let x: CGFloat
        switch edge {
        case .left:
            x = screenFrame.minX
        case .right:
            x = screenFrame.maxX - width
        case .top:
            x = min(max(visibleFrame.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        }
        return CGRect(
            x: x,
            y: roundedBottom,
            width: width,
            height: max(1, roundedTop - roundedBottom)
        )
    }

    static func panelFrame(
        adjacentTo handleFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock,
        aspectRatio: CGFloat,
        panelSize: MemoPanelSize? = nil
    ) -> CGRect {
        let maximumWidth = max(1, min(MemoPanelSize.maximum.width, screenFrame.width))
        let minimumWidth = min(MemoPanelSize.minimum.width, maximumWidth)
        let requestedWidth = panelSize?.cgSize.width ?? panelWidth
        let width = min(
            maximumWidth,
            max(minimumWidth, max(requestedWidth, handleFrame.width))
        )

        let maximumHeight = max(1, min(MemoPanelSize.maximum.height, visibleFrame.height))
        let minimumHeight = min(MemoPanelSize.minimum.height, maximumHeight)
        let requestedHeight = panelSize?.cgSize.height ?? width / max(0.1, aspectRatio)
        let height = min(maximumHeight, max(minimumHeight, requestedHeight))

        switch edge {
        case .right:
            let availableHeight = max(titleBarHeight, handleFrame.maxY - visibleFrame.minY)
            let dockedHeight = min(height, availableHeight)
            return CGRect(
                x: screenFrame.maxX - width,
                y: handleFrame.maxY - dockedHeight,
                width: width,
                height: dockedHeight
            )
        case .left:
            let availableHeight = max(titleBarHeight, handleFrame.maxY - visibleFrame.minY)
            let dockedHeight = min(height, availableHeight)
            return CGRect(
                x: screenFrame.minX,
                y: handleFrame.maxY - dockedHeight,
                width: width,
                height: dockedHeight
            )
        case .top:
            let x = min(
                max(handleFrame.midX - width / 2, visibleFrame.minX),
                visibleFrame.maxX - width
            )
            let y = visibleFrame.maxY - height
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    static func panelTitleBarFrame(in panelFrame: CGRect) -> CGRect {
        let height = min(titleBarHeight, panelFrame.height)
        return CGRect(
            x: panelFrame.minX,
            y: panelFrame.maxY - height,
            width: panelFrame.width,
            height: height
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

    static func hiddenHandleFrame(for frame: CGRect, edge: EdgeDock) -> CGRect {
        switch edge {
        case .left:
            frame.offsetBy(dx: -indexSlideDistance, dy: 0)
        case .right:
            frame.offsetBy(dx: indexSlideDistance, dy: 0)
        case .top:
            frame.offsetBy(dx: 0, dy: frame.height + 8)
        }
    }

    static func dock(
        at point: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> EdgeDock? {
        let candidates: [(EdgeDock, CGFloat)] = [
            (.left, abs(point.x - screenFrame.minX)),
            (.right, abs(point.x - screenFrame.maxX))
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
            .filter { $0.placement.groupID == groupID }
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
            return visibleFrame.minY...visibleFrame.maxY
        case .top:
            return visibleFrame.minX...visibleFrame.maxX
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
