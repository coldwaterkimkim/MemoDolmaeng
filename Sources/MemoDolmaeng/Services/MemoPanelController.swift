import AppKit
import MarkdownEngine
import QuartzCore
import SwiftUI

@MainActor
final class MemoPanelController: NSWindowController, NSWindowDelegate {
    private let assetRootURL: URL
    private var hostingController: NSHostingController<UnifiedEdgeMemoSurfaceView>?
    private var viewModel: NoteEditorViewModel?
    private var currentBodyFrame: CGRect = .zero
    private var currentHandleFrame: CGRect = .zero
    private var shouldBeVisible = false
    private var isBodyMounted = false
    private var visibilityGeneration = 0
    private var isUserResizing = false
    private var suppressResizePersistence = false
    private var resizeSuppressionGeneration = 0
    private var canAddAdjacent = false
    private var revealInputBuffer: NSTextView?
    private var revealInputBaseContent = ""

    var noteID: UUID? { viewModel?.noteID }
    var onFold: (() -> Void)?
    var onImageUpload: ((UUID, Data, String) throws -> URL)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onResize: ((UUID, CGSize) -> Void)?
    var onDidBecomeKey: ((UUID) -> Void)?
    var onCreateAdjacent: ((MemoAdjacentDirection) -> Void)?

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
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // The panel is born at its edge handle size. Expanded editor constraints
        // are installed only after the reveal reaches a valid body frame.
        panel.minSize = CGSize(width: 1, height: 1)
        panel.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "메모돌맹 메모"

        super.init(window: panel)
        panel.delegate = self

        panel.onFold = { [weak self] in self?.requestFold() }
        panel.onCycle = { [weak self] direction in self?.onCycle?(direction) }
        panel.onSelectIndex = { [weak self] index in self?.onSelectIndex?(index) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillStartLiveResize(_:)),
            name: NSWindow.willStartLiveResizeNotification,
            object: panel
        )
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
        canAddAdjacent: Bool,
        focusEditor shouldFocusEditor: Bool = true,
        onTitleChange: @escaping (String) -> Void,
        onContentChange: @escaping (String) -> Void
    ) {
        let motion = EdgeMotionPolicy.current
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
        self.canAddAdjacent = canAddAdjacent
        let previousNoteID = viewModel?.noteID
        let wasVisible = window?.isVisible == true
        let wasIntendedVisible = shouldBeVisible
        let isSwitchingNotes = wasVisible && previousNoteID != nil && previousNoteID != note.id
        if isSwitchingNotes { prepareContentSwitchTransition() }
        isBodyMounted = wasVisible && wasIntendedVisible

        if previousNoteID != note.id {
            viewModel = NoteEditorViewModel(
                note: note,
                onTitleChange: onTitleChange,
                onContentChange: onContentChange
            )
        } else {
            viewModel?.sync(note: note)
        }
        window?.identifier = NSUserInterfaceItemIdentifier("memo-panel-\(note.id.uuidString)")

        if let panel = window as? EdgeMemoPanel {
            let bus = MemoMarkdownBus(documentID: note.id)
            panel.onBold = { bus.post(bus.applyBoldRequest) }
            panel.onItalic = { bus.post(bus.applyItalicRequest) }
        }

        guard let window else { return }
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        window.alphaValue = 1

        if wasVisible {
            updateRootView()
            window.hasShadow = true
            configureWindowSizeConstraints()
            if window.frame != currentBodyFrame {
                suppressResizePersistence(
                    for: motion.animatesGeometry
                        ? EdgeLayoutEngine.panelSwitchDuration
                        : motion.fadeDuration(EdgeLayoutEngine.panelSwitchDuration)
                )
                if motion.animatesGeometry {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = motion.geometryDuration(EdgeLayoutEngine.panelSwitchDuration)
                        context.timingFunction = motion.timingFunction(.reveal)
                        window.animator().setFrame(currentBodyFrame, display: true)
                    }
                } else {
                    window.setFrame(currentBodyFrame, display: true)
                }
            }
            if !isBodyMounted {
                mountBody(
                    after: motion.animatesGeometry
                        ? motion.geometryDuration(EdgeLayoutEngine.panelSwitchDuration)
                        : 0,
                    generation: generation,
                    focusEditor: shouldFocusEditor
                )
            } else if shouldFocusEditor {
                let delay = isSwitchingNotes
                    ? motion.geometryDuration(EdgeLayoutEngine.panelSwitchDuration)
                    : (motion.reduceMotion ? 0 : 0.12)
                focusEditor(after: delay)
            } else {
                clearAutomaticFieldFocus()
            }
            return
        }

        let revealDuration = motion.animatesGeometry
            ? motion.geometryDuration(EdgeLayoutEngine.panelRevealDuration)
            : motion.fadeDuration(EdgeLayoutEngine.panelRevealDuration)
        suppressResizePersistence(for: revealDuration)
        allowTransitionSizing()
        window.setFrame(motion.animatesGeometry ? currentHandleFrame : currentBodyFrame, display: false)
        updateRootView()
        if !motion.animatesGeometry {
            isBodyMounted = true
            updateRootView()
        }
        window.alphaValue = motion.reduceMotion ? 0 : 1
        window.hasShadow = false
        if shouldFocusEditor {
            // Transfer key-window ownership immediately so keystrokes during
            // the reveal can never leak into the memo that spawned this one.
            window.makeKeyAndOrderFront(nil)
            if motion.animatesGeometry {
                beginRevealInputCapture(in: window)
            } else {
                focusEditor(after: 0)
            }
        } else {
            window.orderFrontRegardless()
        }
        if !shouldFocusEditor { clearAutomaticFieldFocus() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealDuration
            context.timingFunction = motion.timingFunction(.reveal)
            if motion.animatesGeometry {
                window.animator().setFrame(currentBodyFrame, display: true)
            } else {
                window.animator().alphaValue = 1
            }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                window.alphaValue = 1
                self.configureWindowSizeConstraints()
                window.hasShadow = true
                if !self.isBodyMounted {
                    self.isBodyMounted = true
                    self.updateRootView()
                }
                if shouldFocusEditor {
                    self.finishRevealInputCaptureWhenReady(generation: generation)
                } else {
                    self.clearAutomaticFieldFocus()
                }
            }
        }
    }

    func reposition(
        frame: CGRect,
        handleFrame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock
    ) {
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
        configureWindowSizeConstraints()
        guard let window, window.isVisible else { return }
        suppressResizePersistence(for: 0.08)
        window.setFrame(currentBodyFrame, display: true)
        updateRootView()
    }

    func setCollapseTargetFrame(_ frame: CGRect) {
        currentHandleFrame = frame
    }

    func flushPendingInput() {
        flushRevealInputCapture()
    }

    func fold(
        to handleFrame: CGRect? = nil,
        beforeOrderOut: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        flushRevealInputCapture()
        let motion = EdgeMotionPolicy.current
        if let handleFrame { currentHandleFrame = handleFrame }
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard let window, window.isVisible else {
            completion?()
            return
        }

        window.hasShadow = false
        isBodyMounted = false
        updateRootView()
        let hideDuration = motion.animatesGeometry
            ? motion.geometryDuration(EdgeLayoutEngine.panelHideDuration)
            : motion.fadeDuration(EdgeLayoutEngine.panelHideDuration)
        suppressResizePersistence(for: hideDuration)
        allowTransitionSizing()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hideDuration
            context.timingFunction = motion.timingFunction(.hide)
            if motion.animatesGeometry {
                window.animator().setFrame(currentHandleFrame, display: true)
            } else {
                window.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                beforeOrderOut?()
                window.orderOut(nil)
                if !motion.animatesGeometry {
                    window.setFrame(self.currentHandleFrame, display: false)
                }
                window.alphaValue = 1
                window.hasShadow = true
                completion?()
            }
        }
    }

    func requestFold() {
        flushRevealInputCapture()
        onFold?()
    }

    @objc private func panelWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window,
              !suppressResizePersistence
        else { return }
        isUserResizing = true
    }

    @objc private func panelDidEndLiveResize(_ notification: Notification) {
        guard isUserResizing else { return }
        isUserResizing = false
        guard let window = notification.object as? NSWindow,
              let noteID,
              shouldBeVisible
        else { return }
        let size = CGSize(
            width: min(MemoPanelSize.maximum.width, max(MemoPanelSize.minimum.width, window.frame.width)),
            height: currentBodyFrame.height
        )
        currentBodyFrame = window.frame
        currentBodyFrame.size = size
        onResize?(noteID, size)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard shouldBeVisible, currentBodyFrame.height > 0 else { return frameSize }
        return NSSize(
            width: min(MemoPanelSize.maximum.width, max(MemoPanelSize.minimum.width, frameSize.width)),
            height: currentBodyFrame.height
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window,
              shouldBeVisible,
              let noteID
        else { return }
        onDidBecomeKey?(noteID)
    }

    private func prepareContentSwitchTransition() {
        guard let contentView = window?.contentView else { return }
        let motion = EdgeMotionPolicy.current
        contentView.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = motion.fadeDuration(EdgeLayoutEngine.contentSwitchDuration)
        transition.timingFunction = motion.timingFunction(.easeOut)
        contentView.layer?.add(transition, forKey: "memoContentSwitch")
    }

    private func beginRevealInputCapture(in window: NSWindow) {
        guard revealInputBuffer == nil,
              let contentView = window.contentView
        else { return }
        let buffer = NSTextView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        buffer.isRichText = false
        buffer.drawsBackground = false
        buffer.alphaValue = 0.01
        buffer.setAccessibilityElement(false)
        revealInputBaseContent = viewModel?.content ?? ""
        buffer.string = revealInputBaseContent
        buffer.setSelectedRange(
            NSRange(location: (revealInputBaseContent as NSString).length, length: 0)
        )
        contentView.addSubview(buffer)
        revealInputBuffer = buffer
        window.makeFirstResponder(buffer)
    }

    private func flushRevealInputCapture() {
        guard let buffer = revealInputBuffer else { return }
        window?.makeFirstResponder(nil)
        let bufferedText = buffer.string
        buffer.removeFromSuperview()
        revealInputBuffer = nil
        guard bufferedText != revealInputBaseContent else { return }
        viewModel?.updateMarkdownContent(bufferedText)
    }

    private func finishRevealInputCaptureWhenReady(generation: Int) {
        guard let buffer = revealInputBuffer else {
            if window?.isKeyWindow == true {
                focusEditor(after: 0.01, onlyWhileKey: true)
            }
            return
        }
        guard !buffer.hasMarkedText() else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self,
                      self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                self.finishRevealInputCaptureWhenReady(generation: generation)
            }
            return
        }
        let shouldTransferFocus = window?.isKeyWindow == true
            && window?.firstResponder === buffer
        flushRevealInputCapture()
        if shouldTransferFocus {
            focusEditor(after: 0.01, onlyWhileKey: true)
        }
    }

    private func focusEditor(
        after delay: TimeInterval,
        remainingAttempts: Int = 8,
        onlyWhileKey: Bool = false
    ) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self,
                  self.shouldBeVisible,
                  !onlyWhileKey || self.window?.isKeyWindow == true
            else { return }
            if !self.focusEditor(), remainingAttempts > 1 {
                self.focusEditor(
                    after: 0.02,
                    remainingAttempts: remainingAttempts - 1,
                    onlyWhileKey: onlyWhileKey
                )
            }
        }
    }

    private func mountBody(after delay: TimeInterval, generation: Int, focusEditor: Bool) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self,
                  self.shouldBeVisible,
                  self.visibilityGeneration == generation
            else { return }
            self.isBodyMounted = true
            self.updateRootView()
            if focusEditor {
                self.focusEditor(after: 0.01)
            } else {
                self.clearAutomaticFieldFocus()
            }
        }
    }

    private func configureWindowSizeConstraints() {
        guard let window else { return }
        window.minSize = CGSize(
            width: min(MemoPanelSize.minimum.width, currentBodyFrame.width),
            height: currentBodyFrame.height
        )
        window.maxSize = CGSize(
            width: MemoPanelSize.maximum.width,
            height: currentBodyFrame.height
        )
    }

    private func allowTransitionSizing() {
        guard let window else { return }
        window.minSize = CGSize(width: 1, height: 1)
        window.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func suppressResizePersistence(for duration: TimeInterval) {
        resizeSuppressionGeneration += 1
        let generation = resizeSuppressionGeneration
        suppressResizePersistence = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, duration + 0.05)))
            guard let self, self.resizeSuppressionGeneration == generation else { return }
            self.suppressResizePersistence = false
        }
    }

    private func updateRootView() {
        guard let viewModel else { return }
        let rootView = UnifiedEdgeMemoSurfaceView(
            viewModel: viewModel,
            isBodyMounted: isBodyMounted,
            assetRootURL: assetRootURL,
            canAddAdjacent: canAddAdjacent,
            onCreateAdjacent: { [weak self] direction in
                self?.onCreateAdjacent?(direction)
            },
            onImageUpload: { [weak self] data, originalName in
                guard let self,
                      let noteID = self.noteID,
                      let onImageUpload = self.onImageUpload
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return try onImageUpload(noteID, data, originalName)
            }
        )

        if let hostingController {
            hostingController.rootView = rootView
            if window?.contentView !== hostingController.view {
                window?.contentViewController = nil
                window?.contentView = hostingController.view
            }
        } else {
            let controller = NSHostingController(rootView: rootView)
            controller.view.wantsLayer = true
            hostingController = controller
            window?.contentViewController = nil
            window?.contentView = controller.view
        }
    }

    @discardableResult
    private func focusEditor() -> Bool {
        guard let contentView = window?.contentView,
              let textView = findTextView(in: contentView)
        else {
            return false
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        return true
    }

    private func clearAutomaticFieldFocus() {
        guard let window,
              let fieldEditor = window.firstResponder as? NSTextView,
              fieldEditor.isFieldEditor
        else { return }
        window.makeFirstResponder(nil)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView,
           textView.delegate is NativeTextViewCoordinator {
            return textView
        }
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
