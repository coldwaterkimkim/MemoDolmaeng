import AppKit

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

    var onPointerChange: ((EdgeDock, UInt32?, Bool) -> Void)?

    func update(screens: [EdgeHotZoneScreen]) {
        let desiredKeys = Set(
            screens.flatMap { screen in
                EdgeDock.interactiveCases.map { key(screenIdentifier: screen.identifier, edge: $0) }
            }
        )
        for key in Array(panels.keys) where !desiredKeys.contains(key) {
            if let edge = edges[key], let screen = descriptors[key] {
                onPointerChange?(edge, screen.displayID, false)
            }
            panels[key]?.close()
            panels.removeValue(forKey: key)
            views.removeValue(forKey: key)
            descriptors.removeValue(forKey: key)
            edges.removeValue(forKey: key)
        }

        for screen in screens {
            for edge in EdgeDock.interactiveCases {
                let key = key(screenIdentifier: screen.identifier, edge: edge)
                descriptors[key] = screen
                edges[key] = edge
                if panels[key] == nil {
                    installPanel(key: key, screen: screen, edge: edge)
                }
            }
        }

        setDragging(false)
        for panel in panels.values { panel.orderFrontRegardless() }
    }

    func setDragging(_ dragging: Bool, targetEdge: EdgeDock? = nil) {
        let thickness: CGFloat = dragging ? 20 : 2
        for (key, panel) in panels {
            guard let screen = descriptors[key], let edge = edges[key] else { continue }
            panel.setFrame(
                EdgeLayoutEngine.hotZoneFrame(
                    edge: edge,
                    thickness: thickness,
                    screenFrame: screen.screenFrame,
                    visibleFrame: screen.visibleFrame
                ),
                display: true
            )
            views[key]?.setDragHighlight(dragging, isTarget: edge == targetEdge)
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
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.onPointerChange = { [weak self] inside in
            self?.onPointerChange?(edge, screen.displayID, inside)
        }
        panels[key] = panel
        views[key] = view
    }

    private func key(screenIdentifier: String, edge: EdgeDock) -> String {
        "\(screenIdentifier):\(edge.rawValue)"
    }
}

private final class EdgeHotZoneView: NSView {
    let edge: EdgeDock
    var onPointerChange: ((Bool) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var dragging = false
    private var isTarget = false

    init(edge: EdgeDock) {
        self.edge = edge
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onPointerChange?(true) }
    override func mouseExited(with event: NSEvent) { onPointerChange?(false) }

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
