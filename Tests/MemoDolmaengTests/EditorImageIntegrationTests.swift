import AppKit
import MarkdownEngine
import SwiftUI
import XCTest
@testable import MemoDolmaeng

final class EditorImageIntegrationTests: XCTestCase {
    @MainActor
    func testNativeEditorUsesTextKit2AndKeepsScrollbarsHidden() async throws {
        let fixture = try NativeEditorFixture(markdown: "본문")
        defer { fixture.close() }

        let textView = try await fixture.textView()
        XCTAssertNotNil(textView.textLayoutManager)
        XCTAssertEqual(textView.string, "본문")

        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
    }

    @MainActor
    func testHashSpaceKeepsTheLineAndAppliesHeadingStyling() async throws {
        let fixture = try NativeEditorFixture(markdown: "")
        defer { fixture.close() }

        let textView = try await fixture.textView()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("#", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        textView.insertText("제목", replacementRange: textView.selectedRange())

        try await waitUntil {
            fixture.markdown == "# 제목"
        }
        XCTAssertEqual(textView.string, "# 제목")

        textView.insertText("\n본문", replacementRange: textView.selectedRange())
        try await waitUntil {
            fixture.markdown == "# 제목\n본문"
        }
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        try await waitUntil {
            guard let storage = textView.textStorage, storage.length >= 3 else { return false }
            let markerFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            return (markerFont?.pointSize ?? .infinity) < 1 &&
                (headingFont?.pointSize ?? 0) > AppPreferences.shared.bodyFontSize
        }
    }

    @MainActor
    func testNativeFormattingCommandAndKoreanTextRoundTrip() async throws {
        let fixture = try NativeEditorFixture(markdown: "한글 입력")
        defer { fixture.close() }

        let textView = try await fixture.textView()
        fixture.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        let bus = MemoMarkdownBus(documentID: fixture.documentID)
        bus.post(bus.applyBoldRequest)

        try await waitUntil {
            fixture.markdown == "**한글** 입력"
        }
        XCTAssertEqual(textView.string, "**한글** 입력")

        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(" 테스트", replacementRange: textView.selectedRange())
        try await waitUntil {
            fixture.markdown == "**한글** 입력 테스트"
        }
    }

    @MainActor
    func testFormattingCommandOnlyChangesItsDocument() async throws {
        let first = try NativeEditorFixture(markdown: "첫째")
        let second = try NativeEditorFixture(markdown: "둘째")
        defer {
            first.close()
            second.close()
        }

        let firstTextView = try await first.textView()
        let secondTextView = try await second.textView()
        firstTextView.setSelectedRange(NSRange(location: 0, length: firstTextView.string.utf16.count))
        secondTextView.setSelectedRange(NSRange(location: 0, length: secondTextView.string.utf16.count))

        let firstBus = MemoMarkdownBus(documentID: first.documentID)
        firstBus.post(firstBus.applyBoldRequest)

        try await waitUntil {
            first.markdown == "**첫째**"
        }
        XCTAssertEqual(second.markdown, "둘째")
    }

    @MainActor
    func testNativeImageProviderLoadsOnlyMemoAssetURLsInsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengNativeImageTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let noteID = UUID()
        let noteDirectory = root.appendingPathComponent(noteID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let imageData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        try imageData.write(to: noteDirectory.appendingPathComponent("image.png"))

        let provider = MemoEmbeddedImageProvider(rootURL: root)
        let assetURL = AttachmentService.assetURL(noteID: noteID, fileName: "image.png")
        XCTAssertNotNil(provider.image(for: EmbeddedImageRequest(name: assetURL.absoluteString)))
        XCTAssertNil(provider.image(for: EmbeddedImageRequest(name: "file:///tmp/image.png")))

        let traversal = URL(string: "memodolmaeng-asset://\(noteID.uuidString)/../image.png")!
        XCTAssertNil(provider.image(for: EmbeddedImageRequest(name: traversal.absoluteString)))
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for native editor state")
    }
}

@MainActor
private final class NativeEditorFixture {
    private(set) var markdown: String
    let window: NSWindow
    let documentID = UUID()

    private let temporaryDirectory: URL

    init(markdown: String) throws {
        setenv("MD_PERF", "0", 1)
        self.markdown = markdown
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoDolmaengNativeEditorTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let editor = MarkdownEditorView(
            markdown: Binding(
                get: { [weak self] in self?.markdown ?? "" },
                set: { [weak self] in self?.markdown = $0 }
            ),
            documentID: documentID,
            textColor: .labelColor,
            assetRootURL: temporaryDirectory,
            onImageUpload: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 340, height: 360)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.orderFront(nil)
    }

    func textView() async throws -> NSTextView {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let textView = findTextView(in: window.contentView) {
                return textView
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    func close() {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}
