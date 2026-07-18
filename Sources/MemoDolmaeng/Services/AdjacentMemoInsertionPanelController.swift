import AppKit

@MainActor
final class AdjacentMemoInsertionPanelController: NSWindowController {
    private let insertionView: AdjacentMemoInsertionView

    init(
        accessibilityLabel: String,
        onInsert: @escaping () -> Void,
        onPointerChange: @escaping (Bool) -> Void
    ) {
        insertionView = AdjacentMemoInsertionView()

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = insertionView
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = accessibilityLabel

        super.init(window: panel)
        insertionView.configure(
            accessibilityLabel: accessibilityLabel,
            onInsert: onInsert,
            onPointerChange: onPointerChange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frame: CGRect) {
        guard let window else { return }
        let alignedFrame = frame.integral
        guard alignedFrame.width > 0, alignedFrame.height > 0 else {
            window.orderOut(nil)
            return
        }
        window.setFrame(alignedFrame, display: window.isVisible)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func resetHover() {
        insertionView.resetHover()
    }
}

private final class AdjacentMemoInsertionView: NSView {
    private let glyphView = AdjacentMemoInsertionGlyphView()
    private var trackingAreaReference: NSTrackingArea?
    private var onInsert: (() -> Void)?
    private var onPointerChange: ((Bool) -> Void)?
    private var hovering = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphView.alphaValue = 0
        addSubview(glyphView)
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

    func configure(
        accessibilityLabel: String,
        onInsert: @escaping () -> Void,
        onPointerChange: @escaping (Bool) -> Void
    ) {
        self.onInsert = onInsert
        self.onPointerChange = onPointerChange
        toolTip = accessibilityLabel
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp("이 위치에 같은 색의 메모를 하나 더 만들어.")
    }

    override func layout() {
        super.layout()
        let diameter = min(
            EdgeLayoutEngine.adjacentInsertionDiameter,
            min(bounds.width, bounds.height)
        )
        glyphView.frame = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        ).integral
    }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        guard !hovering else { return }
        hovering = true
        onPointerChange?(true)
        updateGlyph(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        pressed = false
        onPointerChange?(false)
        updateGlyph(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        glyphView.pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        glyphView.pressed = false
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        resetHover()
        onInsert?()
    }

    override func accessibilityPerformPress() -> Bool {
        resetHover()
        onInsert?()
        return true
    }

    func resetHover() {
        hovering = false
        pressed = false
        glyphView.pressed = false
        updateGlyph(animated: false)
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        glyphView.needsDisplay = true
        updateGlyph(animated: false)
    }

    private func updateGlyph(animated: Bool) {
        let motion = EdgeMotionPolicy.current
        let targetAlpha: CGFloat = hovering ? 1 : 0
        guard animated else {
            glyphView.alphaValue = targetAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeDuration(0.11)
            context.timingFunction = motion.timingFunction(.easeOut)
            glyphView.animator().alphaValue = targetAlpha
        }
    }
}

private final class AdjacentMemoInsertionGlyphView: NSView {
    var pressed = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let motion = EdgeMotionPolicy.current
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        let fillAlpha: CGFloat = motion.reduceTransparency ? 1 : (pressed ? 0.98 : 0.90)
        NSColor.windowBackgroundColor.withAlphaComponent(fillAlpha).setFill()
        path.fill()

        if pressed {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        NSColor.labelColor.withAlphaComponent(motion.increaseContrast ? 0.62 : 0.28).setStroke()
        path.lineWidth = motion.increaseContrast ? 1.5 : 1
        path.stroke()

        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pressed ? 10.5 : 11, weight: .semibold))
        symbol?.draw(
            in: NSRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.92
        )
    }
}
