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

        _ = try await evaluate(
            webView,
            "window.setMemoEditorTheme({'memo-top-bar-display': 'flex'}); true"
        )
        try await waitUntil(webView: webView) {
            "getComputedStyle(document.querySelector('.milkdown-top-bar')).display === 'flex'"
        }
        let topBarMetrics = try await evaluate(
            webView,
            "(() => { const bar = document.querySelector('.milkdown-top-bar'); const inner = bar?.querySelector('.top-bar-inner'); return { display: getComputedStyle(bar).display, height: bar?.getBoundingClientRect().height || 0, innerHeight: inner?.getBoundingClientRect().height || 0, pageWidth: document.documentElement.scrollWidth, viewportWidth: document.documentElement.clientWidth }; })()"
        ) as? [String: Any]
        XCTAssertEqual(topBarMetrics?["display"] as? String, "flex")
        XCTAssertLessThanOrEqual((topBarMetrics?["height"] as? NSNumber)?.doubleValue ?? .infinity, 39)
        XCTAssertLessThanOrEqual((topBarMetrics?["innerHeight"] as? NSNumber)?.doubleValue ?? .infinity, 38)
        XCTAssertLessThanOrEqual(
            (topBarMetrics?["pageWidth"] as? NSNumber)?.doubleValue ?? .infinity,
            (topBarMetrics?["viewportWidth"] as? NSNumber)?.doubleValue ?? 0
        )

        let longMarkdown = (0..<80).map { "본문 줄 \($0)" }.joined(separator: "\n\n")
        let longLiteral = String(data: try JSONEncoder().encode(longMarkdown), encoding: .utf8)!
        _ = try await evaluate(webView, "window.setMemoMarkdown(\(longLiteral)); true")
        try await waitUntil(webView: webView) {
            "document.querySelector('.ProseMirror').scrollHeight > document.querySelector('.ProseMirror').clientHeight"
        }
        let scrollMetrics = try await evaluate(
            webView,
            "(() => { const root = document.querySelector('.milkdown'); const bar = document.querySelector('.milkdown-top-bar'); const body = document.querySelector('.ProseMirror'); body.scrollTop = body.scrollHeight; const rootRect = root.getBoundingClientRect(); const barRect = bar.getBoundingClientRect(); const bodyRect = body.getBoundingClientRect(); return { rootOverflow: getComputedStyle(root).overflow, bodyOverflowY: getComputedStyle(body).overflowY, barBottom: barRect.bottom, bodyTop: bodyRect.top, bodyBottom: bodyRect.bottom, rootBottom: rootRect.bottom, scrollTop: body.scrollTop, scrollHeight: body.scrollHeight, clientHeight: body.clientHeight }; })()"
        ) as? [String: Any]
        XCTAssertEqual(scrollMetrics?["rootOverflow"] as? String, "hidden")
        XCTAssertEqual(scrollMetrics?["bodyOverflowY"] as? String, "auto")
        XCTAssertGreaterThan((scrollMetrics?["scrollTop"] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertGreaterThan(
            (scrollMetrics?["scrollHeight"] as? NSNumber)?.doubleValue ?? 0,
            (scrollMetrics?["clientHeight"] as? NSNumber)?.doubleValue ?? .infinity
        )
        XCTAssertGreaterThanOrEqual(
            (scrollMetrics?["bodyTop"] as? NSNumber)?.doubleValue ?? 0,
            ((scrollMetrics?["barBottom"] as? NSNumber)?.doubleValue ?? .infinity) - 0.5
        )
        XCTAssertLessThanOrEqual(
            (scrollMetrics?["bodyBottom"] as? NSNumber)?.doubleValue ?? .infinity,
            ((scrollMetrics?["rootBottom"] as? NSNumber)?.doubleValue ?? 0) + 0.5
        )

        _ = try await evaluate(
            webView,
            "window.setMemoEditorTheme({'memo-top-bar-display': 'none'}); true"
        )
        let hiddenTopBar = try await evaluate(
            webView,
            "getComputedStyle(document.querySelector('.milkdown-top-bar')).display === 'none'"
        ) as? Bool
        XCTAssertTrue(hiddenTopBar ?? false)

        _ = try await evaluate(webView, "window.setMemoMarkdown('#\\n'); true")
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror h1'))"
        }
        let headingIsVisible = try await evaluate(
            webView,
            "(() => { const h1 = document.querySelector('.ProseMirror h1'); const br = h1?.querySelector('br.ProseMirror-trailingBreak'); return Boolean(h1 && h1.getBoundingClientRect().height > 0 && (!br || getComputedStyle(br).display !== 'none')); })()"
        ) as? Bool
        XCTAssertTrue(headingIsVisible ?? false)

        _ = try await evaluate(webView, "window.setMemoMarkdown('# 제목\\n\\n본문'); true")
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror h1') && document.querySelector('.ProseMirror p'))"
        }
        let textStrokeIsAbsent = try await evaluate(
            webView,
            "[...document.querySelectorAll('.ProseMirror h1, .ProseMirror p')].every((node) => getComputedStyle(node).webkitTextStrokeWidth === '0px')"
        ) as? Bool
        XCTAssertTrue(textStrokeIsAbsent ?? false)

        let firstHeadingMargin = try await evaluate(
            webView,
            "parseFloat(getComputedStyle(document.querySelector('.ProseMirror h1')).marginTop)"
        ) as? NSNumber
        XCTAssertLessThanOrEqual(firstHeadingMargin?.doubleValue ?? .infinity, 10)

        _ = try await evaluate(webView, "window.setMemoMarkdown('윗줄\\n\\n# 제목\\n\\n본문'); true")
        try await waitUntil(webView: webView) {
            "Boolean(document.querySelector('.ProseMirror p + h1'))"
        }
        let followingHeadingMargin = try await evaluate(
            webView,
            "parseFloat(getComputedStyle(document.querySelector('.ProseMirror p + h1')).marginTop)"
        ) as? NSNumber
        XCTAssertLessThanOrEqual(followingHeadingMargin?.doubleValue ?? .infinity, 10)
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
