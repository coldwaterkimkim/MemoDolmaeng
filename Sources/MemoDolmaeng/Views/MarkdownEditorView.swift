import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MarkdownEditorView: NSViewRepresentable {
    let markdown: String
    let theme: MarkdownEditorTheme
    let assetRootURL: URL
    let onInteraction: () -> Void
    let onMarkdownChange: (String) -> Void
    let onImageUpload: (Data, String) throws -> URL

    static var editorIndexURL: URL? {
        Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "MarkdownEditor"
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInteraction: onInteraction,
            onMarkdownChange: onMarkdownChange,
            onImageUpload: onImageUpload
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        for name in Coordinator.messageNames {
            userContentController.add(context.coordinator, name: name)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            MemoAssetSchemeHandler(rootURL: assetRootURL),
            forURLScheme: MemoAssetSchemeHandler.scheme
        )

        let webView = MemoMarkdownWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        let coordinator = context.coordinator
        webView.onInteraction = { [weak coordinator] in coordinator?.onInteraction() }
        webView.onRequestEditorCommand = { [weak coordinator] command in
            coordinator?.performCommand(command)
            return true
        }
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        context.coordinator.attach(webView)
        context.coordinator.loadEditor(markdown: markdown, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onInteraction = onInteraction
        context.coordinator.onMarkdownChange = onMarkdownChange
        context.coordinator.onImageUpload = onImageUpload
        context.coordinator.sync(markdown: markdown, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        for name in Coordinator.messageNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        static let messageNames = [
            "editorReady",
            "editorChanged",
            "editorFocusChanged",
            "editorAppCommand",
            "editorImageUpload"
        ]

        var onInteraction: () -> Void
        var onMarkdownChange: (String) -> Void
        var onImageUpload: (Data, String) throws -> URL

        private weak var webView: WKWebView?
        private var isReady = false
        private var pendingMarkdown = ""
        private var pendingTheme = MarkdownEditorTheme.current()
        private var editorMarkdown = ""

        init(
            onInteraction: @escaping () -> Void,
            onMarkdownChange: @escaping (String) -> Void,
            onImageUpload: @escaping (Data, String) throws -> URL
        ) {
            self.onInteraction = onInteraction
            self.onMarkdownChange = onMarkdownChange
            self.onImageUpload = onImageUpload
            super.init()
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

            guard let indexURL = MarkdownEditorView.editorIndexURL else {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            sync(markdown: pendingMarkdown, theme: pendingTheme)
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

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.title = "메모에 이미지 추가"
            panel.allowedContentTypes = [.image]
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection

            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
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
            case "editorFocusChanged":
                guard let payload = message.body as? [String: Any],
                      let focused = payload["focused"] as? Bool
                else { return }
                (webView as? MemoMarkdownWebView)?.editorIsFocused = focused
            case "editorAppCommand":
                guard let command = (message.body as? [String: Any])?["command"] as? String else { return }
                handleAppCommand(command)
            case "editorImageUpload":
                handleImageUpload(message.body)
            default:
                break
            }
        }

        private func handleImageUpload(_ body: Any) {
            guard let payload = body as? [String: Any],
                  let requestID = payload["requestID"] as? String,
                  let fileName = payload["fileName"] as? String,
                  let base64 = payload["base64"] as? String,
                  base64.utf8.count <= 30_000_000,
                  let data = Data(base64Encoded: base64)
            else {
                if let requestID = (body as? [String: Any])?["requestID"] as? String {
                    resolveImageUpload(requestID: requestID, error: "이미지 데이터가 올바르지 않아.")
                }
                return
            }

            do {
                let url = try onImageUpload(data, fileName)
                resolveImageUpload(requestID: requestID, url: url)
            } catch {
                resolveImageUpload(requestID: requestID, error: error.localizedDescription)
            }
        }

        private func resolveImageUpload(requestID: String, url: URL? = nil, error: String? = nil) {
            let urlValue = url.map { javascriptStringLiteral($0.absoluteString) } ?? "null"
            let errorValue = error.map(javascriptStringLiteral) ?? "null"
            evaluate(
                "window.resolveMemoImageUpload && window.resolveMemoImageUpload(\(javascriptStringLiteral(requestID)), \(urlValue), \(errorValue));"
            )
        }

        private func applyTheme(_ theme: MarkdownEditorTheme) {
            guard let data = try? JSONSerialization.data(withJSONObject: theme.values),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            evaluate("window.setMemoEditorTheme && window.setMemoEditorTheme(\(json));")
        }

        private func handleAppCommand(_ command: String) {
            guard let controller = webView?.window?.windowController as? MemoPanelController else { return }
            switch command {
            case "closeNote":
                controller.requestFold()
            case "newNote":
                NotificationCenter.default.post(name: .memoDolmaengCreateNoteRequested, object: self)
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
            evaluate("window.focusMemoEditorAt && window.focusMemoEditorAt(\(Double(x)), \(Double(y)));")
        }

        private func javascriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8)
            else { return "\"\"" }
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

    static func current(
        preferences: AppPreferences = .shared,
        textColor: NSColor? = nil,
        showsTopBar: Bool = true
    ) -> MarkdownEditorTheme {
        MarkdownEditorTheme(values: [
            "memo-text-color": cssColor(textColor ?? preferences.textColor),
            "memo-body-font-size": cssLength(preferences.bodyFontSize),
            "memo-heading1-font-size": cssLength(preferences.heading1FontSize),
            "memo-heading2-font-size": cssLength(preferences.heading2FontSize),
            "memo-heading3-font-size": cssLength(preferences.heading3FontSize),
            "memo-code-font-size": cssLength(preferences.codeFontSize),
            "memo-padding-x": cssLength(preferences.horizontalInset),
            "memo-padding-top": cssLength(preferences.verticalInset + contentTopClearance),
            "memo-padding-bottom": cssLength(preferences.verticalInset),
            "memo-list-indent": cssLength(preferences.listIndent),
            "memo-quote-indent": cssLength(preferences.quoteIndent),
            "memo-top-bar-display": showsTopBar ? "flex" : "none"
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
    var onInteraction: (() -> Void)?
    var onRequestEditorCommand: ((String) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)
        if flags == .command,
           event.keyCode == KeyboardShortcuts.KeyCode.a,
           onRequestEditorCommand?("selectAll") == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
