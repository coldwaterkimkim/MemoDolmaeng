import AppKit
import QuartzCore
import SwiftUI
import WebKit

@MainActor
final class MemoPanelController: NSWindowController {
    private let assetRootURL: URL
    private var hostingController: NSHostingController<EdgeMemoPanelView>?
    private var viewModel: NoteEditorViewModel?
    private var currentEdge: EdgeDock = .right
    private var currentHandleFrame: CGRect = .zero
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
        currentHandleFrame = handleFrame
        currentScreenFrame = screenFrame
        currentVisibleFrame = visibleFrame
        self.isIce = isIce

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

        guard let window else { return }
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        clearContentMask()
        window.alphaValue = 1

        if wasVisible {
            window.hasShadow = true
            if window.frame != frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EdgeLayoutEngine.panelSwitchDuration
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    window.animator().setFrame(frame, display: true)
                }
            }
            if shouldFocusEditor {
                focusEditor(after: isSwitchingNotes ? EdgeLayoutEngine.panelSwitchDuration : 0.12)
            }
            return
        }

        window.setFrame(frame, display: false)
        window.hasShadow = false
        window.orderFrontRegardless()
        animateContentMask(
            from: revealAnchorRect(panelFrame: frame, handleFrame: handleFrame, edge: edge),
            to: window.contentView?.bounds ?? CGRect(origin: .zero, size: frame.size),
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
        currentHandleFrame = handleFrame
        currentScreenFrame = screenFrame
        currentVisibleFrame = visibleFrame
        guard let window, window.isVisible else { return }
        window.setFrame(frame, display: true)
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
                panelFrame: window.frame,
                handleFrame: currentHandleFrame,
                edge: currentEdge
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
        onResize?(noteID, window.frame.size)
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

    private func revealAnchorRect(
        panelFrame: CGRect,
        handleFrame: CGRect,
        edge: EdgeDock
    ) -> CGRect {
        var anchor = EdgeLayoutEngine.panelRevealAnchorRect(
            panelFrame: panelFrame,
            handleFrame: handleFrame,
            edge: edge
        )
        if window?.contentView?.isFlipped == true {
            anchor.origin.y = panelFrame.height - anchor.maxY
        }
        return anchor
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

    private func updateRootView() {
        guard let viewModel else { return }
        let rootView = EdgeMemoPanelView(
            viewModel: viewModel,
            isIce: isIce,
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
              let webView = findWebView(in: contentView)
        else {
            return
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.focusMemoEditor && window.focusMemoEditor();")
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }
}

private final class EdgeMemoPanel: NSPanel {
    var onFold: (() -> Void)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        onFold?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

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
