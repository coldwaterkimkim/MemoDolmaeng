import AppKit
import WebKit
import XCTest
@testable import MemoDolmaeng

final class EditorImageIntegrationTests: XCTestCase {
    @MainActor
    func testCrepeLoadsDefaultUIAndEmptyDocumentStartsAsAParagraph() async throws {
        _ = NSApplication.shared
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengMilkdownEmptyTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MemoAssetSchemeHandler(rootURL: temporaryDirectory),
            forURLScheme: MemoAssetSchemeHandler.scheme
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 340), configuration: configuration)
        let indexURL = try XCTUnwrap(MarkdownEditorView.editorIndexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror'))"
        }
        let crepeUI = try await evaluate(
            webView,
            "Boolean(document.querySelector('.milkdown-toolbar') && document.querySelector('.crepe-placeholder') && document.querySelector('.milkdown-link-edit'))"
        ) as? Bool
        let firstBlock = try await evaluate(
            webView,
            "document.querySelector('.ProseMirror > p, .ProseMirror > h1')?.tagName"
        ) as? String
        let markdown = try await evaluateMarkdown(webView)
        XCTAssertEqual(firstBlock, "P")
        XCTAssertTrue(crepeUI ?? false)
        XCTAssertEqual(markdown, "")

        _ = try await evaluate(webView, "window.setMemoMarkdown('#\\n'); true")
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror h1'))"
        }
        let headingIsVisible = try await evaluate(
            webView,
            "(() => { const h1 = document.querySelector('.ProseMirror h1'); const br = h1?.querySelector('br.ProseMirror-trailingBreak'); return Boolean(h1 && h1.getBoundingClientRect().height > 0 && (!br || getComputedStyle(br).display !== 'none')); })()"
        ) as? Bool
        XCTAssertTrue(headingIsVisible ?? false)
    }

    @MainActor
    func testBundledEditorLoadsCopiedImageThroughCustomScheme() async throws {
        _ = NSApplication.shared
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengImageTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let noteID = UUID()
        let attachments = temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
        let noteDirectory = attachments.appendingPathComponent(noteID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let imageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        try imageData.write(to: noteDirectory.appendingPathComponent("image.png"))

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MemoAssetSchemeHandler(rootURL: attachments),
            forURLScheme: MemoAssetSchemeHandler.scheme
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 340), configuration: configuration)
        let indexURL = try XCTUnwrap(MarkdownEditorView.editorIndexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        try await waitUntil(webView: webView) {
            "typeof window.setMemoMarkdown === 'function' && Boolean(document.querySelector('.ProseMirror'))"
        }

        let assetURL = AttachmentService.assetURL(noteID: noteID, fileName: "image.png")
        let markdown = "본문\n\n![1.00](\(assetURL.absoluteString) \"테스트\")"
        let literal = String(data: try JSONEncoder().encode(markdown), encoding: .utf8)!
        _ = try await evaluate(webView, "window.setMemoMarkdown(\(literal)); true")

        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.milkdown-image-block img[src^=\"memodolmaeng-asset://\"]')?.complete && document.querySelector('.milkdown-image-block img[src^=\"memodolmaeng-asset://\"]')?.naturalWidth > 0)"
        }
    }

    @MainActor
    func testBundledEditorRendersSemanticMarkdownWithoutSourceMarkers() async throws {
        _ = NSApplication.shared
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengMilkdownTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MemoAssetSchemeHandler(rootURL: temporaryDirectory),
            forURLScheme: MemoAssetSchemeHandler.scheme
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 340), configuration: configuration)
        let indexURL = try XCTUnwrap(MarkdownEditorView.editorIndexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror'))"
        }

        let markdown = "**굵게**와 <u>밑줄</u>\n\n<div style=\"text-align: center;\">\n가운데\n</div>"
        let literal = String(data: try JSONEncoder().encode(markdown), encoding: .utf8)!
        _ = try await evaluate(webView, "window.setMemoMarkdown(\(literal)); true")

        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror strong') && document.querySelector('.ProseMirror u') && document.querySelector('.ProseMirror p[style*=\"center\"]'))"
        }

        let visibleText = try await evaluate(webView, "document.querySelector('.ProseMirror').innerText") as? String
        XCTAssertFalse(visibleText?.contains("**") ?? true)
        XCTAssertFalse(visibleText?.contains("<u>") ?? true)
        let serialized = try await evaluate(webView, "window.getMemoMarkdown()") as? String
        XCTAssertEqual(serialized, markdown)
    }

    @MainActor
    func testMilkdownCommandsSerializeUserFormattingAndPreserveUnsafeHTMLAsText() async throws {
        _ = NSApplication.shared
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengMilkdownCommandTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MemoAssetSchemeHandler(rootURL: temporaryDirectory),
            forURLScheme: MemoAssetSchemeHandler.scheme
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 340), configuration: configuration)
        let indexURL = try XCTUnwrap(MarkdownEditorView.editorIndexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror'))"
        }

        let unsafeHTML = "<script>window.memoUnsafeHTMLRan = true</script>\n\n한글 입력"
        let unsafeLiteral = String(data: try JSONEncoder().encode(unsafeHTML), encoding: .utf8)!
        _ = try await evaluate(webView, "window.setMemoMarkdown(\(unsafeLiteral)); true")
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('[data-type=\"html\"]'))"
        }
        let unsafeHTMLRan = try await evaluate(webView, "Boolean(window.memoUnsafeHTMLRan)") as? Bool
        let scriptWasBlocked = try await evaluate(
            webView,
            "document.querySelector('.ProseMirror script') === null"
        ) as? Bool
        let preservedHTML = try await evaluate(webView, "window.getMemoMarkdown()") as? String
        XCTAssertFalse(unsafeHTMLRan ?? true)
        XCTAssertTrue(scriptWasBlocked ?? false)
        XCTAssertEqual(preservedHTML, unsafeHTML)

        let plain = "한글 입력"
        let plainLiteral = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        _ = try await evaluate(
            webView,
            "window.setMemoMarkdown(\(plainLiteral)); window.memoEditorCommand('selectAll'); window.memoEditorCommand('bold'); true"
        )
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror strong')) && window.getMemoMarkdown().includes('**한글 입력**')"
        }
    }

    @MainActor
    private func waitUntil(
        webView: WKWebView,
        expression: () -> String
    ) async throws {
        for _ in 0..<100 {
            if (try? await evaluate(webView, expression())) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Timed out waiting for editor JavaScript: \(expression())")
    }

    @MainActor
    private func evaluate(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    @MainActor
    private func evaluateMarkdown(_ webView: WKWebView) async throws -> String? {
        try await evaluate(webView, "window.getMemoMarkdown()") as? String
    }
}
