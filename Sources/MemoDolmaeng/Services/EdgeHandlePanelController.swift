import AppKit

@MainActor
final class EdgeHandlePanelController: NSWindowController {
    let noteID: UUID

    private let handleView: EdgeHandleContentView
    private var edge: EdgeDock
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

        let handleView = EdgeHandleContentView(
            title: note.title,
            fillColor: NSColor(note.color.bodyColor),
            textColor: Self.textColor(for: note.color),
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
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = note.title

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
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        window.orderFrontRegardless()
        if animated {
            if window.alphaValue <= 0.01 { window.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EdgeLayoutEngine.indexAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
            window.alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard let window else { return }
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard window.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EdgeLayoutEngine.indexAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self,
                          !self.shouldBeVisible,
                          self.visibilityGeneration == generation
                    else { return }
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            }
        } else {
            window.orderOut(nil)
            window.alphaValue = 1
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
        handleView.update(
            title: note.title,
            fillColor: NSColor(note.color.bodyColor),
            textColor: Self.textColor(for: note.color),
            edge: edge,
            isSelected: isSelected,
            isDropTarget: isDropTarget
        )
        window?.title = note.title
        window?.setFrame(frame, display: true)
    }

    private static func textColor(for color: NoteColor) -> NSColor {
        color == .black ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
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
        needsDisplay = true
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

    override func mouseEntered(with event: NSEvent) { onPointerChange?(true) }
    override func mouseExited(with event: NSEvent) { onPointerChange?(false) }

    override func mouseDown(with event: NSEvent) {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        fillColor.setFill()
        path.fill()

        let stroke = isDropTarget ? NSColor.systemGreen : (isSelected ? .controlAccentColor : .separatorColor)
        stroke.setStroke()
        path.lineWidth = isDropTarget ? 3 : (isSelected ? 2 : 1)
        path.stroke()

        let font = NSFont.systemFont(ofSize: edge == .top ? 10 : 9.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: centeredParagraphStyle
        ]

        if edge == .top {
            title.draw(
                in: bounds.insetBy(dx: 5, dy: 6),
                withAttributes: attributes
            )
            return
        }

        let characters = Array(title.prefix(6)).map(String.init)
        let lineHeight = min(CGFloat(11), max(6, bounds.height / CGFloat(max(1, characters.count))))
        let totalHeight = CGFloat(characters.count) * lineHeight
        var y = bounds.midY + totalHeight / 2 - lineHeight
        for character in characters {
            let rect = NSRect(x: 1, y: y, width: bounds.width - 2, height: lineHeight)
            character.draw(in: rect, withAttributes: attributes)
            y -= lineHeight
        }
    }

    private var centeredParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }
}
