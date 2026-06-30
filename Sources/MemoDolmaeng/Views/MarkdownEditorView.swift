import AppKit
import SwiftUI
import WebKit

struct MarkdownEditorView: NSViewRepresentable {
    let markdown: String
    let theme: MarkdownEditorTheme
    let onMarkdownChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMarkdownChange: onMarkdownChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        for name in Coordinator.messageNames {
            userContentController.add(context.coordinator, name: name)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = MemoMarkdownWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let coordinator: Coordinator = context.coordinator
        webView.onRequestEditorFocus = { [weak coordinator] point in
            coordinator?.focusEditor(at: point)
        }
        webView.onRequestPaste = { [weak coordinator] in
            coordinator?.pasteFromPasteboard() ?? false
        }
        webView.onRequestEditorCommand = { [weak coordinator] command in
            coordinator?.performCommand(command)
            return true
        }
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }

        context.coordinator.attach(webView)
        context.coordinator.loadEditor(markdown: markdown, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMarkdownChange = onMarkdownChange
        context.coordinator.sync(markdown: markdown, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        for name in Coordinator.messageNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageNames = [
            "editorReady",
            "editorChanged",
            "editorHeightChanged",
            "editorFocusChanged",
            "editorAppCommand"
        ]

        var onMarkdownChange: (String) -> Void

        private weak var webView: WKWebView?
        private var isReady = false
        private var pendingMarkdown = ""
        private var pendingTheme = MarkdownEditorTheme.current()
        private var editorMarkdown = ""

        init(onMarkdownChange: @escaping (String) -> Void) {
            self.onMarkdownChange = onMarkdownChange
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach() {
            webView = nil
        }

        func loadEditor(markdown: String, theme: MarkdownEditorTheme) {
            pendingMarkdown = markdown
            pendingTheme = theme

            guard let indexURL = Bundle.module.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "MarkdownEditor"
            ) else {
                webView?.loadHTMLString(
                    "<html><body><pre>Markdown editor resource missing.</pre></body></html>",
                    baseURL: nil
                )
                return
            }

            webView?.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }

        func sync(markdown: String, theme: MarkdownEditorTheme) {
            pendingMarkdown = markdown
            pendingTheme = theme
            guard isReady else { return }

            if markdown != editorMarkdown {
                editorMarkdown = markdown
                evaluate("window.setMemoMarkdown(\(javascriptStringLiteral(markdown)));")
            }

            applyTheme(theme)
        }

        func focusEditor() {
            webView?.window?.makeFirstResponder(webView)
            evaluate("window.focusMemoEditor && window.focusMemoEditor();")
        }

        func performCommand(_ command: String) {
            evaluate("window.memoEditorCommand && window.memoEditorCommand(\(javascriptStringLiteral(command)));")
        }

        func pasteFromPasteboard() -> Bool {
            let pasteboard = NSPasteboard.general
            let appleHTMLType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")
            let html = pasteboard.string(forType: .html) ?? pasteboard.string(forType: appleHTMLType) ?? ""
            let plainText = pasteboard.string(forType: .string) ?? ""

            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !plainText.isEmpty
            else {
                return false
            }

            focusEditor()
            evaluate(
                "window.memoPasteClipboard && window.memoPasteClipboard(\(javascriptStringLiteral(html)), \(javascriptStringLiteral(plainText)));"
            )
            return true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            sync(markdown: pendingMarkdown, theme: pendingTheme)
            focusEditor()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }

            if Self.isSafeExternalURL(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "editorReady":
                isReady = true
                sync(markdown: pendingMarkdown, theme: pendingTheme)
            case "editorChanged":
                guard let markdown = (message.body as? [String: Any])?["markdown"] as? String else { return }
                editorMarkdown = markdown
                onMarkdownChange(markdown)
            case "editorHeightChanged":
                guard let height = (message.body as? [String: Any])?["height"] as? Double else { return }
                publishHeight(CGFloat(height))
            case "editorFocusChanged":
                guard let payload = message.body as? [String: Any],
                      let focused = payload["focused"] as? Bool
                else {
                    return
                }
                (webView as? MemoMarkdownWebView)?.editorIsFocused = focused
            case "editorAppCommand":
                guard let payload = message.body as? [String: Any],
                      let command = payload["command"] as? String
                else {
                    return
                }
                handleAppCommand(command)
            default:
                break
            }
        }

        private func applyTheme(_ theme: MarkdownEditorTheme) {
            guard let data = try? JSONSerialization.data(withJSONObject: theme.values, options: []),
                  let json = String(data: data, encoding: .utf8)
            else {
                return
            }
            evaluate("window.setMemoEditorTheme && window.setMemoEditorTheme(\(json));")
        }

        private func publishHeight(_ height: CGFloat) {
            guard let controller = webView?.window?.windowController as? NoteWindowController else { return }
            controller.noteContentHeightDidChange(height + NoteWindowMetrics.dragHandleHeight)
        }

        private func handleAppCommand(_ command: String) {
            guard let controller = webView?.window?.windowController as? NoteWindowController else { return }

            switch command {
            case "closeNote":
                controller.closeNote()
            case "newNote":
                NotificationCenter.default.post(name: .memoDolmaengCreateNoteRequested, object: self)
            case "toggleFloatOnTop":
                controller.toggleFloatsOnTop()
            case "toggleTranslucent":
                controller.toggleTranslucent()
            default:
                break
            }
        }

        private func evaluate(_ javascript: String) {
            webView?.evaluateJavaScript(javascript)
        }

        func focusEditor(at windowPoint: NSPoint) {
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)

            let viewPoint = webView.convert(windowPoint, from: nil)
            let x = max(0, min(webView.bounds.width, viewPoint.x))
            let y = max(0, min(webView.bounds.height, webView.bounds.height - viewPoint.y))
            evaluate(
                "window.focusMemoEditorAt && window.focusMemoEditorAt(\(Double(x)), \(Double(y)));"
            )
        }

        private func javascriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                return "\"\""
            }
            return encoded
        }

        private static func isSafeExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "mailto"].contains(scheme)
        }
    }
}

struct MarkdownEditorTheme: Equatable {
    let values: [String: String]
    private static let contentTopClearance: CGFloat = 12

    static func current(preferences: AppPreferences = .shared) -> MarkdownEditorTheme {
        MarkdownEditorTheme(values: [
            "memo-text-color": cssColor(preferences.textColor),
            "memo-text-stroke-color": cssColor(preferences.strokeColor),
            "memo-text-stroke-width": cssLength(max(0, preferences.strokeWidth)),
            "memo-body-font-size": cssLength(preferences.bodyFontSize),
            "memo-heading1-font-size": cssLength(preferences.heading1FontSize),
            "memo-heading2-font-size": cssLength(preferences.heading2FontSize),
            "memo-heading3-font-size": cssLength(preferences.heading3FontSize),
            "memo-code-font-size": cssLength(preferences.codeFontSize),
            "memo-padding-x": cssLength(preferences.horizontalInset),
            "memo-padding-top": cssLength(preferences.verticalInset + contentTopClearance),
            "memo-padding-bottom": cssLength(preferences.verticalInset),
            "memo-list-indent": cssLength(preferences.listIndent),
            "memo-quote-indent": cssLength(preferences.quoteIndent)
        ])
    }

    private static func cssLength(_ value: CGFloat) -> String {
        String(format: "%.2fpx", Double(value))
    }

    private static func cssColor(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let red = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let green = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let blue = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        let alpha = max(0, min(1, rgb.alphaComponent))
        return String(format: "rgba(%d, %d, %d, %.3f)", red, green, blue, Double(alpha))
    }
}

final class MemoMarkdownWebView: WKWebView {
    var editorIsFocused = false
    var onRequestEditorFocus: ((NSPoint) -> Void)?
    var onRequestPaste: (() -> Bool)?
    var onRequestEditorCommand: ((String) -> Bool)?
    private var inactiveDragContext: InactiveWebDragContext?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !editorIsFocused else {
            super.mouseDown(with: event)
            return
        }

        guard let window else {
            super.mouseDown(with: event)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        inactiveDragContext = InactiveWebDragContext(
            startOrigin: window.frame.origin,
            startPoint: window.convertPoint(toScreen: event.locationInWindow),
            clickPoint: event.locationInWindow,
            didMove: false
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let inactiveDragContext,
              let window
        else {
            super.mouseDragged(with: event)
            return
        }

        let nextPoint = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = nextPoint.x - inactiveDragContext.startPoint.x
        let deltaY = nextPoint.y - inactiveDragContext.startPoint.y

        if inactiveDragContext.didMove || hypot(deltaX, deltaY) > 2 {
            self.inactiveDragContext?.didMove = true
            window.setFrameOrigin(
                NSPoint(
                    x: inactiveDragContext.startOrigin.x + deltaX,
                    y: inactiveDragContext.startOrigin.y + deltaY
                )
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let inactiveDragContext else {
            super.mouseUp(with: event)
            return
        }

        self.inactiveDragContext = nil
        guard !inactiveDragContext.didMove else { return }

        onRequestEditorFocus?(inactiveDragContext.clickPoint)
    }

    func performMemoPaste(_ sender: Any?) -> Bool {
        onRequestPaste?() == true
    }

    @objc func paste(_ sender: Any?) {
        _ = performMemoPaste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)
        if flags == .command,
           event.keyCode == KeyboardShortcuts.KeyCode.v,
           performMemoPaste(nil) {
            return true
        }

        if flags == .command,
           event.keyCode == KeyboardShortcuts.KeyCode.a,
           onRequestEditorCommand?("selectAll") == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

private struct InactiveWebDragContext {
    let startOrigin: NSPoint
    let startPoint: NSPoint
    let clickPoint: NSPoint
    var didMove: Bool
}
