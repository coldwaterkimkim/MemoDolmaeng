import AppKit

@MainActor
final class EdgeControlPanelController: NSWindowController {
    let edge: EdgeDock

    private let controlView: EdgeControlView
    private var targetFrame: CGRect = .zero
    private var shouldBeVisible = false

    init(
        edge: EdgeDock,
        onCreate: @escaping () -> Void,
        onPointerChange: @escaping (Bool) -> Void
    ) {
        self.edge = edge
        controlView = EdgeControlView()

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = controlView
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "새 메모"

        super.init(window: panel)
        controlView.onCreate = onCreate
        controlView.onPointerChange = onPointerChange
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frame: CGRect) {
        targetFrame = frame
        if shouldBeVisible {
            window?.setFrame(frame, display: true)
        }
    }

    func show(animated: Bool = true) {
        guard let window else { return }
        shouldBeVisible = true
        if !window.isVisible {
            window.setFrame(EdgeLayoutEngine.hiddenHandleFrame(for: targetFrame, edge: edge), display: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        guard animated else {
            window.setFrame(targetFrame, display: true)
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EdgeLayoutEngine.indexRevealDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            window.animator().setFrame(targetFrame, display: true)
            window.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard let window else { return }
        shouldBeVisible = false
        guard window.isVisible else { return }
        guard animated else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EdgeLayoutEngine.indexHideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            window.animator().setFrame(
                EdgeLayoutEngine.hiddenHandleFrame(for: targetFrame, edge: edge),
                display: true
            )
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, !self.shouldBeVisible else { return }
                window.orderOut(nil)
            }
        }
    }
}

private final class EdgeControlView: NSView {
    var onCreate: (() -> Void)?
    var onPointerChange: ((Bool) -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "새 메모"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("새 메모")
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

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onPointerChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onPointerChange?(false)
    }

    override func mouseUp(with event: NSEvent) {
        onCreate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.windowBackgroundColor.withAlphaComponent(hovering ? 0.96 : 0.84).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(hovering ? 0.38 : 0.22).setStroke()
        path.lineWidth = hovering ? 1.5 : 1
        path.stroke()

        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        symbol?.draw(
            in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.9
        )
    }
}
