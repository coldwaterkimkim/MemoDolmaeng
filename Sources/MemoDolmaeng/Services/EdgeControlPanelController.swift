import AppKit

@MainActor
final class EdgeControlPanelController: NSWindowController {
    let edge: EdgeDock

    private let controlView: EdgeControlView
    private var targetFrame: CGRect = .zero
    private var shouldBeVisible = false
    private var visibilityGeneration = 0

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
    }

    func show(animated: Bool = true) {
        guard let window else { return }
        let motion = EdgeMotionPolicy.current
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if !window.isVisible {
            let initialFrame = motion.animatesGeometry
                ? EdgeLayoutEngine.hiddenHandleFrame(for: targetFrame, edge: edge)
                : targetFrame
            window.setFrame(initialFrame, display: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        guard animated else {
            window.setFrame(targetFrame, display: true)
            window.alphaValue = 1
            return
        }
        if !motion.animatesGeometry {
            window.setFrame(targetFrame, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.animatesGeometry
                ? motion.geometryDuration(EdgeLayoutEngine.indexRevealDuration)
                : motion.fadeDuration(EdgeLayoutEngine.indexRevealDuration)
            context.timingFunction = motion.timingFunction(.reveal)
            if motion.animatesGeometry {
                window.animator().setFrame(targetFrame, display: true)
            }
            window.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                window.alphaValue = 1
            }
        }
    }

    func hide(animated: Bool = true) {
        guard let window else { return }
        let motion = EdgeMotionPolicy.current
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard window.isVisible else { return }
        guard animated else {
            window.orderOut(nil)
            return
        }
        let hiddenFrame = EdgeLayoutEngine.hiddenHandleFrame(for: targetFrame, edge: edge)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.animatesGeometry
                ? motion.geometryDuration(EdgeLayoutEngine.indexHideDuration)
                : motion.fadeDuration(EdgeLayoutEngine.indexHideDuration)
            context.timingFunction = motion.timingFunction(.hide)
            if motion.animatesGeometry {
                window.animator().setFrame(hiddenFrame, display: true)
            }
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self,
                      !self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                window.orderOut(nil)
                window.setFrame(hiddenFrame, display: false)
                window.alphaValue = 0
            }
        }
    }
}

private final class EdgeControlView: NSView {
    var onCreate: (() -> Void)?
    var onPointerChange: ((Bool) -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var hovering = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "새 메모"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("새 메모")
        setAccessibilityHelp("새 메모를 만들어 현재 엣지에 ICE로 열어.")
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        pressed = false
        needsDisplay = true
        onPointerChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) { onCreate?() }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onCreate?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let motion = EdgeMotionPolicy.current
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let fillAlpha: CGFloat = motion.reduceTransparency
            ? 1
            : (pressed ? 0.98 : (hovering ? 0.96 : 0.84))
        NSColor.windowBackgroundColor.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        if pressed {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        let strokeAlpha: CGFloat = motion.increaseContrast
            ? (hovering || pressed ? 0.7 : 0.5)
            : (hovering || pressed ? 0.38 : 0.22)
        NSColor.labelColor.withAlphaComponent(strokeAlpha).setStroke()
        path.lineWidth = motion.increaseContrast
            ? (hovering || pressed ? 2 : 1.5)
            : (hovering || pressed ? 1.5 : 1)
        path.stroke()

        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pressed ? 11.5 : 12, weight: .semibold))
        symbol?.draw(
            in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.9
        )
    }
}
