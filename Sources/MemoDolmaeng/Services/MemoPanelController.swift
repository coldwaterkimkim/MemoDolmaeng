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
    private var visibilityGeneration = 0
    private var isUserResizing = false
    private var suppressResizePersistence = false
    private var resizeSuppressionGeneration = 0

    var noteID: UUID? { viewModel?.noteID }
    var onFold: (() -> Void)?
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
        focusEditor shouldFocusEditor: Bool = true,
        onTitleChange: @escaping (String) -> Void,
        onContentChange: @escaping (String) -> Void
    ) {
        currentBodyFrame = frame
        currentHandleFrame = handleFrame
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
        window.alphaValue = 1

        if wasVisible {
            window.hasShadow = true
            configureWindowSizeConstraints()
            if window.frame != currentBodyFrame {
                suppressResizePersistence(for: EdgeLayoutEngine.panelSwitchDuration)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EdgeLayoutEngine.panelSwitchDuration
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    window.animator().setFrame(currentBodyFrame, display: true)
                }
            }
            if shouldFocusEditor {
                focusEditor(after: isSwitchingNotes ? EdgeLayoutEngine.panelSwitchDuration : 0.12)
            }
            return
        }

        suppressResizePersistence(for: transitionDuration(EdgeLayoutEngine.panelRevealDuration))
        allowTransitionSizing()
        window.setFrame(currentHandleFrame, display: false)
        window.hasShadow = false
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transitionDuration(EdgeLayoutEngine.panelRevealDuration)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            window.animator().setFrame(currentBodyFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                self.configureWindowSizeConstraints()
                window.hasShadow = true
                if shouldFocusEditor { self.focusEditor() }
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

    func fold(
        to handleFrame: CGRect? = nil,
        beforeOrderOut: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        if let handleFrame { currentHandleFrame = handleFrame }
        shouldBeVisible = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard let window, window.isVisible else {
            completion?()
            return
        }

        window.hasShadow = false
        suppressResizePersistence(for: transitionDuration(EdgeLayoutEngine.panelHideDuration))
        allowTransitionSizing()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transitionDuration(EdgeLayoutEngine.panelHideDuration)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            window.animator().setFrame(currentHandleFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                beforeOrderOut?()
                window.orderOut(nil)
                window.alphaValue = 1
                window.hasShadow = true
                completion?()
            }
        }
    }

    func requestFold() {
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

    private func prepareContentSwitchTransition() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = EdgeLayoutEngine.contentSwitchDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentView.layer?.add(transition, forKey: "memoContentSwitch")
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
