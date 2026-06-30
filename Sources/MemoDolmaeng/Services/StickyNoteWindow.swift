import AppKit

final class StickyNoteWindow: NSWindow {
    var onRequestClose: (() -> Void)?
    var onToggleFloatOnTop: (() -> Void)?
    var onToggleTranslucent: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func performClose(_ sender: Any?) {
        if let onRequestClose {
            onRequestClose()
        } else {
            close()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        if flags == .command, event.keyCode == KeyboardShortcuts.KeyCode.n {
            NotificationCenter.default.post(name: .memoDolmaengCreateNoteRequested, object: self)
            return true
        }

        if flags == .command, event.keyCode == KeyboardShortcuts.KeyCode.w {
            performClose(nil)
            return true
        }

        if flags.contains(.option) {
            switch event.keyCode {
            case KeyboardShortcuts.KeyCode.f:
                guard let onToggleFloatOnTop else { break }
                onToggleFloatOnTop()
                return true
            case KeyboardShortcuts.KeyCode.t:
                guard let onToggleTranslucent else { break }
                onToggleTranslucent()
                return true
            default:
                break
            }
        }

        if flags == .command,
           event.keyCode == KeyboardShortcuts.KeyCode.v,
           let markdownWebView = findMarkdownWebView(in: contentView),
           markdownWebView.performMemoPaste(nil) {
            return true
        }

        guard let textView = findTextView(in: contentView) else {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }

            return super.performKeyEquivalent(with: event)
        }

        if let noteTextView = textView as? NoteTextView,
           noteTextView.performFormatKeyEquivalent(with: event) {
            return true
        }

        switch (flags, event.keyCode) {
        case ([.command], KeyboardShortcuts.KeyCode.a):
            textView.selectAll(nil)
        case ([.command], KeyboardShortcuts.KeyCode.z):
            textView.undoManager?.undo()
        case ([.command, .shift], KeyboardShortcuts.KeyCode.z):
            textView.undoManager?.redo()
        case ([.command], KeyboardShortcuts.KeyCode.x):
            textView.cut(nil)
        case ([.command], KeyboardShortcuts.KeyCode.c):
            textView.copy(nil)
        case ([.command], KeyboardShortcuts.KeyCode.v):
            textView.paste(nil)
        case ([.command], KeyboardShortcuts.KeyCode.w):
            performClose(nil)
        default:
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }

            return super.performKeyEquivalent(with: event)
        }

        return true
    }

    private func findMarkdownWebView(in view: NSView?) -> MemoMarkdownWebView? {
        guard let view else { return nil }

        if let webView = view as? MemoMarkdownWebView {
            return webView
        }

        for subview in view.subviews {
            if let webView = findMarkdownWebView(in: subview) {
                return webView
            }
        }

        return nil
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }

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
