import AppKit

@MainActor
final class EdgeHandlePanelController: NSWindowController {
    let noteID: UUID

    private let handleView: EdgeHandleContentView
    private var edge: EdgeDock
    private var targetFrame: CGRect
    private var shouldBeVisible = false
    private var visibilityGeneration = 0

    init(
        note: MemoNote,
        frame: CGRect,
        edge: EdgeDock,
        onClick: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void,
        onPointerChange: @escaping (Bool) -> Void,
        onDragBegan: @escaping () -> Void,
        onDragChanged: @escaping (NSPoint) -> Void,
        onDragFinished: @escaping (NSPoint) -> Void
    ) {
        noteID = note.id
        self.edge = edge
        targetFrame = frame

        let handleView = EdgeHandleContentView(
            title: note.displayTitle,
            fillColor: Self.fillColor(for: note),
            textColor: Self.textColor(for: note),
            edge: edge
        )
        self.handleView = handleView

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = handleView
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = note.displayTitle

        super.init(window: panel)

        handleView.onClick = onClick
        handleView.onDoubleClick = onDoubleClick
        handleView.onPointerChange = onPointerChange
        handleView.onDragBegan = onDragBegan
        handleView.onDragChanged = onDragChanged
        handleView.onDragFinished = onDragFinished
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        if animated {
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
        } else {
            window.setFrame(targetFrame, display: true)
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    func hide(animated: Bool = true) {
        guard let window else { return }
        let motion = EdgeMotionPolicy.current
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard window.isVisible else { return }
        if animated {
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
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self,
                          !self.shouldBeVisible,
                          self.visibilityGeneration == generation
                    else { return }
                    window.orderOut(nil)
                    window.setFrame(hiddenFrame, display: false)
                    window.alphaValue = 0
                }
            }
        } else {
            window.orderOut(nil)
            window.setFrame(
                EdgeLayoutEngine.hiddenHandleFrame(for: targetFrame, edge: edge),
                display: false
            )
            window.alphaValue = 0
        }
    }

    func update(
        note: MemoNote,
        frame: CGRect,
        edge: EdgeDock,
        isSelected: Bool,
        isDropTarget: Bool = false
    ) {
        self.edge = edge
        targetFrame = frame
        handleView.update(
            title: note.displayTitle,
            fillColor: Self.fillColor(for: note),
            textColor: Self.textColor(for: note),
            edge: edge,
            isSelected: isSelected,
            isDropTarget: isDropTarget
        )
        window?.title = note.displayTitle
    }

    private static func fillColor(for note: MemoNote) -> NSColor {
        NSColor(note.color.bodyColor).withAlphaComponent(note.opacity)
    }

    private static func textColor(for note: MemoNote) -> NSColor {
        NSColor.memoColor(hex: note.textColorHex)
            ?? (note.color == .black ? .white : NSColor(calibratedWhite: 0.12, alpha: 1))
    }
}

private final class EdgeHandleContentView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onPointerChange: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragFinished: ((NSPoint) -> Void)?

    private var title: String
    private var fillColor: NSColor
    private var textColor: NSColor
    private var edge: EdgeDock
    private var isSelected = false
    private var isDropTarget = false
    private var hovering = false
    private var pressed = false
    private var trackingAreaReference: NSTrackingArea?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didDrag = false

    init(title: String, fillColor: NSColor, textColor: NSColor, edge: EdgeDock) {
        self.title = title
        self.fillColor = fillColor
        self.textColor = textColor
        self.edge = edge
        super.init(frame: .zero)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp("메모를 ICE로 열거나, 열려 있다면 인덱스로 접어.")
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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    func update(
        title: String,
        fillColor: NSColor,
        textColor: NSColor,
        edge: EdgeDock,
        isSelected: Bool,
        isDropTarget: Bool
    ) {
        self.title = title
        self.fillColor = fillColor
        self.textColor = textColor
        self.edge = edge
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        toolTip = title
        setAccessibilityLabel(title)
        setAccessibilityValue(isSelected ? "열린 메모" : "접힌 메모")
        needsDisplay = true
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
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

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onPointerChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if dragStartMouse == nil { pressed = false }
        needsDisplay = true
        onPointerChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartMouse, let dragStartOrigin else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - dragStartMouse.x, y: current.y - dragStartMouse.y)
        if !didDrag, hypot(delta.x, delta.y) > 3 {
            didDrag = true
            onDragBegan?()
        }
        guard didDrag else { return }
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y))
        onDragChanged?(current)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = false
            needsDisplay = true
            dragStartMouse = nil
            dragStartOrigin = nil
        }
        if didDrag {
            onDragFinished?(NSEvent.mouseLocation)
            return
        }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let motion = EdgeMotionPolicy.current
        let path = handlePath(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        let effectiveFill = motion.reduceTransparency
            ? fillColor.withAlphaComponent(1)
            : fillColor
        effectiveFill.setFill()
        path.fill()

        if hovering || pressed {
            textColor.withAlphaComponent(pressed ? 0.13 : 0.065).setFill()
            path.fill()
        }

        let stroke = isDropTarget
            ? NSColor.systemGreen
            : textColor.withAlphaComponent(
                motion.increaseContrast
                    ? (isSelected || hovering ? 0.72 : 0.5)
                    : (isSelected ? 0.42 : (hovering ? 0.3 : 0.18))
            )
        stroke.setStroke()
        path.lineWidth = isDropTarget
            ? (motion.increaseContrast ? 3.5 : 3)
            : (isSelected || hovering
                ? (motion.increaseContrast ? 2.5 : 2)
                : (motion.increaseContrast ? 1.5 : 1))
        path.stroke()

        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: centeredParagraphStyle
        ]

        title.draw(
            in: bounds.insetBy(dx: 7, dy: 6),
            withAttributes: attributes
        )
    }

    private func handlePath(in rect: NSRect) -> NSBezierPath {
        let radius = EdgeLayoutEngine.handleCornerRadius
        var topLeft = radius
        var topRight = radius
        var bottomRight = radius
        var bottomLeft = radius

        if isSelected {
            switch edge {
            case .right:
                topLeft = 0
                bottomLeft = 0
            case .left:
                topRight = 0
                bottomRight = 0
            case .top:
                bottomLeft = 0
                bottomRight = 0
            }
        }

        let kappa: CGFloat = 0.552_284_75
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + bottomLeft, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - bottomRight, y: rect.minY))
        if bottomRight > 0 {
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.minY + bottomRight),
                controlPoint1: NSPoint(x: rect.maxX - bottomRight + kappa * bottomRight, y: rect.minY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + bottomRight - kappa * bottomRight)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - topRight))
        if topRight > 0 {
            path.curve(
                to: NSPoint(x: rect.maxX - topRight, y: rect.maxY),
                controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - topRight + kappa * topRight),
                controlPoint2: NSPoint(x: rect.maxX - topRight + kappa * topRight, y: rect.maxY)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX + topLeft, y: rect.maxY))
        if topLeft > 0 {
            path.curve(
                to: NSPoint(x: rect.minX, y: rect.maxY - topLeft),
                controlPoint1: NSPoint(x: rect.minX + topLeft - kappa * topLeft, y: rect.maxY),
                controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - topLeft + kappa * topLeft)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + bottomLeft))
        if bottomLeft > 0 {
            path.curve(
                to: NSPoint(x: rect.minX + bottomLeft, y: rect.minY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.minY + bottomLeft - kappa * bottomLeft),
                controlPoint2: NSPoint(x: rect.minX + bottomLeft - kappa * bottomLeft, y: rect.minY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }
        path.close()
        return path
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }
}
