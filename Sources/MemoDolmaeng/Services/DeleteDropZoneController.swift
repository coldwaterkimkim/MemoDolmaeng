import AppKit

@MainActor
final class DeleteDropZoneController: NSWindowController {
    private let dropView = DeleteDropZoneView()
    private var targetFrame: CGRect = .zero

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = dropView
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "메모 삭제"
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(visibleFrame: CGRect) {
        guard let window else { return }
        targetFrame = EdgeLayoutEngine.deleteDropFrame(visibleFrame: visibleFrame)
        window.setFrame(targetFrame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        dropView.highlighted = highlighted
    }

    func contains(_ point: NSPoint) -> Bool {
        targetFrame.insetBy(dx: -10, dy: -10).contains(point)
    }

    func hide() {
        dropView.highlighted = false
        window?.orderOut(nil)
    }
}

private final class DeleteDropZoneView: NSView {
    var highlighted = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let color = NSColor.systemRed
        color.withAlphaComponent(highlighted ? 0.92 : 0.78).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(highlighted ? 0.94 : 0.72).setStroke()
        path.lineWidth = highlighted ? 2.5 : 1.5
        path.stroke()

        let symbol = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: highlighted ? 20 : 18, weight: .semibold))
        symbol?.draw(
            in: NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}
