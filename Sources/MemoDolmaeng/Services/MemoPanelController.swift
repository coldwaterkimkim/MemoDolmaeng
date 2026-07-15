import AppKit
import SwiftUI
import WebKit

@MainActor
final class MemoPanelController: NSWindowController {
    private let assetRootURL: URL
    private var hostingController: NSHostingController<EdgeMemoPanelView>?
    private var viewModel: NoteEditorViewModel?
    private var currentEdge: EdgeDock = .right
    private var currentScreenFrame: CGRect = .zero
    private var currentVisibleFrame: CGRect = .zero
    private var isIce = false
    private var shouldBeVisible = false
    private var visibilityGeneration = 0

    var noteID: UUID? { viewModel?.noteID }
    var onFold: (() -> Void)?
    var onPointerChange: ((Bool) -> Void)?
    var onImageUpload: ((UUID, Data, String) throws -> URL)?
    var onCycle: ((Int) -> Void)?
    var onSelectIndex: ((Int) -> Void)?

    init(assetRootURL: URL) {
        self.assetRootURL = assetRootURL

        let panel = EdgeMemoPanel(
            contentRect: .zero,
            styleMask: [.borderless],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "메모돌맹 메모"

        super.init(window: panel)

        panel.onFold = { [weak self] in self?.requestFold() }
        panel.onCycle = { [weak self] direction in self?.onCycle?(direction) }
        panel.onSelectIndex = { [weak self] index in self?.onSelectIndex?(index) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        note: MemoNote,
        frame: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edge: EdgeDock,
        isIce: Bool,
        focusEditor shouldFocusEditor: Bool = true,
        onContentChange: @escaping (String) -> Void
    ) {
        currentEdge = edge
        currentScreenFrame = screenFrame
        currentVisibleFrame = visibleFrame
        self.isIce = isIce

        if viewModel?.noteID != note.id {
            viewModel = NoteEditorViewModel(note: note, onContentChange: onContentChange)
        } else {
            viewModel?.sync(note: note)
        }
        updateRootView()

        guard let window else { return }
        shouldBeVisible = true
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let wasVisible = window.isVisible
        if !wasVisible {
            window.setFrame(
                EdgeLayoutEngine.collapsedPanelFrame(
                    for: frame,
                    edge: edge,
                    screenFrame: screenFrame,
                    visibleFrame: visibleFrame
                ),
                display: false
            )
            window.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = EdgeLayoutEngine.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.shouldBeVisible,
                      self.visibilityGeneration == generation,
                      shouldFocusEditor
                else { return }
                self.focusEditor()
            }
        }
    }

    func refresh(note: MemoNote, isIce: Bool) {
        self.isIce = isIce
        viewModel?.sync(note: note)
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

        let target = EdgeLayoutEngine.collapsedPanelFrame(
            for: window.frame,
            edge: currentEdge,
            screenFrame: currentScreenFrame,
            visibleFrame: currentVisibleFrame
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EdgeLayoutEngine.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      !self.shouldBeVisible,
                      self.visibilityGeneration == generation
                else { return }
                window.orderOut(nil)
                completion?()
            }
        }
    }

    func requestFold() {
        onFold?()
    }

    private func updateRootView() {
        guard let viewModel else { return }
        let rootView = EdgeMemoPanelView(
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
            },
            onPointerChange: { [weak self] inside in self?.onPointerChange?(inside) }
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = NSHostingController(rootView: rootView)
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
