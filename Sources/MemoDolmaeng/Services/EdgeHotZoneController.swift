import AppKit

@MainActor
final class EdgeHotZoneController {
    private var panels: [EdgeDock: NSPanel] = [:]
    private var views: [EdgeDock: EdgeHotZoneView] = [:]
    private var screenFrame: CGRect = .zero
    private var visibleFrame: CGRect = .zero

    var onPointerChange: ((EdgeDock, Bool) -> Void)?

    init() {
        for edge in EdgeDock.interactiveCases {
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
            view.onPointerChange = { [weak self] inside in self?.onPointerChange?(edge, inside) }
            panels[edge] = panel
            views[edge] = view
        }
    }

    func update(screenFrame: CGRect, visibleFrame: CGRect) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        setDragging(false)
        for panel in panels.values { panel.orderFrontRegardless() }
    }

    func setDragging(_ dragging: Bool, targetEdge: EdgeDock? = nil) {
        let thickness: CGFloat = dragging ? 20 : 2
        for edge in EdgeDock.interactiveCases {
            panels[edge]?.setFrame(
                EdgeLayoutEngine.hotZoneFrame(
                    edge: edge,
                    thickness: thickness,
                    screenFrame: screenFrame,
                    visibleFrame: visibleFrame
                ),
                display: true
            )
            views[edge]?.setDragHighlight(dragging, isTarget: edge == targetEdge)
        }
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
