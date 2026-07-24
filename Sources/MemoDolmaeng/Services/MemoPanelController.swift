import AppKit
import MarkdownEngine
import QuartzCore
import SwiftUI

enum MemoPanelFocusTarget {
    case none
    case title
    case editor
}

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
    private var revealInputBuffer: NSTextView?
    private var revealInputBaseText = ""
    private var revealInputTarget: MemoPanelFocusTarget = .none

    var noteID: UUID? { viewModel?.noteID }
    var onFold: (() -> Void)?
    var onImageUpload: ((UUID, Data, String) throws -> URL)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onResize: ((UUID, CGSize) -> Void)?
    var onDidBecomeKey: ((UUID) -> Void)?
    var shouldAcceptAutomaticFocus: (() -> Bool)?

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
        panel.title = AppIdentity.memoWindowTitle

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
        initialFocus: MemoPanelFocusTarget = .editor,
        onTitleChange: @escaping (String) -> Void,
        onContentChange: @escaping (String) -> Void
    ) {
        let motion = EdgeMotionPolicy.current
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
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
                    focusTarget: initialFocus
                )
            } else if initialFocus != .none {
                let delay = isSwitchingNotes
                    ? motion.geometryDuration(EdgeLayoutEngine.panelSwitchDuration)
                    : (motion.reduceMotion ? 0 : 0.12)
                focus(initialFocus, after: delay)
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
        if initialFocus != .none {
            // Transfer key-window ownership immediately so keystrokes during
            // the reveal can never leak into the memo that spawned this one.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if motion.animatesGeometry {
                beginRevealInputCapture(in: window, target: initialFocus)
                if initialFocus == .title {
                    _ = applyFocus(.title)
                }
            } else {
                focus(initialFocus, after: 0)
            }
        } else {
            window.orderFrontRegardless()
        }
        if initialFocus == .none { clearAutomaticFieldFocus() }
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
                switch initialFocus {
                case .editor, .title:
                    self.finishRevealInputCaptureWhenReady(
                        generation: generation,
                        focusTarget: initialFocus
                    )
                case .none:
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
        edge: EdgeDock,
        animatedDuration: TimeInterval? = nil
    ) {
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
        configureWindowSizeConstraints()
        guard let window, window.isVisible else { return }
        let motion = EdgeMotionPolicy.current
        let duration = animatedDuration.map(motion.geometryDuration) ?? 0
        suppressResizePersistence(for: max(0.08, duration))
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = motion.timingFunction(.easeOut)
                window.animator().setFrame(currentBodyFrame, display: true)
            }
        } else {
            window.setFrame(currentBodyFrame, display: true)
        }
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

    private func beginRevealInputCapture(
        in window: NSWindow,
        target: MemoPanelFocusTarget
    ) {
        guard revealInputBuffer == nil,
              let contentView = window.contentView
        else { return }
        let buffer = NSTextView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        buffer.isRichText = false
        buffer.drawsBackground = false
        buffer.alphaValue = 0.01
        buffer.setAccessibilityElement(false)
        revealInputTarget = target
        revealInputBaseText = switch target {
        case .title:
            viewModel?.title ?? ""
        case .editor:
            viewModel?.content ?? ""
        case .none:
            ""
        }
        buffer.string = revealInputBaseText
        buffer.setSelectedRange(
            NSRange(location: (revealInputBaseText as NSString).length, length: 0)
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
        let target = revealInputTarget
        revealInputTarget = .none
        guard bufferedText != revealInputBaseText else { return }
        switch target {
        case .title:
            viewModel?.updateTitle(bufferedText)
        case .editor:
            viewModel?.updateMarkdownContent(bufferedText)
        case .none:
            break
        }
    }

    private func finishRevealInputCaptureWhenReady(
        generation: Int,
        focusTarget: MemoPanelFocusTarget
    ) {
        guard let buffer = revealInputBuffer else {
            if window?.isKeyWindow == true {
                focus(focusTarget, after: 0.01, onlyWhileKey: true)
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
                self.finishRevealInputCaptureWhenReady(
                    generation: generation,
                    focusTarget: focusTarget
                )
            }
            return
        }
        let shouldTransferFocus = NSApp.isActive
            && (shouldAcceptAutomaticFocus?() ?? true)
        flushRevealInputCapture()
        if shouldTransferFocus {
            focus(focusTarget, after: 0.01)
        }
    }

    private func focus(
        _ target: MemoPanelFocusTarget,
        after delay: TimeInterval,
        remainingAttempts: Int = 8,
        onlyWhileKey: Bool = false
    ) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self,
                  self.shouldBeVisible,
                  self.shouldAcceptAutomaticFocus?() ?? true,
                  !onlyWhileKey || self.window?.isKeyWindow == true
            else { return }
            if !self.applyFocus(target), remainingAttempts > 1 {
                self.focus(
                    target,
                    after: 0.02,
                    remainingAttempts: remainingAttempts - 1,
                    onlyWhileKey: onlyWhileKey
                )
            }
        }
    }

    private func mountBody(
        after delay: TimeInterval,
        generation: Int,
        focusTarget: MemoPanelFocusTarget
    ) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self,
                  self.shouldBeVisible,
                  self.visibilityGeneration == generation
            else { return }
            self.isBodyMounted = true
            self.updateRootView()
            if focusTarget != .none {
                self.focus(focusTarget, after: 0.01)
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
    private func applyFocus(_ target: MemoPanelFocusTarget) -> Bool {
        switch target {
        case .none:
            return true
        case .title:
            return focusTitle()
        case .editor:
            return focusEditor()
        }
    }

    @discardableResult
    private func focusTitle() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)

        if let fieldEditor = window.firstResponder as? NSTextView,
           fieldEditor.isFieldEditor {
            fieldEditor.setSelectedRange(
                NSRange(location: (fieldEditor.string as NSString).length, length: 0)
            )
            return true
        }

        if let contentView = window.contentView,
           let titleField = findTitleField(in: contentView),
           window.makeFirstResponder(titleField),
           let fieldEditor = window.firstResponder as? NSTextView,
           fieldEditor.isFieldEditor {
            fieldEditor.setSelectedRange(
                NSRange(location: (fieldEditor.string as NSString).length, length: 0)
            )
            return true
        }

        viewModel?.requestTitleFocus()
        if let fieldEditor = window.firstResponder as? NSTextView,
           fieldEditor.isFieldEditor {
            fieldEditor.setSelectedRange(
                NSRange(location: (fieldEditor.string as NSString).length, length: 0)
            )
        }
        return false
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

    private func findTitleField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let textField = findTitleField(in: subview) { return textField }
        }
        return nil
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
