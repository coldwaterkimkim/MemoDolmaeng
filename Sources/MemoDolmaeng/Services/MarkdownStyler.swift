import AppKit

enum MarkdownBlockStyle {
    case body
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case quote
    case checkbox
    case checkedCheckbox
    case codeBlock
}

enum MarkdownInlineStyle {
    case bold
    case italic
    case code
}

enum MarkdownStyler {
    @discardableResult
    static func transformMarkdown(in textView: NoteTextView) -> Bool {
        false
    }

    static func applyBlockStyle(_ style: MarkdownBlockStyle, to textView: NoteTextView) {
        guard let textStorage = textView.textStorage else { return }

        let selectedRange = textView.selectedRange()
        let source = textStorage.string as NSString
        let paragraphRange = source.paragraphRange(for: selectedRange)

        if style == .codeBlock {
            let selectedText = source.substring(with: selectedRange)
            let replacement = selectedText.isEmpty ? "```\n\n```" : "```\n\(selectedText)\n```"
            let caretOffset = selectedText.isEmpty ? 4 : replacement.count
            replaceText(
                in: selectedRange,
                with: replacement,
                textView: textView,
                caretOffset: caretOffset
            )
            return
        }

        if style == .body {
            guard let markerRange = existingRawBlockMarkerRange(in: paragraphRange, textStorage: textStorage) else {
                return
            }

            replaceText(in: markerRange, with: "", textView: textView, caretOffset: 0)
            return
        }

        guard let prefix = rawMarkdownPrefix(for: style) else { return }
        let markerRange = existingRawBlockMarkerRange(in: paragraphRange, textStorage: textStorage)
            ?? NSRange(location: paragraphRange.location, length: 0)
        replaceText(in: markerRange, with: prefix, textView: textView)
    }

    static func applyInlineStyle(_ style: MarkdownInlineStyle, to textView: NoteTextView) {
        guard let textStorage = textView.textStorage else { return }

        let selectedRange = textView.selectedRange()
        let marker: String

        switch style {
        case .bold:
            marker = "**"
        case .italic:
            marker = "*"
        case .code:
            marker = "`"
        }

        let selectedText = (textStorage.string as NSString).substring(with: selectedRange)
        let replacement = "\(marker)\(selectedText)\(marker)"
        let caretOffset = selectedText.isEmpty ? marker.count : replacement.count
        replaceText(in: selectedRange, with: replacement, textView: textView, caretOffset: caretOffset)
    }

    static func insertDivider(in textView: NoteTextView) {
        replaceText(in: textView.selectedRange(), with: "---\n", textView: textView)
    }

    static func addLink(to textView: NoteTextView, url: URL) {
        guard sanitizedURL(from: url.absoluteString) != nil,
              let textStorage = textView.textStorage
        else {
            return
        }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else { return }

        let selectedText = (textStorage.string as NSString).substring(with: selectedRange)
        replaceText(
            in: selectedRange,
            with: "[\(selectedText)](\(url.absoluteString))",
            textView: textView
        )
    }

    static func insertImage(_ image: NSImage, in textView: NoteTextView) {
        let maxWidth = NoteWindowMetrics.automaticWidth - (NoteWindowMetrics.contentHorizontalInset * 2)
        let imageSize = image.size
        let scale = imageSize.width > 0 ? min(1, maxWidth / imageSize.width) : 1
        let scaledSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let scaledImage = image.copy() as? NSImage ?? image
        scaledImage.size = scaledSize

        let attachment = NSTextAttachment()
        attachment.image = scaledImage
        attachment.bounds = CGRect(origin: .zero, size: scaledSize)

        textView.textStorage?.replaceCharacters(
            in: textView.selectedRange(),
            with: NSAttributedString(attachment: attachment)
        )
        textView.didChangeText()
    }

    static func updateTypingAttributes(for textView: NSTextView) {
        textView.typingAttributes = RichTextArchive.baseAttributes
    }

    static func attributes(for style: MarkdownBlockStyle) -> [NSAttributedString.Key: Any] {
        RichTextArchive.baseAttributes
    }

    private static func replaceText(
        in range: NSRange,
        with string: String,
        textView: NSTextView,
        caretOffset: Int? = nil
    ) {
        guard let textStorage = textView.textStorage else { return }

        textStorage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: string, attributes: RichTextArchive.baseAttributes)
        )
        textView.setSelectedRange(NSRange(location: range.location + (caretOffset ?? string.count), length: 0))
        textView.typingAttributes = RichTextArchive.baseAttributes
        textView.didChangeText()
    }

    private static func rawMarkdownPrefix(for style: MarkdownBlockStyle) -> String? {
        switch style {
        case .heading1:
            return "# "
        case .heading2:
            return "## "
        case .heading3:
            return "### "
        case .bullet:
            return "- "
        case .numbered:
            return "1. "
        case .quote:
            return "> "
        case .checkbox:
            return "- [ ] "
        case .checkedCheckbox:
            return "- [x] "
        default:
            return nil
        }
    }

    private static func existingRawBlockMarkerRange(in paragraphRange: NSRange, textStorage: NSTextStorage) -> NSRange? {
        let source = textStorage.string as NSString
        guard paragraphRange.location <= source.length else { return nil }

        let line = source.substring(with: NSRange(
            location: paragraphRange.location,
            length: min(paragraphRange.length, source.length - paragraphRange.location)
        ))
        let trimmedLine = line.trimmingCharacters(in: .newlines)
        guard !trimmedLine.isEmpty else { return nil }

        let patterns = [
            #"^\s{0,3}#{1,3}\s+"#,
            #"^\s*[-*+]\s+\[[ xX]\]\s+"#,
            #"^\s*(?:[-*+]|\d+\.)\s+"#,
            #"^\s*>+\s?"#
        ]

        for pattern in patterns {
            guard let match = trimmedLine.range(of: pattern, options: .regularExpression) else { continue }
            let marker = String(trimmedLine[match])
            return NSRange(location: paragraphRange.location, length: (marker as NSString).length)
        }

        return nil
    }

    private static func sanitizedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else {
            return nil
        }

        return url
    }
}
