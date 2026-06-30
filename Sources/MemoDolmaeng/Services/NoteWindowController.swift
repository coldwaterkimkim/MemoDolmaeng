import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    private static let autoDeleteDelay: TimeInterval = 2

    let noteID: UUID
    private let viewModel: NoteEditorViewModel
    private let onFrameChange: (UUID, CGRect) -> Void
    private let onClose: (UUID, CGRect) -> Void
    private let onDelete: (UUID) -> Void
    private let onFloatChange: (UUID, Bool) -> Void
    private let onTranslucentChange: (UUID, Bool) -> Void
    private let onAutomaticHeightChange: (UUID, Bool) -> Void
    private var isFloatingOnTop: Bool
    private var isWindowTranslucent: Bool
    private var usesAutomaticHeight: Bool
    private var isApplyingProgrammaticFrame = false
    private var isDeleting = false
    private var hasEverHadContent: Bool
    private var contentObservation: AnyCancellable?
    private var autoDeleteTask: Task<Void, Never>?

    init(
        note: MemoNote,
        store: NoteStore,
        onFrameChange: @escaping (UUID, CGRect) -> Void,
        onClose: @escaping (UUID, CGRect) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onFloatChange: @escaping (UUID, Bool) -> Void,
        onTranslucentChange: @escaping (UUID, Bool) -> Void,
        onAutomaticHeightChange: @escaping (UUID, Bool) -> Void
    ) {
        self.noteID = note.id
        self.viewModel = NoteEditorViewModel(
            noteID: note.id,
            initialContent: note.content,
            initialRichTextData: note.richTextData,
            color: note.color,
            isTranslucent: note.isTranslucent,
            store: store
        )
        self.onFrameChange = onFrameChange
        self.onClose = onClose
        self.onDelete = onDelete
        self.onFloatChange = onFloatChange
        self.onTranslucentChange = onTranslucentChange
        self.onAutomaticHeightChange = onAutomaticHeightChange
        self.isFloatingOnTop = note.floatsOnTop
        self.isWindowTranslucent = note.isTranslucent
        self.usesAutomaticHeight = note.usesAutomaticHeight
        self.hasEverHadContent = Self.hasMeaningfulContent(note.content)

        let rootView = NoteWindowView(viewModel: viewModel)
        let hostingController = NSViewController()
        hostingController.view = StickyNoteHostingView(rootView: rootView)
        let window = StickyNoteWindow(
            contentRect: note.frame.rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Memo"
        window.minSize = NSSize(width: 240, height: NoteWindowMetrics.minimumAutomaticHeight)
        window.contentViewController = hostingController
        window.setFrame(note.frame.rect, display: true)
        window.level = note.floatsOnTop ? .floating : .normal
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 1
        window.hasShadow = AppPreferences.shared.windowShadowEnabled
        window.collectionBehavior = []
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.onRequestClose = { [weak self] in
            self?.requestClose()
        }
        window.onToggleFloatOnTop = { [weak self] in
            self?.toggleFloatsOnTop()
        }
        window.onToggleTranslucent = { [weak self] in
            self?.toggleTranslucent()
        }
        window.delegate = self

        contentObservation = viewModel.$content
            .dropFirst()
            .sink { [weak self] content in
                self?.handleContentChange(content)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        focusEditor()
    }

    func bringToFront(makeKey: Bool) {
        guard let window else { return }

        if makeKey {
            window.makeKeyAndOrderFront(nil)
            focusEditor()
        } else {
            window.orderFront(nil)
        }
    }

    func closeNote() {
        requestClose()
    }

    func setColor(_ color: NoteColor) {
        viewModel.setColor(color)
    }

    func setFloatsOnTop(_ floatsOnTop: Bool) {
        isFloatingOnTop = floatsOnTop
        window?.level = floatsOnTop ? .floating : .normal
        onFloatChange(noteID, floatsOnTop)
    }

    func toggleFloatsOnTop() {
        setFloatsOnTop(!isFloatingOnTop)
    }

    func setTranslucent(_ isTranslucent: Bool) {
        isWindowTranslucent = isTranslucent
        viewModel.setTranslucent(isTranslucent)
        window?.alphaValue = 1
        onTranslucentChange(noteID, isTranslucent)
    }

    func toggleTranslucent() {
        setTranslucent(!isWindowTranslucent)
    }

    var floatsOnTop: Bool {
        isFloatingOnTop
    }

    var color: NoteColor {
        viewModel.color
    }

    var isTranslucent: Bool {
        isWindowTranslucent
    }

    func noteContentHeightDidChange(_ contentHeight: CGFloat) {
        guard usesAutomaticHeight else { return }
        applyAutomaticFrame(contentHeight: contentHeight)
    }

    func applyPreferences() {
        guard let window else { return }
        window.minSize = NSSize(width: 240, height: NoteWindowMetrics.minimumAutomaticHeight)
        window.alphaValue = 1
        window.hasShadow = AppPreferences.shared.windowShadowEnabled
    }

    func resetWidthToDefault() {
        guard let window else { return }

        let currentFrame = window.frame
        let targetWidth = NoteWindowMetrics.automaticWidth
        guard abs(currentFrame.width - targetWidth) >= 1 else { return }

        let nextFrame = CGRect(
            x: currentFrame.minX,
            y: currentFrame.minY,
            width: targetWidth,
            height: currentFrame.height
        )

        isApplyingProgrammaticFrame = true
        window.setFrame(nextFrame, display: true)
        isApplyingProgrammaticFrame = false
        onFrameChange(noteID, nextFrame)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingProgrammaticFrame else { return }
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingProgrammaticFrame else { return }

        if usesAutomaticHeight {
            usesAutomaticHeight = false
            onAutomaticHeightChange(noteID, false)
        }

        persistFrame()
    }

    func windowWillClose(_ notification: Notification) {
        guard let frame = window?.frame else { return }

        if isDeleting {
            cancelAutoDelete()
            onDelete(noteID)
            return
        }

        cancelAutoDelete()
        onClose(noteID, frame)
    }

    private func requestClose() {
        guard hasContent else {
            window?.close()
            return
        }

        showCloseConfirmation()
    }

    private var hasContent: Bool {
        Self.hasMeaningfulContent(viewModel.content)
    }

    private func showCloseConfirmation() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "If you don't save this note, its contents will be lost."
        alert.informativeText = "Are you sure you want to discard this MemoDolmaeng note?"
        alert.addButton(withTitle: "Save...")
        alert.addButton(withTitle: "Delete Note")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            window?.close()
        case .alertSecondButtonReturn:
            isDeleting = true
            window?.close()
        default:
            break
        }
    }

    private func handleContentChange(_ content: String) {
        if Self.hasMeaningfulContent(content) {
            hasEverHadContent = true
            cancelAutoDelete()
            return
        }

        guard hasEverHadContent else {
            cancelAutoDelete()
            return
        }

        scheduleAutoDelete()
    }

    private func scheduleAutoDelete() {
        guard autoDeleteTask == nil else { return }

        viewModel.beginAutoDeleteCountdown(duration: Self.autoDeleteDelay)
        autoDeleteTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.autoDeleteDelay * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.completeAutoDeleteIfStillEmpty()
            }
        }
    }

    private func completeAutoDeleteIfStillEmpty() {
        autoDeleteTask = nil

        guard hasEverHadContent, !hasContent else {
            viewModel.cancelAutoDeleteCountdown()
            return
        }

        isDeleting = true
        window?.close()
    }

    private func cancelAutoDelete() {
        autoDeleteTask?.cancel()
        autoDeleteTask = nil
        viewModel.cancelAutoDeleteCountdown()
    }

    private static func hasMeaningfulContent(_ content: String) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyAutomaticFrame(contentHeight: CGFloat) {
        guard let window else { return }

        let targetHeight = min(
            max(ceil(contentHeight), NoteWindowMetrics.minimumAutomaticHeight),
            maximumAutomaticHeight(for: window)
        )
        let targetWidth = NoteWindowMetrics.automaticWidth
        let currentFrame = window.frame

        guard abs(currentFrame.height - targetHeight) >= 1 || abs(currentFrame.width - targetWidth) >= 1 else {
            return
        }

        let nextFrame = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetHeight,
            width: targetWidth,
            height: targetHeight
        )

        isApplyingProgrammaticFrame = true
        window.setFrame(nextFrame, display: true)
        isApplyingProgrammaticFrame = false
        onFrameChange(noteID, nextFrame)
    }

    private func maximumAutomaticHeight(for window: NSWindow) -> CGFloat {
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? NoteWindowMetrics.maximumAutomaticHeight
        return max(
            NoteWindowMetrics.minimumAutomaticHeight,
            min(NoteWindowMetrics.maximumAutomaticHeight, visibleHeight - 80)
        )
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        onFrameChange(noteID, frame)
    }

    private func focusEditor(retryCount: Int = 0) {
        guard let contentView = window?.contentView else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let markdownWebView = self.findWebView(in: contentView) {
                self.window?.makeFirstResponder(markdownWebView)
                markdownWebView.evaluateJavaScript("window.focusMemoEditor && window.focusMemoEditor();")
                return
            }

            guard let textView = self.findTextView(in: contentView) else {
                if retryCount < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusEditor(retryCount: retryCount + 1)
                    }
                }

                return
            }

            self.window?.makeFirstResponder(textView)
        }
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }

        for subview in view.subviews {
            if let webView = findWebView(in: subview) {
                return webView
            }
        }

        return nil
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }
}
