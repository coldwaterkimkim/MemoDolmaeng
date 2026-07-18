import AppKit
import QuartzCore

@MainActor
final class DeleteDropZoneController: NSWindowController {
    private let dropView = DeleteDropZoneView()
    private var targetFrame: CGRect = .zero
    private var shouldBeVisible = false
    private var visibilityGeneration = 0

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
        let motion = EdgeMotionPolicy.current
        targetFrame = EdgeLayoutEngine.deleteDropFrame(visibleFrame: visibleFrame)
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        window.setFrame(targetFrame, display: false)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeDuration(0.14)
            context.timingFunction = motion.timingFunction(.easeOut)
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

    func setHighlighted(_ highlighted: Bool) {
        dropView.setHighlighted(highlighted, motion: .current)
    }

    func contains(_ point: NSPoint) -> Bool {
        targetFrame.insetBy(dx: -10, dy: -10).contains(point)
    }

    func hide() {
        guard let window else { return }
        let motion = EdgeMotionPolicy.current
        dropView.setHighlighted(false, motion: motion)
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeDuration(0.12)
            context.timingFunction = motion.timingFunction(.easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                window.orderOut(nil)
                window.alphaValue = 0
            }
        }
    }
}

private final class DeleteDropZoneView: NSView {
    private var highlighted = false

    @objc dynamic private var highlightProgress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("영구 삭제")
        setAccessibilityHelp("메모를 이 영역에 놓으면 삭제 확인을 요청해.")
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

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "highlightProgress" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    func setHighlighted(_ highlighted: Bool, motion: EdgeMotionPolicy) {
        guard self.highlighted != highlighted else { return }
        self.highlighted = highlighted
        setAccessibilityValue(highlighted ? "삭제 준비됨" : "삭제 영역")
        let target: CGFloat = highlighted ? 1 : 0
        guard !motion.reduceMotion else {
            highlightProgress = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = motion.timingFunction(.easeOut)
            animator().highlightProgress = target
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let motion = EdgeMotionPolicy.current
        let progress = min(1, max(0, highlightProgress))
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let color = NSColor.systemRed
        let fillAlpha: CGFloat = motion.reduceTransparency
            ? 1
            : 0.78 + 0.14 * progress
        color.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        let strokeAlpha = motion.increaseContrast
            ? 1
            : 0.72 + 0.22 * progress
        NSColor.white.withAlphaComponent(strokeAlpha).setStroke()
        path.lineWidth = (motion.increaseContrast ? 2 : 1.5) + progress
        path.stroke()

        let symbolSize = 17 + 2 * progress
        let symbol = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .semibold))
        symbol?.draw(
            in: NSRect(x: 21, y: bounds.midY - 10, width: 20, height: 20),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let text = NSAttributedString(
            string: "영구 삭제",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82 + 0.18 * progress),
                .paragraphStyle: paragraph
            ]
        )
        text.draw(in: NSRect(x: 46, y: bounds.midY - 7, width: 50, height: 15))
    }
}
