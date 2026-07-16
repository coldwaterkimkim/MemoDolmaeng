import AppKit
import MarkdownEngine
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEditorView: View {
    @Binding var markdown: String

    let documentID: UUID
    let textColor: NSColor
    let assetRootURL: URL
    let onInteraction: () -> Void
    let onImageUpload: (Data, String) throws -> URL

    @ObservedObject private var preferences = AppPreferences.shared
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?
    @State private var isBold = false
    @State private var isItalic = false

    var body: some View {
        let toolbarColor = Color(nsColor: textColor)
        let markdownBus = MemoMarkdownBus(documentID: documentID)

        VStack(spacing: 0) {
            NativeMarkdownToolbar(
                bus: markdownBus,
                textColor: textColor,
                isBold: isBold,
                isItalic: isItalic,
                onInsertImage: chooseImage
            )

            Rectangle()
                .fill(toolbarColor.opacity(0.2))
                .frame(height: 1)

            NativeTextViewWrapper(
                text: $markdown,
                isWikiLinkActive: $isWikiLinkActive,
                pendingInlineReplacement: $pendingInlineReplacement,
                configuration: editorConfiguration,
                fontName: NSFont.systemFont(ofSize: preferences.bodyFontSize).fontName,
                fontSize: preferences.bodyFontSize,
                documentId: documentID.uuidString,
                onPasteImage: importPastedImage,
                onLinkClick: openLink,
                placeholder: NSAttributedString(
                    string: "메모를 입력해",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: preferences.bodyFontSize),
                        .foregroundColor: textColor.withAlphaComponent(0.42)
                    ]
                )
            )
        }
        .background(Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onInteraction))
        .onReceive(NotificationCenter.default.publisher(for: markdownBus.selectionBoldDidChange)) {
            isBold = $0.userInfo?["isBold"] as? Bool ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: markdownBus.selectionItalicDidChange)) {
            isItalic = $0.userInfo?["isItalic"] as? Bool ?? false
        }
    }

    private var editorConfiguration: MarkdownEditorConfiguration {
        let bodySize = max(1, preferences.bodyFontSize)
        let mutedText = textColor.withAlphaComponent(0.56)
        let disabledText = textColor.withAlphaComponent(0.34)

        return MarkdownEditorConfiguration(
            theme: MarkdownEditorTheme(
                bodyText: textColor,
                mutedText: mutedText,
                disabledText: disabledText,
                headingMarker: mutedText,
                link: NSColor.systemBlue,
                incompleteLink: NSColor.systemBlue.withAlphaComponent(0.72),
                findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.45),
                findCurrentMatchHighlight: NSColor.systemOrange.withAlphaComponent(0.55),
                latexLightModeText: textColor,
                latexDarkModeText: textColor,
                strikethroughColor: textColor,
                highlightColor: NSColor.systemYellow.withAlphaComponent(0.36)
            ),
            services: MarkdownEditorServices(
                images: MemoEmbeddedImageProvider(rootURL: assetRootURL),
                bus: MemoMarkdownBus(documentID: documentID).editorBus
            ),
            codeBlock: CodeBlockStyle(
                fontSizeScale: preferences.codeFontSize / bodySize,
                paragraphSpacing: preferences.codeBlockSpacing,
                horizontalIndent: preferences.horizontalInset
            ),
            inlineCode: InlineCodeStyle(fontSizeScale: preferences.codeFontSize / bodySize),
            lists: ListStyle(
                helpersEnabled: true,
                autoClosePairsEnabled: true,
                indentPerLevel: preferences.listIndent,
                maximumNestingLevel: 6,
                extraLineHeight: 1
            ),
            headings: HeadingStyle(
                fontMultipliers: [
                    preferences.heading1FontSize / bodySize,
                    preferences.heading2FontSize / bodySize,
                    preferences.heading3FontSize / bodySize,
                    1,
                    0.92,
                    0.84
                ],
                topSpacingEm: [
                    preferences.heading1Spacing / bodySize,
                    preferences.heading2Spacing / bodySize,
                    preferences.heading3Spacing / bodySize,
                    0.12,
                    0.1,
                    0.08
                ]
            ),
            imageEmbed: ImageEmbedStyle(
                minimumWidth: 48,
                fallbackMaxWidth: 560,
                unreasonableMaxWidth: 1_000_000,
                paragraphSpacing: 6,
                imageGap: 6
            ),
            blockquote: BlockquoteStyle(extraLineHeight: 1),
            paragraph: ParagraphStyle(
                spacingFactor: preferences.paragraphSpacing / bodySize,
                lineHeightExtraSpacing: 1
            ),
            overscroll: OverscrollPolicy(
                percent: 0.18,
                maxPoints: 90,
                minPoints: 16,
                activationStartFraction: 0.25,
                activationRangeFraction: 0.75
            ),
            safeAreaInsets: .default,
            scrollers: .hidden,
            textInsets: TextInsets(
                horizontal: preferences.horizontalInset,
                vertical: preferences.verticalInset
            ),
            spellChecking: SpellCheckingPolicy(
                continuousSpellChecking: true,
                grammarChecking: false,
                automaticSpellingCorrection: true
            ),
            extensions: [StrikethroughExtension()]
        )
    }

    private func openLink(_ value: String) {
        guard let url = URL(string: value), Self.isSafeExternalURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "메모에 이미지 추가"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            let assetURL = try onImageUpload(data, sourceURL.lastPathComponent)
            MemoMarkdownBus(documentID: documentID).post(
                MemoMarkdownBus(documentID: documentID).applyImageRequest,
                userInfo: ["url": assetURL.absoluteString]
            )
        } catch {
            presentImageError(error)
        }
    }

    private func importPastedImage(_ pasteboard: NSPasteboard) -> String? {
        do {
            if let sourceURL = pasteboardFileURL(pasteboard) {
                let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                let assetURL = try onImageUpload(data, sourceURL.lastPathComponent)
                return "![](" + assetURL.absoluteString + ")"
            }

            if let image = NSImage(pasteboard: pasteboard),
               let tiff = image.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiff),
               let data = representation.representation(using: .png, properties: [:]) {
                let assetURL = try onImageUpload(data, "붙여넣은 이미지.png")
                return "![](" + assetURL.absoluteString + ")"
            }
        } catch {
            presentImageError(error)
        }
        return nil
    }

    private func pasteboardFileURL(_ pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?
            .first(where: { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            })
    }

    private func presentImageError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "이미지를 추가할 수 없어"
        alert.runModal()
    }

    private static func isSafeExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}

private struct NativeMarkdownToolbar: View {
    let bus: MemoMarkdownBus
    let textColor: NSColor
    let isBold: Bool
    let isItalic: Bool
    let onInsertImage: () -> Void

    private var toolbarColor: Color { Color(nsColor: textColor) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Menu {
                    ForEach(1...3, id: \.self) { level in
                        Button("제목 \(level)") { bus.heading(level) }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(toolbarColor)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .tint(toolbarColor)
                .fixedSize()
                .help("본문 및 제목")

                toolbarButton("bold", help: "굵게", active: isBold) {
                    bus.post(bus.applyBoldRequest)
                }
                toolbarButton("italic", help: "기울임", active: isItalic) {
                    bus.post(bus.applyItalicRequest)
                }
                toolbarButton("strikethrough", help: "취소선") {
                    bus.post(bus.applyStrikethroughRequest)
                }

                Rectangle()
                    .fill(toolbarColor.opacity(0.24))
                    .frame(width: 1, height: 16)

                toolbarButton("list.bullet", help: "글머리표") {
                    bus.post(bus.applyUnorderedListRequest)
                }
                toolbarButton("list.number", help: "번호 목록") {
                    bus.post(bus.applyOrderedListRequest)
                }
                toolbarButton("text.quote", help: "인용") {
                    bus.post(bus.applyBlockquoteRequest)
                }
                toolbarButton("chevron.left.forwardslash.chevron.right", help: "인라인 코드") {
                    bus.post(bus.applyInlineCodeRequest)
                }
                toolbarButton("curlybraces.square", help: "코드 블록") {
                    bus.post(bus.applyCodeBlockRequest)
                }
                toolbarButton("photo", help: "이미지 추가", action: onInsertImage)
            }
            .padding(.horizontal, 8)
            .foregroundStyle(toolbarColor)
            .tint(toolbarColor)
        }
        .frame(height: 36)
    }

    private func toolbarButton(
        _ symbol: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(toolbarColor)
                .frame(width: 26, height: 26)
                .background(active ? toolbarColor.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MemoMarkdownBus {
    let documentID: UUID

    var applyBoldRequest: Notification.Name { name("ApplyBold") }
    var applyItalicRequest: Notification.Name { name("ApplyItalic") }
    var applyHeadingRequest: Notification.Name { name("ApplyHeading") }
    var applyStrikethroughRequest: Notification.Name { name("ApplyStrikethrough") }
    var applyInlineCodeRequest: Notification.Name { name("ApplyInlineCode") }
    var applyBlockquoteRequest: Notification.Name { name("ApplyBlockquote") }
    var applyUnorderedListRequest: Notification.Name { name("ApplyUnorderedList") }
    var applyOrderedListRequest: Notification.Name { name("ApplyOrderedList") }
    var applyCodeBlockRequest: Notification.Name { name("ApplyCodeBlock") }
    var applyImageRequest: Notification.Name { name("ApplyImage") }
    var selectionBoldDidChange: Notification.Name { name("SelectionBold") }
    var selectionItalicDidChange: Notification.Name { name("SelectionItalic") }

    var editorBus: MarkdownEditorBus {
        MarkdownEditorBus(
        applyBoldRequest: applyBoldRequest,
        applyItalicRequest: applyItalicRequest,
        applyHeadingRequest: applyHeadingRequest,
        applyStrikethroughRequest: applyStrikethroughRequest,
        applyInlineCodeRequest: applyInlineCodeRequest,
        applyBlockquoteRequest: applyBlockquoteRequest,
        applyUnorderedListRequest: applyUnorderedListRequest,
        applyOrderedListRequest: applyOrderedListRequest,
        applyCodeBlockRequest: applyCodeBlockRequest,
        applyImageRequest: applyImageRequest,
        selectionBoldDidChange: selectionBoldDidChange,
        selectionItalicDidChange: selectionItalicDidChange
        )
    }

    func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    func heading(_ level: Int) {
        post(applyHeadingRequest, userInfo: ["level": level])
    }

    private func name(_ action: String) -> Notification.Name {
        Notification.Name("MemoDolmaeng.Markdown.\(documentID.uuidString).\(action)")
    }
}

struct MemoEmbeddedImageProvider: EmbeddedImageProvider {
    let rootURL: URL

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        guard let requestURL = URL(string: reference.name),
              let fileURL = MemoAssetSchemeHandler.resolvedFileURL(for: requestURL, rootURL: rootURL)
        else { return nil }
        return NSImage(contentsOf: fileURL)
    }

    func fingerprint() -> AnyHashable {
        rootURL.standardizedFileURL.path
    }
}
