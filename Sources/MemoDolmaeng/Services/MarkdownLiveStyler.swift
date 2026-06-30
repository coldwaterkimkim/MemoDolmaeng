import AppKit

enum MarkdownLiveStyler {
    static func apply(in textView: NoteTextView) {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0
        else {
            textView.typingAttributes = RichTextArchive.baseAttributes
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textView.isApplyingMarkdown = true
        textStorage.beginEditing()

        resetLiveAttributes(in: textStorage, range: fullRange)

        let codeBlockRanges = applyFencedCodeBlocks(in: textStorage)
        let mathBlockRanges = applyMathBlocks(in: textStorage, protectedRanges: codeBlockRanges)
        let blockProtectedRanges = codeBlockRanges + mathBlockRanges

        applyLineStyles(in: textStorage, protectedRanges: blockProtectedRanges)

        let inlineCodeRanges = applyInlineCode(in: textStorage, protectedRanges: blockProtectedRanges)
        let inlineProtectedRanges = blockProtectedRanges + inlineCodeRanges

        applyInlineMath(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyLinks(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyStrikethrough(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyBoldItalic(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyBold(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyItalic(in: textStorage, protectedRanges: inlineProtectedRanges)
        applyFootnoteReferences(in: textStorage, protectedRanges: inlineProtectedRanges)

        textStorage.endEditing()
        textView.isApplyingMarkdown = false
        textView.typingAttributes = RichTextArchive.baseAttributes
        textView.layoutManager?.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
    }

    private static func resetLiveAttributes(in textStorage: NSTextStorage, range: NSRange) {
        textStorage.addAttributes(RichTextArchive.baseAttributes, range: range)

        [
            NSAttributedString.Key.backgroundColor,
            .underlineStyle,
            .underlineColor,
            .strikethroughStyle,
            .strikethroughColor,
            .obliqueness,
            .baselineOffset,
            .link
        ].forEach { key in
            textStorage.removeAttribute(key, range: range)
        }
    }

    private static func applyFencedCodeBlocks(in textStorage: NSTextStorage) -> [NSRange] {
        let pattern = "```([A-Za-z0-9_+\\-.#]*)[ \\t]*\\n([\\s\\S]*?)\\n```"
        let ranges = matches(pattern, in: textStorage.string).map(\.range)

        for range in ranges {
            textStorage.addAttributes(codeBlockAttributes, range: clamped(range, in: textStorage))

            if let firstLineRange = firstLineRange(in: range, textStorage: textStorage) {
                textStorage.addAttributes(dimmedAttributes, range: firstLineRange)
            }
        }

        return ranges
    }

    private static func applyMathBlocks(
        in textStorage: NSTextStorage,
        protectedRanges: [NSRange]
    ) -> [NSRange] {
        let patterns = [
            #"(?m)^\s*\$\$\s*\n[\s\S]*?\n\s*\$\$\s*$"#,
            #"(?m)^\s*\\\[\s*\n[\s\S]*?\n\s*\\\]\s*$"#
        ]
        var ranges: [NSRange] = []

        for pattern in patterns {
            for match in matches(pattern, in: textStorage.string) where !intersects(match.range, protectedRanges) {
                ranges.append(match.range)
                textStorage.addAttributes(mathAttributes, range: clamped(match.range, in: textStorage))
            }
        }

        return ranges
    }

    private static func applyLineStyles(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        let nsString = textStorage.string as NSString
        var location = 0

        while location < nsString.length {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            defer {
                let nextLocation = NSMaxRange(paragraphRange)
                location = nextLocation > location ? nextLocation : nsString.length
            }

            guard !intersects(paragraphRange, protectedRanges) else { continue }

            let rawLine = nsString.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lineRange = clamped(paragraphRange, in: textStorage)

            if let heading = headingLevel(in: rawLine) {
                textStorage.addAttributes(headingAttributes(level: heading), range: lineRange)
                applyMarkerDim(pattern: #"^\s{0,3}#{1,6}\s+"#, paragraphRange: lineRange, textStorage: textStorage)
            } else if ["---", "***", "___"].contains(trimmed) {
                textStorage.addAttributes(dividerAttributes, range: lineRange)
            } else if rawLine.range(of: #"^\s*>+"#, options: .regularExpression) != nil {
                textStorage.addAttributes(quoteAttributes, range: lineRange)
                applyMarkerDim(pattern: #"^\s*>+\s?"#, paragraphRange: lineRange, textStorage: textStorage)
            } else if rawLine.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) != nil {
                textStorage.addAttributes(listAttributes, range: lineRange)
                applyMarkerDim(pattern: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, paragraphRange: lineRange, textStorage: textStorage)
            } else if rawLine.range(of: #"^\s*(?:[-*+]|\d+\.)\s+"#, options: .regularExpression) != nil {
                textStorage.addAttributes(listAttributes, range: lineRange)
                applyMarkerDim(pattern: #"^\s*(?:[-*+]|\d+\.)\s+"#, paragraphRange: lineRange, textStorage: textStorage)
            } else if rawLine.range(of: #"^\[\^[^\]]+\]:\s+"#, options: .regularExpression) != nil {
                textStorage.addAttributes(footnoteAttributes, range: lineRange)
            }
        }

        applyTableBlocks(in: textStorage, protectedRanges: protectedRanges)
    }

    private static func applyTableBlocks(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        let nsString = textStorage.string as NSString
        var ranges: [NSRange] = []
        var location = 0

        while location < nsString.length {
            let range = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            let nextLocation = NSMaxRange(range)
            location = nextLocation > location ? nextLocation : nsString.length
        }

        guard ranges.count >= 2 else { return }

        var index = 0
        while index < ranges.count - 1 {
            let header = nsString.substring(with: ranges[index]).trimmingCharacters(in: .newlines)
            let delimiter = nsString.substring(with: ranges[index + 1]).trimmingCharacters(in: .newlines)

            guard !intersects(ranges[index], protectedRanges),
                  !intersects(ranges[index + 1], protectedRanges),
                  isTableRow(header),
                  isTableDelimiter(delimiter)
            else {
                index += 1
                continue
            }

            var end = index + 2
            while end < ranges.count {
                let row = nsString.substring(with: ranges[end]).trimmingCharacters(in: .newlines)
                guard !intersects(ranges[end], protectedRanges), isTableRow(row) else { break }
                end += 1
            }

            let tableRange = NSRange(
                location: ranges[index].location,
                length: NSMaxRange(ranges[end - 1]) - ranges[index].location
            )
            textStorage.addAttributes(tableAttributes, range: clamped(tableRange, in: textStorage))
            index = end
        }
    }

    private static func applyInlineCode(
        in textStorage: NSTextStorage,
        protectedRanges: [NSRange]
    ) -> [NSRange] {
        var ranges: [NSRange] = []

        for match in matches(#"`([^`\n]+)`"#, in: textStorage.string) where !intersects(match.range, protectedRanges) {
            ranges.append(match.range)
            textStorage.addAttributes(inlineCodeAttributes, range: clamped(match.range, in: textStorage))
            applyDim(to: match.range(at: 0), markerPrefix: "`", markerSuffix: "`", textStorage: textStorage)
        }

        return ranges
    }

    private static func applyInlineMath(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        let patterns = [
            #"\\\(([^\n]+?)\\\)"#,
            #"(?<!\$)\$(?![\s\d])([^\n$]+?)(?<!\s)\$(?!\d)"#
        ]
        for pattern in patterns {
            for match in matches(pattern, in: textStorage.string) where !intersects(match.range, protectedRanges) {
                textStorage.addAttributes(inlineMathAttributes, range: clamped(match.range, in: textStorage))
            }
        }
    }

    private static func applyLinks(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        for match in matches(#"\[([^\]\n]+)\]\(([^\)\n]+)\)"#, in: textStorage.string) where !intersects(match.range, protectedRanges) {
            guard match.numberOfRanges > 2 else { continue }
            let urlString = (textStorage.string as NSString).substring(with: match.range(at: 2))
            guard safeURL(urlString) != nil else {
                textStorage.addAttributes(dimmedAttributes, range: clamped(match.range, in: textStorage))
                continue
            }

            textStorage.addAttributes(linkAttributes, range: clamped(match.range(at: 1), in: textStorage))
            applyDim(to: match.range, markerPrefix: "[", markerSuffix: ")", textStorage: textStorage)
        }

        for match in matches(#"https?://[^\s)]+"#, in: textStorage.string) where !intersects(match.range, protectedRanges) {
            textStorage.addAttributes(linkAttributes, range: clamped(match.range, in: textStorage))
        }
    }

    private static func applyStrikethrough(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        applyInlinePattern(
            #"~~([^~\n]+)~~"#,
            attributes: strikethroughAttributes,
            protectedRanges: protectedRanges,
            textStorage: textStorage
        )
    }

    private static func applyBoldItalic(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        applyInlinePattern(
            #"\*\*\*([^*\n]+)\*\*\*"#,
            attributes: boldItalicAttributes,
            protectedRanges: protectedRanges,
            textStorage: textStorage
        )
    }

    private static func applyBold(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        applyInlinePattern(
            #"(?<!\*)\*\*([^*\n]+)\*\*(?!\*)"#,
            attributes: boldAttributes,
            protectedRanges: protectedRanges,
            textStorage: textStorage
        )
    }

    private static func applyItalic(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        applyInlinePattern(
            #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            attributes: italicAttributes,
            protectedRanges: protectedRanges,
            textStorage: textStorage
        )
    }

    private static func applyInlinePattern(
        _ pattern: String,
        attributes: [NSAttributedString.Key: Any],
        protectedRanges: [NSRange],
        textStorage: NSTextStorage
    ) {
        for match in matches(pattern, in: textStorage.string) where !intersects(match.range, protectedRanges) {
            guard match.numberOfRanges > 1 else { continue }
            textStorage.addAttributes(attributes, range: clamped(match.range(at: 1), in: textStorage))
            textStorage.addAttributes(dimmedAttributes, range: clamped(match.range, in: textStorage))
            textStorage.addAttributes(attributes, range: clamped(match.range(at: 1), in: textStorage))
        }
    }

    private static func applyFootnoteReferences(in textStorage: NSTextStorage, protectedRanges: [NSRange]) {
        for match in matches(#"\[\^([^\]\n]+)\]"#, in: textStorage.string) where !intersects(match.range, protectedRanges) {
            textStorage.addAttributes(footnoteReferenceAttributes, range: clamped(match.range, in: textStorage))
        }
    }

    private static func applyMarkerDim(pattern: String, paragraphRange: NSRange, textStorage: NSTextStorage) {
        let source = textStorage.string as NSString
        let paragraph = source.substring(with: paragraphRange)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: paragraph, range: NSRange(location: 0, length: (paragraph as NSString).length))
        else {
            return
        }

        textStorage.addAttributes(
            dimmedAttributes,
            range: NSRange(location: paragraphRange.location + match.range.location, length: match.range.length)
        )
    }

    private static func applyDim(
        to range: NSRange,
        markerPrefix: String,
        markerSuffix: String,
        textStorage: NSTextStorage
    ) {
        let prefixLength = (markerPrefix as NSString).length
        let suffixLength = (markerSuffix as NSString).length

        if range.length >= prefixLength {
            textStorage.addAttributes(
                dimmedAttributes,
                range: clamped(NSRange(location: range.location, length: prefixLength), in: textStorage)
            )
        }

        if range.length >= suffixLength {
            textStorage.addAttributes(
                dimmedAttributes,
                range: clamped(NSRange(location: NSMaxRange(range) - suffixLength, length: suffixLength), in: textStorage)
            )
        }
    }

    private static func headingLevel(in line: String) -> Int? {
        let pattern = #"^\s{0,3}(#{1,6})\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges > 1
        else {
            return nil
        }

        return match.range(at: 1).length
    }

    private static func firstLineRange(in range: NSRange, textStorage: NSTextStorage) -> NSRange? {
        let source = textStorage.string as NSString
        guard range.location < source.length else { return nil }
        let paragraph = source.paragraphRange(for: NSRange(location: range.location, length: 0))
        return clamped(paragraph, in: textStorage)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.split(separator: "|", omittingEmptySubsequences: false).count >= 2
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            cell.trimmingCharacters(in: .whitespaces).range(
                of: #"^:?-{3,}:?$"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func matches(_ pattern: String, in string: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
    }

    private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func clamped(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange {
        let location = min(max(0, range.location), textStorage.length)
        let length = min(max(0, range.length), max(0, textStorage.length - location))
        return NSRange(location: location, length: length)
    }

    private static func safeURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else {
            return nil
        }
        return url
    }

    private static var dimmedAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: AppPreferences.shared.textColor.withAlphaComponent(0.48)]
    }

    private static var headingMarkerColor: NSColor {
        AppPreferences.shared.textColor.withAlphaComponent(0.44)
    }

    private static func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
        let fontSize: CGFloat
        switch level {
        case 1:
            fontSize = RichTextArchive.heading1FontSize
        case 2:
            fontSize = RichTextArchive.heading2FontSize
        case 3:
            fontSize = RichTextArchive.heading3FontSize
        case 4:
            fontSize = max(RichTextArchive.baseFontSize + 1, 13)
        default:
            fontSize = RichTextArchive.baseFontSize
        }
        return [
            .font: RichTextArchive.appFont(ofSize: fontSize, bold: true),
            .foregroundColor: AppPreferences.shared.textColor
        ]
    }

    private static var listAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: AppPreferences.shared.textColor]
    }

    private static var quoteAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: AppPreferences.shared.textColor.withAlphaComponent(0.86),
            .obliqueness: RichTextArchive.italicObliqueness
        ]
    }

    private static var dividerAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: AppPreferences.shared.textColor.withAlphaComponent(0.58),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    private static var codeBlockAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.codeFont(),
            .foregroundColor: AppPreferences.shared.textColor,
            .backgroundColor: NSColor.black.withAlphaComponent(0.12)
        ]
    }

    private static var inlineCodeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.codeFont(),
            .foregroundColor: AppPreferences.shared.textColor,
            .backgroundColor: NSColor.black.withAlphaComponent(0.12)
        ]
    }

    private static var tableAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.codeFont(),
            .foregroundColor: AppPreferences.shared.textColor,
            .backgroundColor: NSColor.black.withAlphaComponent(0.08)
        ]
    }

    private static var mathAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.codeFont(),
            .foregroundColor: AppPreferences.shared.textColor,
            .backgroundColor: NSColor.black.withAlphaComponent(0.08)
        ]
    }

    private static var inlineMathAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.codeFont(),
            .backgroundColor: NSColor.black.withAlphaComponent(0.08)
        ]
    }

    private static var footnoteAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.appFont(ofSize: max(RichTextArchive.baseFontSize - 1, 10)),
            .foregroundColor: AppPreferences.shared.textColor.withAlphaComponent(0.76)
        ]
    }

    private static var footnoteReferenceAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.appFont(ofSize: max(RichTextArchive.baseFontSize - 2, 9)),
            .foregroundColor: AppPreferences.shared.textColor.withAlphaComponent(0.8),
            .baselineOffset: 4
        ]
    }

    private static var boldAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.appFont(ofSize: RichTextArchive.baseFontSize, bold: true),
            .foregroundColor: AppPreferences.shared.textColor
        ]
    }

    private static var italicAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: AppPreferences.shared.textColor,
            .obliqueness: RichTextArchive.italicObliqueness
        ]
    }

    private static var boldItalicAttributes: [NSAttributedString.Key: Any] {
        [
            .font: RichTextArchive.appFont(ofSize: RichTextArchive.baseFontSize, bold: true),
            .foregroundColor: AppPreferences.shared.textColor,
            .obliqueness: RichTextArchive.italicObliqueness
        ]
    }

    private static var strikethroughAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: AppPreferences.shared.textColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: AppPreferences.shared.textColor
        ]
    }

    private static var linkAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor(calibratedRed: 0.66, green: 0.84, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }
}
