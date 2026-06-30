import AppKit

enum RichTextArchive {
    static let italicObliqueness: CGFloat = 0.18
    private static let memoRegularFontName = "D2CodingLigatureNF"
    private static let memoBoldFontName = "D2CodingLigatureNF-Bold"
    private static let memoCodeFontName = "D2CodingLigatureNFM"
    private static let fallbackRegularFontName = "AppleSDGothicNeo-Regular"
    private static let fallbackBoldFontName = "AppleSDGothicNeo-Bold"

    static var baseFontSize: CGFloat { AppPreferences.shared.bodyFontSize }
    static var heading1FontSize: CGFloat { AppPreferences.shared.heading1FontSize }
    static var heading2FontSize: CGFloat { AppPreferences.shared.heading2FontSize }
    static var heading3FontSize: CGFloat { AppPreferences.shared.heading3FontSize }
    static var codeFontSize: CGFloat { AppPreferences.shared.codeFontSize }

    static var baseFont: NSFont {
        appFont(ofSize: baseFontSize)
    }

    static func appFont(ofSize size: CGFloat, bold: Bool = false) -> NSFont {
        let primaryName = bold ? memoBoldFontName : memoRegularFontName
        let fallbackName = bold ? fallbackBoldFontName : fallbackRegularFontName

        if let font = cascadedFont(primaryName: primaryName, fallbackName: fallbackName, size: size) {
            return font
        }

        return fallbackFont(ofSize: size, bold: bold)
    }

    static func codeFont(ofSize size: CGFloat = codeFontSize) -> NSFont {
        if let font = cascadedFont(primaryName: memoCodeFontName, fallbackName: fallbackRegularFontName, size: size) {
            return font
        }

        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        textStyleAttributes(merging: [
            .font: baseFont,
            .paragraphStyle: bodyParagraphStyle()
        ])
    }

    static func attributedString(plainText: String, richTextData: Data?) -> NSAttributedString {
        if let richTextData,
           let archived = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: richTextData
           ) {
            return migratedTypographyIfNeeded(archived)
        }

        return NSAttributedString(string: plainText, attributes: baseAttributes)
    }

    static func data(from attributedString: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: attributedString, requiringSecureCoding: false)
    }

    static func bodyParagraphStyle() -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = AppPreferences.shared.paragraphSpacing
        return paragraphStyle
    }

    static func restyledTypography(_ attributedString: NSAttributedString) -> NSAttributedString {
        let migrated = NSMutableAttributedString(attributedString: attributedString)
        migrated.enumerateAttributes(in: NSRange(location: 0, length: migrated.length), options: []) { attributes, range, _ in
            migrated.setAttributes(migratedAttributes(from: attributes), range: range)
        }

        return migrated
    }

    private static func migratedTypographyIfNeeded(_ attributedString: NSAttributedString) -> NSAttributedString {
        guard needsTypographyMigration(attributedString) else {
            return attributedString
        }

        return restyledTypography(attributedString)
    }

    private static func needsTypographyMigration(_ attributedString: NSAttributedString) -> Bool {
        var needsMigration = false

        attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length), options: []) { attributes, _, stop in
            guard let font = attributes[.font] as? NSFont else { return }
            let isCode = isCodeAttributes(attributes)
            let isCurrentBodyFont = isCurrentMemoFont(font)
                && isKnownCurrentAppFontSize(font.pointSize)
            let isCurrentCodeFont = isCode && approximatelyEqual(font.pointSize, codeFontSize)
            let hasCurrentTextStyle = textStyleMatches(attributes)

            if (!isCode && !isCurrentBodyFont) || (isCode && !isCurrentCodeFont) || !hasCurrentTextStyle {
                needsMigration = true
                stop.pointee = true
            }
        }

        return needsMigration
    }

    private static func migratedAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var nextAttributes = attributes
        let currentFont = attributes[.font] as? NSFont ?? baseFont
        let traits = NSFontManager.shared.traits(of: currentFont)
        let isCode = isCodeAttributes(attributes)
        let isBold = traits.contains(.boldFontMask) || currentFont.fontName.localizedCaseInsensitiveContains("bold")
        let isItalic = traits.contains(.italicFontMask) || attributes[.obliqueness] != nil
        let pointSize = currentFont.pointSize

        if isCode {
            nextAttributes[.font] = codeFont()
            nextAttributes[.backgroundColor] = NSColor.black.withAlphaComponent(0.08)
        } else if isBold && isHeading1Size(pointSize) {
            nextAttributes[.font] = appFont(ofSize: heading1FontSize, bold: true)
        } else if isBold && isHeading2Size(pointSize) {
            nextAttributes[.font] = appFont(ofSize: heading2FontSize, bold: true)
        } else if isBold && isHeading3Size(pointSize) {
            nextAttributes[.font] = appFont(ofSize: heading3FontSize, bold: true)
        } else {
            nextAttributes[.font] = appFont(ofSize: baseFontSize, bold: isBold)
        }

        if isItalic && !isCode {
            nextAttributes[.obliqueness] = italicObliqueness
        } else {
            nextAttributes.removeValue(forKey: .obliqueness)
        }

        nextAttributes[.paragraphStyle] = migratedParagraphStyle(from: attributes[.paragraphStyle] as? NSParagraphStyle)
        return textStyleAttributes(merging: nextAttributes)
    }

    private static func migratedParagraphStyle(from paragraphStyle: NSParagraphStyle?) -> NSParagraphStyle {
        let previousHeadIndent = paragraphStyle?.headIndent ?? 0
        let previousFirstLineHeadIndent = paragraphStyle?.firstLineHeadIndent ?? 0
        let previousParagraphSpacing = paragraphStyle?.paragraphSpacing ?? 2
        let nextParagraphStyle = NSMutableParagraphStyle()
        let listIndent = max(AppPreferences.shared.listIndent, 1)

        nextParagraphStyle.lineSpacing = 0
        nextParagraphStyle.paragraphSpacing = min(max(previousParagraphSpacing * 0.75, AppPreferences.shared.paragraphSpacing), AppPreferences.shared.heading1Spacing)

        if previousHeadIndent >= listIndent {
            let level = max(0, Int(round(previousFirstLineHeadIndent / listIndent)))
            nextParagraphStyle.firstLineHeadIndent = CGFloat(level) * listIndent
            nextParagraphStyle.headIndent = CGFloat(level + 1) * listIndent
        } else if previousHeadIndent >= 9 {
            nextParagraphStyle.headIndent = AppPreferences.shared.quoteIndent
            nextParagraphStyle.firstLineHeadIndent = AppPreferences.shared.quoteIndent
        }

        return nextParagraphStyle
    }

    private static func isKnownCurrentAppFontSize(_ size: CGFloat) -> Bool {
        [
            baseFontSize,
            heading1FontSize,
            heading2FontSize,
            heading3FontSize
        ].contains { approximatelyEqual(size, $0) }
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.1
    }

    private static func cascadedFont(primaryName: String, fallbackName: String, size: CGFloat) -> NSFont? {
        let primary = NSFontDescriptor(name: primaryName, size: size)
        let fallback = NSFontDescriptor(name: fallbackName, size: size)
        let descriptor = primary.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size)
    }

    private static func fallbackFont(ofSize size: CGFloat, bold: Bool) -> NSFont {
        let fontName = bold ? fallbackBoldFontName : fallbackRegularFontName

        if let font = NSFont(name: fontName, size: size) {
            return font
        }

        return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    private static func isCurrentMemoFont(_ font: NSFont) -> Bool {
        let familyName = font.familyName ?? ""
        return familyName == "D2CodingLigature Nerd Font"
            || familyName == "D2CodingLigature Nerd Font Mono"
            || font.fontName.hasPrefix("D2CodingLigatureNF")
            || font.fontName.hasPrefix("D2CodingLigatureNFM")
    }

    private static func isCodeAttributes(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        attributes[.backgroundColor] != nil
    }

    static func textStyleAttributes(
        merging attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var nextAttributes = attributes
        let preferences = AppPreferences.shared
        nextAttributes[.foregroundColor] = preferences.textColor
        nextAttributes[.strokeColor] = preferences.strokeColor

        if preferences.strokeWidth > 0 {
            nextAttributes[.strokeWidth] = -preferences.strokeWidth
        } else {
            nextAttributes.removeValue(forKey: .strokeWidth)
            nextAttributes.removeValue(forKey: .strokeColor)
        }

        return nextAttributes
    }

    private static func textStyleMatches(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        let preferences = AppPreferences.shared
        let foregroundColor = attributes[.foregroundColor] as? NSColor
        let strokeColor = attributes[.strokeColor] as? NSColor
        let strokeWidth = attributes[.strokeWidth] as? NSNumber
        let strokeMatches: Bool

        if preferences.strokeWidth <= 0 {
            strokeMatches = strokeWidth == nil
        } else {
            strokeMatches = color(strokeColor, approximatelyEquals: preferences.strokeColor)
                && approximatelyEqual(CGFloat(truncating: strokeWidth ?? 0), -preferences.strokeWidth)
        }

        return color(foregroundColor, approximatelyEquals: preferences.textColor)
            && strokeMatches
    }

    private static func color(_ lhs: NSColor?, approximatelyEquals rhs: NSColor) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs.usingColorSpace(.sRGB)
        else {
            return false
        }

        return approximatelyEqual(lhs.redComponent, rhs.redComponent)
            && approximatelyEqual(lhs.greenComponent, rhs.greenComponent)
            && approximatelyEqual(lhs.blueComponent, rhs.blueComponent)
            && approximatelyEqual(lhs.alphaComponent, rhs.alphaComponent)
    }

    private static func isHeading1Size(_ size: CGFloat) -> Bool {
        approximatelyEqual(size, heading1FontSize)
            || approximatelyEqual(size, 24)
            || approximatelyEqual(size, 19)
            || approximatelyEqual(size, 13)
            || size >= 22
    }

    private static func isHeading2Size(_ size: CGFloat) -> Bool {
        approximatelyEqual(size, heading2FontSize)
            || approximatelyEqual(size, 20)
            || approximatelyEqual(size, 16.5)
            || approximatelyEqual(size, 11)
            || (size >= 15.5 && size < 22)
    }

    private static func isHeading3Size(_ size: CGFloat) -> Bool {
        approximatelyEqual(size, heading3FontSize)
            || approximatelyEqual(size, 17)
            || approximatelyEqual(size, 14)
            || approximatelyEqual(size, 9.5)
            || (size >= 13.5 && size < 15.5)
    }
}
