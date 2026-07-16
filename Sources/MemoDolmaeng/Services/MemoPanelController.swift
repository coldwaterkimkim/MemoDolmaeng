import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class MemoPanelController: NSWindowController {
    private let assetRootURL: URL
    private var hostingController: NSHostingController<UnifiedEdgeMemoSurfaceView>?
    private var viewModel: NoteEditorViewModel?
    private var currentEdge: EdgeDock = .right
    private var currentBodyFrame: CGRect = .zero
    private var currentHandleFrame: CGRect = .zero
    private var currentSurfaceFrame: CGRect = .zero
    private var currentScreenFrame: CGRect = .zero
    private var currentVisibleFrame: CGRect = .zero
    private var isIce = false
    private var shouldBeVisible = false
    private var visibilityGeneration = 0

    var noteID: UUID? { viewModel?.noteID }
    var onFold: (() -> Void)?
    var onRequestIce: (() -> Void)?
    var onPointerChange: ((Bool) -> Void)?
    var onImageUpload: ((UUID, Data, String) throws -> URL)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onResize: ((UUID, CGSize) -> Void)?

    init(assetRootURL: URL) {
        self.assetRootURL = assetRootURL

        let panel = EdgeMemoPanel(
            contentRect: .zero,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.minSize = MemoPanelSize.minimum
        panel.maxSize = MemoPanelSize.maximum
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "메모돌맹 메모"

        super.init(window: panel)

        panel.onFold = { [weak self] in self?.requestFold() }
        panel.onCycle = { [weak self] direction in self?.onCycle?(direction) }
        panel.onSelectIndex = { [weak self] index in self?.onSelectIndex?(index) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: panel
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        note: MemoNote,
        frame: CGRect,
        handleFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock,
        isIce: Bool,
        focusEditor shouldFocusEditor: Bool = true,
        onTitleChange: @escaping (String) -> Void,
        onContentChange: @escaping (String) -> Void
    ) {
        currentEdge = edge
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
        currentSurfaceFrame = EdgeLayoutEngine.unifiedSurfaceFrame(
            bodyFrame: frame,
            handleFrame: handleFrame
        )
        currentScreenFrame = screenFrame
        currentVisibleFrame = visibleFrame
        self.isIce = isIce
        configureWindowSizeConstraints(handleFrame: handleFrame, edge: edge)

        let previousNoteID = viewModel?.noteID
        let wasVisible = window?.isVisible == true
        let isSwitchingNotes = wasVisible && previousNoteID != nil && previousNoteID != note.id
        if isSwitchingNotes { prepareContentSwitchTransition() }

        if previousNoteID != note.id {
            viewModel = NoteEditorViewModel(
                note: note,
                onTitleChange: onTitleChange,
                onContentChange: onContentChange
            )
        } else {
            viewModel?.sync(note: note)
        }
        updateRootView()

        if let panel = window as? EdgeMemoPanel {
            let bus = MemoMarkdownBus(documentID: note.id)
            panel.onBold = { bus.post(bus.applyBoldRequest) }
            panel.onItalic = { bus.post(bus.applyItalicRequest) }
        }

        guard let window else { return }
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        clearContentMask()
        window.alphaValue = 1

        if wasVisible {
            window.hasShadow = true
            if window.frame != currentSurfaceFrame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EdgeLayoutEngine.panelSwitchDuration
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    window.animator().setFrame(currentSurfaceFrame, display: true)
                }
            }
            if shouldFocusEditor {
                focusEditor(after: isSwitchingNotes ? EdgeLayoutEngine.panelSwitchDuration : 0.12)
            }
            return
        }

        window.setFrame(currentSurfaceFrame, display: false)
        window.hasShadow = false
        window.orderFrontRegardless()
        animateContentMask(
            from: revealAnchorRect(surfaceFrame: currentSurfaceFrame, handleFrame: handleFrame),
            to: window.contentView?.bounds ?? CGRect(origin: .zero, size: currentSurfaceFrame.size),
            duration: transitionDuration(EdgeLayoutEngine.panelRevealDuration),
            generation: generation
        ) { [weak self] in
            guard let self,
                  self.shouldBeVisible,
                  self.visibilityGeneration == generation
            else { return }
            window.hasShadow = true
            self.clearContentMask()
            if shouldFocusEditor { self.focusEditor() }
        }
    }

    func refresh(note: MemoNote, isIce: Bool) {
        self.isIce = isIce
        viewModel?.sync(note: note)
        updateRootView()
    }

    func reposition(
        frame: CGRect,
        handleFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock
    ) {
        currentEdge = edge
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
        currentSurfaceFrame = EdgeLayoutEngine.unifiedSurfaceFrame(
            bodyFrame: frame,
            handleFrame: handleFrame
        )
        currentScreenFrame = screenFrame
        currentVisibleFrame = visibleFrame
        configureWindowSizeConstraints(handleFrame: handleFrame, edge: edge)
        guard let window, window.isVisible else { return }
        window.setFrame(currentSurfaceFrame, display: true)
        updateRootView()
    }

    func fold(completion: (() -> Void)? = nil) {
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard let window, window.isVisible else {
            completion?()
            return
        }

        window.hasShadow = false
        clearContentMask()
        animateContentMask(
            from: window.contentView?.bounds ?? CGRect(origin: .zero, size: window.frame.size),
            to: revealAnchorRect(
                surfaceFrame: currentSurfaceFrame,
                handleFrame: currentHandleFrame
            ),
            duration: transitionDuration(EdgeLayoutEngine.panelHideDuration),
            generation: generation
        ) { [weak self] in
            guard let self,
                  !self.shouldBeVisible,
                  self.visibilityGeneration == generation
            else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            window.hasShadow = true
            self.clearContentMask()
            completion?()
        }
    }

    func requestFold() {
        onFold?()
    }

    @objc private func panelDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let noteID,
              shouldBeVisible
        else { return }
        currentSurfaceFrame = window.frame
        let size = EdgeLayoutEngine.bodySize(
            fromSurfaceSize: window.frame.size,
            handleSize: currentHandleFrame.size,
            edge: currentEdge
        )
        currentBodyFrame.size = size
        onResize?(noteID, size)
    }

    private func prepareContentSwitchTransition() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = EdgeLayoutEngine.contentSwitchDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentView.layer?.add(transition, forKey: "memoContentSwitch")
    }

    private func revealAnchorRect(surfaceFrame: CGRect, handleFrame: CGRect) -> CGRect {
        var anchor = handleFrame.offsetBy(dx: -surfaceFrame.minX, dy: -surfaceFrame.minY)
        if window?.contentView?.isFlipped == true {
            anchor.origin.y = surfaceFrame.height - anchor.maxY
        }
        return anchor.intersection(CGRect(origin: .zero, size: surfaceFrame.size))
    }

    private func animateContentMask(
        from startRect: CGRect,
        to endRect: CGRect,
        duration: TimeInterval,
        generation: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let contentView = window?.contentView else {
            completion()
            return
        }
        contentView.wantsLayer = true
        guard let contentLayer = contentView.layer else {
            completion()
            return
        }

        let maskLayer = CAShapeLayer()
        maskLayer.frame = contentView.bounds
        maskLayer.fillColor = NSColor.black.cgColor
        let startPath = maskPath(for: startRect)
        let endPath = maskPath(for: endRect)
        maskLayer.path = endPath
        contentLayer.mask = maskLayer

        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = startPath
        animation.toValue = endPath
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        maskLayer.add(animation, forKey: "memoPanelReveal")

        Task { @MainActor [weak self, weak maskLayer] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self,
                  self.visibilityGeneration == generation,
                  self.window?.contentView?.layer?.mask === maskLayer
            else { return }
            completion()
        }
    }

    private func maskPath(for rect: CGRect) -> CGPath {
        let radius = min(
            EdgeLayoutEngine.panelCornerRadius,
            max(1, min(rect.width, rect.height) / 2)
        )
        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    private func clearContentMask() {
        guard let layer = window?.contentView?.layer else { return }
        layer.mask?.removeAllAnimations()
        layer.mask = nil
    }

    private func transitionDuration(_ duration: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : duration
    }

    private func focusEditor(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.shouldBeVisible else { return }
            self.focusEditor()
        }
    }

    private func configureWindowSizeConstraints(handleFrame: CGRect, edge: EdgeDock) {
        guard let window else { return }
        switch edge {
        case .left, .right:
            window.minSize = CGSize(
                width: MemoPanelSize.minimum.width + handleFrame.width,
                height: MemoPanelSize.minimum.height
            )
            window.maxSize = CGSize(
                width: MemoPanelSize.maximum.width + handleFrame.width,
                height: MemoPanelSize.maximum.height
            )
        case .top:
            window.minSize = CGSize(
                width: MemoPanelSize.minimum.width,
                height: MemoPanelSize.minimum.height + handleFrame.height
            )
            window.maxSize = CGSize(
                width: MemoPanelSize.maximum.width,
                height: MemoPanelSize.maximum.height + handleFrame.height
            )
        }
    }

    private func updateRootView() {
        guard let viewModel else { return }
        let handleOffset: CGFloat
        switch currentEdge {
        case .left, .right:
            handleOffset = currentSurfaceFrame.maxY - currentHandleFrame.maxY
        case .top:
            handleOffset = currentHandleFrame.minX - currentSurfaceFrame.minX
        }

        let rootView = UnifiedEdgeMemoSurfaceView(
            viewModel: viewModel,
            edge: currentEdge,
            handleSize: currentHandleFrame.size,
            handleOffset: handleOffset,
            assetRootURL: assetRootURL,
            onImageUpload: { [weak self] data, originalName in
                guard let self,
                      let noteID = self.noteID,
                      let onImageUpload = self.onImageUpload
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return try onImageUpload(noteID, data, originalName)
            },
            onRequestIce: { [weak self] in self?.onRequestIce?() },
            onRequestFold: { [weak self] in
                guard let self else { return }
                if self.isIce {
                    self.requestFold()
                } else {
                    self.onRequestIce?()
                }
            },
            onPointerChange: { [weak self] inside in self?.onPointerChange?(inside) }
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = NSHostingController(rootView: rootView)
            controller.view.wantsLayer = true
            hostingController = controller
            window?.contentViewController = controller
        }
    }

    private func focusEditor() {
        guard let contentView = window?.contentView,
              let textView = findTextView(in: contentView)
        else {
            return
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}

private final class EdgeMemoPanel: NSPanel {
    var onFold: (() -> Void)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        onFold?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

        if flags == .command, event.keyCode == KeyboardShortcuts.KeyCode.b {
            onBold?()
            return true
        }

        if flags == .command, event.keyCode == KeyboardShortcuts.KeyCode.i {
            onItalic?()
            return true
        }

        if event.keyCode == 53 {
            onFold?()
            return true
        }

        if flags == .command, event.keyCode == KeyboardShortcuts.KeyCode.w {
            onFold?()
            return true
        }

        if flags == [.command, .shift] {
            if event.keyCode == 126 {
                onCycle?(-1)
                return true
            }
            if event.keyCode == 125 {
                onCycle?(1)
                return true
            }
        }

        if flags == .command,
           let character = event.charactersIgnoringModifiers?.first,
           let number = Int(String(character)),
           (0...9).contains(number) {
            onSelectIndex?(number == 0 ? 9 : number - 1)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
