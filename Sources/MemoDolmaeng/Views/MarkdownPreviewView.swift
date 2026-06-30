import AppKit
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.loadRenderer(in: webView, markdown: markdown)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(markdown, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isReady = false
        private var pendingMarkdown = ""

        func loadRenderer(in webView: WKWebView, markdown: String) {
            pendingMarkdown = markdown

            guard let indexURL = Bundle.module.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "MarkdownRenderer"
            ) else {
                webView.loadHTMLString(
                    "<html><body><pre>Markdown renderer resource missing.</pre></body></html>",
                    baseURL: nil
                )
                return
            }

            let directoryURL = indexURL.deletingLastPathComponent()
            webView.loadFileURL(indexURL, allowingReadAccessTo: directoryURL)
        }

        func render(_ markdown: String, in webView: WKWebView) {
            pendingMarkdown = markdown
            guard isReady else { return }

            let encodedMarkdown = javascriptStringLiteral(markdown)
            webView.evaluateJavaScript("window.renderMarkdown(\(encodedMarkdown));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            render(pendingMarkdown, in: webView)
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

        private static func isSafeExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "mailto"].contains(scheme)
        }

        private func javascriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                return "\"\""
            }

            return encoded
        }
    }
}
