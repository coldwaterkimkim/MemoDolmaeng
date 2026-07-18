import AppKit

enum EdgeHotZoneSpatialResolver {
    static let activationThickness: CGFloat = 2
    static let rearmDistance: CGFloat = 12

    static func event(
        isLatched: Bool,
        verticalMatch: Bool,
        distance: CGFloat
    ) -> Bool? {
        if isLatched {
            return !verticalMatch || distance < 0 || distance >= rearmDistance
                ? false
                : nil
        }
        return verticalMatch && distance >= 0 && distance <= activationThickness
            ? true
            : nil
    }
}

struct EdgeHotZoneActivationSample {
    let zoneID: EdgeHotZoneID
    let screenFrame: CGRect
}

enum EdgeHotZoneSeamResolver {
    static func preferredZone(
        at point: CGPoint,
        candidates: [EdgeHotZoneActivationSample]
    ) -> EdgeHotZoneID? {
        guard candidates.count > 1 else { return candidates.first?.zoneID }
        let containing = candidates.filter { $0.screenFrame.contains(point) }
        return (containing.isEmpty ? candidates : containing)
            .sorted {
                if $0.zoneID.screenIdentifier != $1.zoneID.screenIdentifier {
                    return $0.zoneID.screenIdentifier < $1.zoneID.screenIdentifier
                }
                return $0.zoneID.edge.rawValue < $1.zoneID.edge.rawValue
            }
            .first?
            .zoneID
    }
}

struct EdgeHotZoneScreen {
    let identifier: String
    let displayID: UInt32?
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

@MainActor
final class EdgeHotZoneController {
    private var panels: [String: NSPanel] = [:]
    private var views: [String: EdgeHotZoneView] = [:]
    private var descriptors: [String: EdgeHotZoneScreen] = [:]
    private var edges: [String: EdgeDock] = [:]
    private var zoneIDs: [String: EdgeHotZoneID] = [:]
    private var latchedZoneIDs: Set<EdgeHotZoneID> = []
    private var isDragging = false
    private var dragTargetEdge: EdgeDock?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    var onPointerChange: ((EdgeHotZoneID, Bool) -> Void)?
    var onZonesRemoved: ((Set<EdgeHotZoneID>) -> Void)?

    init() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            Task { @MainActor in self?.refreshPointerState(at: NSEvent.mouseLocation) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPointerState(at: NSEvent.mouseLocation) }
        }
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func update(screens: [EdgeHotZoneScreen]) {
        let desiredKeys = Set(
            screens.flatMap { screen in
                EdgeDock.interactiveCases.map { key(screenIdentifier: screen.identifier, edge: $0) }
            }
        )
        var removedZoneIDs: Set<EdgeHotZoneID> = []
        for key in Array(panels.keys) where !desiredKeys.contains(key) {
            if let zoneID = zoneIDs[key] {
                removedZoneIDs.insert(zoneID)
                latchedZoneIDs.remove(zoneID)
                onPointerChange?(zoneID, false)
            }
            panels[key]?.close()
            panels.removeValue(forKey: key)
            views.removeValue(forKey: key)
            descriptors.removeValue(forKey: key)
            edges.removeValue(forKey: key)
            zoneIDs.removeValue(forKey: key)
        }
        if !removedZoneIDs.isEmpty { onZonesRemoved?(removedZoneIDs) }

        for screen in screens {
            for edge in EdgeDock.interactiveCases {
                let key = key(screenIdentifier: screen.identifier, edge: edge)
                descriptors[key] = screen
                edges[key] = edge
                zoneIDs[key] = EdgeHotZoneID(
                    screenIdentifier: screen.identifier,
                    displayID: screen.displayID,
                    edge: edge
                )
                if panels[key] == nil {
                    installPanel(key: key, screen: screen, edge: edge)
                }
            }
        }

        refreshPanelFrames()
        for panel in panels.values { panel.orderFrontRegardless() }
    }

    func setDragging(_ dragging: Bool, targetEdge: EdgeDock? = nil) {
        isDragging = dragging
        dragTargetEdge = targetEdge
        refreshPanelFrames()
        if !dragging { refreshPointerState(at: NSEvent.mouseLocation) }
    }

    private func refreshPanelFrames() {
        let thickness: CGFloat = isDragging ? 20 : EdgeHotZoneSpatialResolver.activationThickness
        for (key, panel) in panels {
            guard let screen = descriptors[key], let edge = edges[key] else { continue }
            let targetFrame = EdgeLayoutEngine.hotZoneFrame(
                edge: edge,
                thickness: thickness,
                screenFrame: screen.screenFrame,
                visibleFrame: screen.visibleFrame
            )
            if panel.frame != targetFrame {
                panel.setFrame(targetFrame, display: true)
            }
            views[key]?.setDragHighlight(isDragging, isTarget: edge == dragTargetEdge)
        }
    }

    private func refreshPointerState(at point: CGPoint) {
        guard !isDragging else { return }
        var activationSamples: [EdgeHotZoneActivationSample] = []
        for (key, zoneID) in zoneIDs {
            guard let screen = descriptors[key], let edge = edges[key] else { continue }
            let verticalMatch = point.y >= screen.visibleFrame.minY
                && point.y <= screen.visibleFrame.maxY
            let distance: CGFloat
            switch edge {
            case .left:
                distance = point.x - screen.screenFrame.minX
            case .right:
                distance = screen.screenFrame.maxX - point.x
            case .top:
                continue
            }

            if verticalMatch,
               distance >= 0,
               distance <= EdgeHotZoneSpatialResolver.activationThickness {
                activationSamples.append(
                    EdgeHotZoneActivationSample(zoneID: zoneID, screenFrame: screen.screenFrame)
                )
            }

            if EdgeHotZoneSpatialResolver.event(
                isLatched: latchedZoneIDs.contains(zoneID),
                verticalMatch: verticalMatch,
                distance: distance
            ) == false {
                if latchedZoneIDs.remove(zoneID) != nil {
                    onPointerChange?(zoneID, false)
                }
            }
        }

        guard let preferredZoneID = EdgeHotZoneSeamResolver.preferredZone(
            at: point,
            candidates: activationSamples
        ) else { return }
        for sample in activationSamples where sample.zoneID != preferredZoneID {
            if latchedZoneIDs.remove(sample.zoneID) != nil {
                onPointerChange?(sample.zoneID, false)
            }
        }
        if latchedZoneIDs.insert(preferredZoneID).inserted {
            onPointerChange?(preferredZoneID, true)
        }
    }

    private func installPanel(key: String, screen: EdgeHotZoneScreen, edge: EdgeDock) {
        let view = EdgeHotZoneView(edge: edge)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        // Keep the 2pt activation strip above the visible index and + control.
        // Otherwise those panels cover the strip and a deliberate second edge
        // entry cannot toggle the tray closed.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panels[key] = panel
        views[key] = view
    }

    private func key(screenIdentifier: String, edge: EdgeDock) -> String {
        "\(screenIdentifier):\(edge.rawValue)"
    }
}

private final class EdgeHotZoneView: NSView {
    let edge: EdgeDock
    private var dragging = false
    private var isTarget = false

    init(edge: EdgeDock) {
        self.edge = edge
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDragHighlight(_ dragging: Bool, isTarget: Bool) {
        self.dragging = dragging
        self.isTarget = isTarget
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard dragging else { return }
        (isTarget ? NSColor.controlAccentColor.withAlphaComponent(0.32) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
        bounds.fill()
    }
}
