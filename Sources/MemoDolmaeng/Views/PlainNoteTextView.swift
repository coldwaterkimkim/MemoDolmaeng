import AppKit
import SwiftUI

struct PlainNoteTextView: NSViewRepresentable {
    let initialAttributedText: NSAttributedString
    let onTextChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(initialAttributedText)
        textView.font = RichTextArchive.baseFont
        textView.textColor = AppPreferences.shared.textColor
        textView.insertionPointColor = AppPreferences.shared.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.typingAttributes = RichTextArchive.baseAttributes
        textView.textContainerInset = NSSize(
            width: NoteWindowMetrics.contentHorizontalInset,
            height: NoteWindowMetrics.contentVerticalInset
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.preferencesObserver = NotificationCenter.default.addObserver(
            forName: .memoDolmaengPreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak textView, weak coordinator = context.coordinator] _ in
            guard let textView else { return }
            textView.applyCurrentPreferences()
            coordinator?.save(textView)
            Self.publishMeasuredHeight(for: textView)
        }

        scrollView.documentView = textView

        DispatchQueue.main.async {
            MarkdownLiveStyler.apply(in: textView)
            Self.publishMeasuredHeight(for: textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }

        DispatchQueue.main.async {
            MarkdownLiveStyler.apply(in: textView)
            Self.publishMeasuredHeight(for: textView)
        }
    }

    private static func publishMeasuredHeight(for textView: NSTextView) {
        guard let controller = textView.window?.windowController as? NoteWindowController else { return }
        controller.noteContentHeightDidChange(measuredHeight(for: textView))
    }

    private static func measuredHeight(for textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return 0
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let font = textView.font ?? RichTextArchive.baseFont
        let singleLineHeight = layoutManager.defaultLineHeight(for: font)
        let textHeight = max(usedRect.height, singleLineHeight)

        return ceil(textHeight + (textView.textContainerInset.height * 2))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let onTextChange: (NSAttributedString) -> Void

        init(onTextChange: @escaping (NSAttributedString) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            guard !textView.isApplyingMarkdown else { return }

            save(textView)
            MarkdownLiveStyler.apply(in: textView)
            PlainNoteTextView.publishMeasuredHeight(for: textView)
        }

        func save(_ textView: NSTextView) {
            guard let attributedString = textView.textStorage?.copy() as? NSAttributedString else { return }
            onTextChange(attributedString)
        }
    }
}

final class NoteTextView: NSTextView {
    var isApplyingMarkdown = false
    var preferencesObserver: NSObjectProtocol?
    private var inactiveDragContext: InactiveDragContext?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NoteTextLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditingActive else {
            super.mouseDown(with: event)
            return
        }

        beginInactiveDrag(with: event)
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

        if !inactiveDragContext.didMove {
            focusEditor(at: event.locationInWindow)
        }
    }

    @objc func applyBody(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.body, to: self)
    }

    @objc func applyHeading1(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.heading1, to: self)
    }

    @objc func applyHeading2(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.heading2, to: self)
    }

    @objc func applyHeading3(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.heading3, to: self)
    }

    @objc func applyBulletList(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.bullet, to: self)
    }

    @objc func applyNumberedList(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.numbered, to: self)
    }

    @objc func applyQuote(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.quote, to: self)
    }

    @objc func applyCheckbox(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.checkbox, to: self)
    }

    @objc func applyCodeBlock(_ sender: Any?) {
        MarkdownStyler.applyBlockStyle(.codeBlock, to: self)
    }

    @objc func applyBold(_ sender: Any?) {
        MarkdownStyler.applyInlineStyle(.bold, to: self)
    }

    @objc func applyItalic(_ sender: Any?) {
        MarkdownStyler.applyInlineStyle(.italic, to: self)
    }

    @objc func applyInlineCode(_ sender: Any?) {
        MarkdownStyler.applyInlineStyle(.code, to: self)
    }

    @objc func insertDivider(_ sender: Any?) {
        MarkdownStyler.insertDivider(in: self)
    }

    @objc func addLink(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Enter a URL for the selected text."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: textField.stringValue),
              !textField.stringValue.isEmpty
        else {
            return
        }

        MarkdownStyler.addLink(to: self, url: url)
    }

    @objc func resetFormatting(_ sender: Any?) {
        guard let textStorage else { return }

        let selection = selectedRange()
        let resetRange = selection.length > 0
            ? selection
            : NSRange(location: 0, length: textStorage.length)

        guard resetRange.length > 0 else {
            typingAttributes = RichTextArchive.baseAttributes
            return
        }

        let normalizedText = RichTextArchive.restyledTypography(
            textStorage.attributedSubstring(from: resetRange)
        )
        textStorage.replaceCharacters(in: resetRange, with: normalizedText)
        setSelectedRange(NSRange(location: resetRange.location + normalizedText.length, length: 0))
        MarkdownStyler.updateTypingAttributes(for: self)
        didChangeText()
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        if let image = NSImage(pasteboard: pasteboard) {
            MarkdownStyler.insertImage(image, in: self)
            return
        }

        pastePlainTextFromPasteboard(pasteboard)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pastePlainTextFromPasteboard(.general)
    }

    override func keyDown(with event: NSEvent) {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

        if event.keyCode == 36, !flags.contains(.command) {
            if flags.contains(.shift) {
                super.keyDown(with: event)
            } else if !insertListParagraphBreak() {
                insertBodyParagraphBreak()
            }

            return
        }

        if event.keyCode == KeyboardShortcuts.KeyCode.tab,
           !flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control) {
            if adjustListIndent(outdent: flags.contains(.shift)) {
                return
            }

            if flags.contains(.shift) {
                interpretKeyEvents([event])
            } else {
                super.keyDown(with: event)
            }

            return
        }

        guard flags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        if flags.contains(.option),
           (event.keyCode == KeyboardShortcuts.KeyCode.f || event.keyCode == KeyboardShortcuts.KeyCode.t),
           window?.performKeyEquivalent(with: event) == true {
            return
        }

        if performFormatKeyEquivalent(with: event) {
            return
        }

        if performStandardTextKeyEquivalent(with: event) {
            return
        }

        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }

        super.keyDown(with: event)
    }

    @discardableResult
    func performFormatKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

        switch (flags, event.keyCode) {
        case ([.command, .option], KeyboardShortcuts.KeyCode.zero):
            applyBody(nil)
        case ([.command, .option], KeyboardShortcuts.KeyCode.one):
            applyHeading1(nil)
        case ([.command, .option], KeyboardShortcuts.KeyCode.two):
            applyHeading2(nil)
        case ([.command, .option], KeyboardShortcuts.KeyCode.three):
            applyHeading3(nil)
        case ([.command, .shift], KeyboardShortcuts.KeyCode.eight):
            applyBulletList(nil)
        case ([.command, .shift], KeyboardShortcuts.KeyCode.seven):
            applyNumberedList(nil)
        case ([.command, .option], KeyboardShortcuts.KeyCode.q):
            applyQuote(nil)
        case ([.command, .option], KeyboardShortcuts.KeyCode.c):
            applyCheckbox(nil)
        case ([.command], KeyboardShortcuts.KeyCode.b):
            applyBold(nil)
        case ([.command], KeyboardShortcuts.KeyCode.i):
            applyItalic(nil)
        case ([.command], KeyboardShortcuts.KeyCode.e):
            applyInlineCode(nil)
        case ([.command], KeyboardShortcuts.KeyCode.k):
            addLink(nil)
        default:
            return false
        }

        return true
    }

    private func performStandardTextKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = KeyboardShortcuts.normalizedModifiers(for: event)

        switch (flags, event.keyCode) {
        case ([.command], KeyboardShortcuts.KeyCode.a):
            selectAll(nil)
        case ([.command], KeyboardShortcuts.KeyCode.z):
            undoManager?.undo()
        case ([.command, .shift], KeyboardShortcuts.KeyCode.z):
            undoManager?.redo()
        case ([.command], KeyboardShortcuts.KeyCode.x):
            cut(nil)
        case ([.command], KeyboardShortcuts.KeyCode.c):
            copy(nil)
        case ([.command], KeyboardShortcuts.KeyCode.v):
            paste(nil)
        case ([.command], KeyboardShortcuts.KeyCode.w):
            window?.performClose(nil)
        case ([.command], KeyboardShortcuts.KeyCode.n):
            NotificationCenter.default.post(name: .memoDolmaengCreateNoteRequested, object: self)
        default:
            return false
        }

        return true
    }

    private var isEditingActive: Bool {
        NSApp.isActive
            && window?.isKeyWindow == true
            && window?.firstResponder === self
    }

    private func beginInactiveDrag(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        inactiveDragContext = InactiveDragContext(
            startOrigin: window.frame.origin,
            startPoint: window.convertPoint(toScreen: event.locationInWindow),
            didMove: false
        )
    }

    private func focusEditor(at windowPoint: NSPoint) {
        window?.makeFirstResponder(self)

        let viewPoint = convert(windowPoint, from: nil)
        let insertionIndex = min(characterIndexForInsertion(at: viewPoint), textStorage?.length ?? 0)
        setSelectedRange(NSRange(location: insertionIndex, length: 0))
    }

    private func pastePlainTextFromPasteboard(_ pasteboard: NSPasteboard) {
        guard let pastedText = pasteboard.string(forType: .string),
              !pastedText.isEmpty,
              let textStorage
        else {
            return
        }

        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: pastedText) else {
            return
        }

        let replacement = NSAttributedString(string: pastedText, attributes: RichTextArchive.baseAttributes)
        textStorage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        typingAttributes = RichTextArchive.baseAttributes
        didChangeText()
    }

    private func finalizeBlockShortcutBeforeSpace() -> Bool {
        guard let textStorage else { return false }

        let selection = selectedRange()
        guard selection.length == 0 else { return false }

        let paragraphRange = currentParagraphRange()
        let paragraphPrefixRange = NSRange(
            location: paragraphRange.location,
            length: max(0, selection.location - paragraphRange.location)
        )
        let nsString = textStorage.string as NSString
        guard paragraphPrefixRange.location >= 0,
              NSMaxRange(paragraphPrefixRange) <= nsString.length
        else {
            return false
        }

        let prefix = nsString.substring(with: paragraphPrefixRange)
        guard let shortcut = BlockShortcut(prefix: prefix) else {
            return false
        }

        guard shouldChangeText(in: paragraphPrefixRange, replacementString: shortcut.replacement) else {
            return true
        }

        let replacement = NSAttributedString(
            string: shortcut.replacement,
            attributes: MarkdownStyler.attributes(for: shortcut.style)
        )
        textStorage.replaceCharacters(in: paragraphPrefixRange, with: replacement)

        let nextLocation = paragraphRange.location + replacement.length
        setSelectedRange(NSRange(location: nextLocation, length: 0))
        typingAttributes = MarkdownStyler.attributes(for: shortcut.style)
        didChangeText()
        return true
    }

    private func insertListParagraphBreak() -> Bool {
        guard let textStorage else { return false }

        let selection = selectedRange()
        let paragraphRange = currentParagraphRange()
        guard let paragraph = paragraphText(in: paragraphRange),
              let marker = listMarker(in: paragraph)
        else {
            return false
        }

        if marker.contentIsEmpty(in: paragraph) {
            exitEmptyListItem(marker: marker, paragraphRange: paragraphRange)
            return true
        }

        let paragraphStyle = currentParagraphStyle(at: paragraphRange.location)
        let insertionStyle = listParagraphStyle(from: paragraphStyle, level: listLevel(from: paragraphStyle))
        var attributes = MarkdownStyler.attributes(for: marker.style)
        attributes[.paragraphStyle] = insertionStyle

        let insertedText = "\n\(marker.nextText)"
        guard shouldChangeText(in: selection, replacementString: insertedText) else {
            return true
        }

        let replacement = NSAttributedString(string: insertedText, attributes: attributes)
        textStorage.replaceCharacters(in: selection, with: replacement)
        setSelectedRange(NSRange(location: selection.location + replacement.length, length: 0))
        typingAttributes = attributes
        didChangeText()
        return true
    }

    private func exitEmptyListItem(marker: ListMarker, paragraphRange: NSRange) {
        guard let textStorage else { return }

        let markerRange = NSRange(location: paragraphRange.location, length: marker.length)
        guard shouldChangeText(in: markerRange, replacementString: "") else {
            return
        }

        textStorage.replaceCharacters(in: markerRange, with: "")
        let restyledLength = max(0, min(paragraphRange.length - marker.length, textStorage.length - paragraphRange.location))
        if restyledLength > 0 {
            textStorage.addAttributes(
                RichTextArchive.baseAttributes,
                range: NSRange(location: paragraphRange.location, length: restyledLength)
            )
        }

        setSelectedRange(NSRange(location: paragraphRange.location, length: 0))
        typingAttributes = RichTextArchive.baseAttributes
        didChangeText()
    }

    private func adjustListIndent(outdent: Bool) -> Bool {
        guard let textStorage else { return false }

        let affectedRange = selectedParagraphRange()
        let ranges = paragraphRanges(in: affectedRange).reversed()
        var handledList = false
        var changed = false
        var selection = selectedRange()

        textStorage.beginEditing()
        for range in ranges {
            guard let paragraph = paragraphText(in: range),
                  listMarker(in: paragraph) != nil,
                  range.location < textStorage.length
            else {
                continue
            }

            handledList = true

            if outdent {
                let removeLength = leadingMarkdownIndentLength(in: paragraph)
                guard removeLength > 0 else { continue }

                let removeRange = NSRange(location: range.location, length: removeLength)
                guard shouldChangeText(in: removeRange, replacementString: "") else { continue }
                textStorage.replaceCharacters(in: removeRange, with: "")
                if range.location < selection.location {
                    selection.location = max(0, selection.location - removeLength)
                }
                changed = true
            } else {
                guard shouldChangeText(in: NSRange(location: range.location, length: 0), replacementString: "  ") else {
                    continue
                }
                textStorage.replaceCharacters(
                    in: NSRange(location: range.location, length: 0),
                    with: NSAttributedString(string: "  ", attributes: RichTextArchive.baseAttributes)
                )
                if range.location <= selection.location {
                    selection.location += 2
                }
                changed = true
            }
        }
        textStorage.endEditing()

        guard handledList else {
            return false
        }

        MarkdownStyler.updateTypingAttributes(for: self)

        if changed {
            setSelectedRange(NSRange(location: min(selection.location, textStorage.length), length: selection.length))
            didChangeText()
        }

        return true
    }

    private func leadingMarkdownIndentLength(in paragraph: String) -> Int {
        if paragraph.hasPrefix("\t") {
            return 1
        }

        return min(2, paragraph.prefix { $0 == " " }.count)
    }

    private func currentParagraphRange() -> NSRange {
        let nsString = (textStorage?.string ?? "") as NSString
        let length = nsString.length
        let location = min(selectedRange().location, length)
        return nsString.paragraphRange(
            for: NSRange(location: location, length: 0)
        )
    }

    private func selectedParagraphRange() -> NSRange {
        let nsString = (textStorage?.string ?? "") as NSString

        let selection = selectedRange()
        let safeLocation = min(selection.location, nsString.length)
        let safeLength = min(selection.length, nsString.length - safeLocation)
        return nsString.paragraphRange(for: NSRange(location: safeLocation, length: safeLength))
    }

    private func paragraphRanges(in range: NSRange) -> [NSRange] {
        let nsString = (textStorage?.string ?? "") as NSString

        var ranges: [NSRange] = []
        var location = min(range.location, nsString.length)
        let upperBound = min(NSMaxRange(range), nsString.length)

        repeat {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraphRange)

            let nextLocation = NSMaxRange(paragraphRange)
            guard nextLocation > location else { break }
            location = nextLocation
        } while location < upperBound

        return ranges
    }

    private func paragraphText(in range: NSRange) -> String? {
        let nsString = (textStorage?.string ?? "") as NSString
        guard range.location <= nsString.length
        else {
            return nil
        }

        let safeRange = NSRange(
            location: range.location,
            length: min(range.length, nsString.length - range.location)
        )
        return nsString.substring(with: safeRange).trimmingCharacters(in: .newlines)
    }

    private func currentParagraphStyle(at location: Int) -> NSParagraphStyle {
        guard let textStorage, textStorage.length > 0 else {
            return RichTextArchive.bodyParagraphStyle()
        }

        let safeLocation = min(max(location, 0), textStorage.length - 1)
        return textStorage.attribute(.paragraphStyle, at: safeLocation, effectiveRange: nil) as? NSParagraphStyle
            ?? RichTextArchive.bodyParagraphStyle()
    }

    private func listLevel(from paragraphStyle: NSParagraphStyle) -> Int {
        let indent = max(AppPreferences.shared.listIndent, 1)
        return max(0, Int(round(paragraphStyle.firstLineHeadIndent / indent)))
    }

    private func listParagraphStyle(from baseStyle: NSParagraphStyle, level: Int) -> NSParagraphStyle {
        let indent = max(AppPreferences.shared.listIndent, 1)
        let nextStyle = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        nextStyle.lineSpacing = 0
        nextStyle.paragraphSpacing = AppPreferences.shared.paragraphSpacing
        nextStyle.firstLineHeadIndent = CGFloat(level) * indent
        nextStyle.headIndent = CGFloat(level + 1) * indent
        return nextStyle
    }

    private func listMarker(in paragraph: String) -> ListMarker? {
        let leadingWhitespace = String(paragraph.prefix { $0 == " " || $0 == "\t" })
        if !leadingWhitespace.isEmpty {
            let contentStart = paragraph.index(paragraph.startIndex, offsetBy: leadingWhitespace.count)
            let content = String(paragraph[contentStart...])

            if let marker = listMarker(in: content) {
                return ListMarker(
                    length: (leadingWhitespace as NSString).length + marker.length,
                    style: marker.style,
                    nextText: leadingWhitespace + marker.nextText
                )
            }
        }

        if paragraph.hasPrefix("- ") {
            return ListMarker(length: 2, style: .bullet, nextText: "- ")
        }

        if paragraph.hasPrefix("* ") {
            return ListMarker(length: 2, style: .bullet, nextText: "* ")
        }

        if paragraph.hasPrefix("+ ") {
            return ListMarker(length: 2, style: .bullet, nextText: "+ ")
        }

        if paragraph.hasPrefix("- [ ] ") {
            return ListMarker(length: 6, style: .checkbox, nextText: "- [ ] ")
        }

        if paragraph.hasPrefix("- [x] ") || paragraph.hasPrefix("- [X] ") {
            return ListMarker(length: 6, style: .checkedCheckbox, nextText: "- [ ] ")
        }

        if paragraph.hasPrefix("• ") {
            return ListMarker(length: 2, style: .bullet, nextText: "• ")
        }

        if paragraph.hasPrefix("☐ ") {
            return ListMarker(length: 2, style: .checkbox, nextText: "☐ ")
        }

        if paragraph.hasPrefix("☑ ") {
            return ListMarker(length: 2, style: .checkedCheckbox, nextText: "☐ ")
        }

        if let match = paragraph.range(of: #"^\d+\. "#, options: .regularExpression) {
            let marker = String(paragraph[match])
            let number = Int(marker.dropLast(2)) ?? 1
            return ListMarker(length: marker.count, style: .numbered, nextText: "\(number + 1). ")
        }

        return nil
    }

    private func insertBodyParagraphBreak() {
        let range = selectedRange()

        guard shouldChangeText(in: range, replacementString: "\n") else {
            return
        }

        textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: "\n", attributes: RichTextArchive.baseAttributes)
        )
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
        typingAttributes = RichTextArchive.baseAttributes
        didChangeText()
    }

    func applyCurrentPreferences() {
        guard let textStorage else {
            return
        }

        isApplyingMarkdown = true
        let selection = selectedRange()
        let restyledText = RichTextArchive.restyledTypography(textStorage)
        textStorage.setAttributedString(restyledText)
        textColor = AppPreferences.shared.textColor
        insertionPointColor = AppPreferences.shared.textColor
        font = RichTextArchive.baseFont
        textContainerInset = NSSize(
            width: NoteWindowMetrics.contentHorizontalInset,
            height: NoteWindowMetrics.contentVerticalInset
        )
        typingAttributes = RichTextArchive.baseAttributes
        setSelectedRange(NSRange(location: min(selection.location, textStorage.length), length: min(selection.length, max(0, textStorage.length - min(selection.location, textStorage.length)))))
        MarkdownLiveStyler.apply(in: self)
        isApplyingMarkdown = false
    }
}

private struct InactiveDragContext {
    let startOrigin: NSPoint
    let startPoint: NSPoint
    var didMove: Bool
}

private struct BlockShortcut {
    let style: MarkdownBlockStyle
    let replacement: String

    init?(prefix: String) {
        switch prefix {
        case "#":
            style = .heading1
            replacement = ""
        case "##":
            style = .heading2
            replacement = ""
        case "###":
            style = .heading3
            replacement = ""
        case "-", "*", "+":
            style = .bullet
            replacement = "• "
        case ">":
            style = .quote
            replacement = ""
        case "- [ ]", "* [ ]", "+ [ ]":
            style = .checkbox
            replacement = "☐ "
        case "- [x]", "- [X]", "* [x]", "* [X]", "+ [x]", "+ [X]":
            style = .checkedCheckbox
            replacement = "☑ "
        default:
            if prefix.range(of: #"^\d+\.$"#, options: .regularExpression) != nil {
                style = .numbered
                replacement = "\(prefix) "
            } else {
                return nil
            }
        }
    }
}

private struct ListMarker {
    let length: Int
    let style: MarkdownBlockStyle
    let nextText: String

    func contentIsEmpty(in paragraph: String) -> Bool {
        let contentStart = paragraph.index(paragraph.startIndex, offsetBy: min(length, paragraph.count))
        return paragraph[contentStart...].trimmingCharacters(in: .whitespaces).isEmpty
    }
}

final class NoteTextLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        guard AppPreferences.shared.strokeWidth > 0,
              let textStorage,
              glyphsToShow.length > 0
        else {
            return
        }

        let characterRange = self.characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: nil
        )
        guard characterRange.length > 0 else { return }

        addTemporaryAttributes([.strokeWidth: 0], forCharacterRange: characterRange)
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        removeTemporaryAttribute(.strokeWidth, forCharacterRange: characterRange)
        textStorage.invalidateAttributes(in: characterRange)
    }
}
