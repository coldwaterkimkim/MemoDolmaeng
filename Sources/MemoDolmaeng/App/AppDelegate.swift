import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = NoteStore()
    private lazy var windowManager = WindowManager(store: store)
    private lazy var preferencesWindowController = PreferencesWindowController(preferences: AppPreferences.shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(createNoteFromNotification(_:)),
            name: .memoDolmaengCreateNoteRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange(_:)),
            name: .memoDolmaengPreferencesChanged,
            object: nil
        )
        windowManager.openInitialWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowManager.prepareForTermination()
        return .terminateNow
    }

    @objc private func newNote(_ sender: Any?) {
        windowManager.createNote()
    }

    @objc private func createNoteFromNotification(_ notification: Notification) {
        windowManager.createNote()
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        windowManager.applyPreferencesToOpenWindows()
    }

    @objc private func showPreferences(_ sender: Any?) {
        preferencesWindowController.show()
    }

    @objc private func bringAllNotesToFront(_ sender: Any?) {
        windowManager.bringVisibleNotesToFront()
    }

    @objc private func showAllNotes(_ sender: Any?) {
        windowManager.showAllNotes()
    }

    @objc private func closeCurrentNote(_ sender: Any?) {
        windowManager.closeCurrentNote()
    }

    @objc private func closeAllNotes(_ sender: Any?) {
        windowManager.closeAllNotes()
    }

    @objc private func setNoteColor(_ sender: NSMenuItem) {
        guard let color = NoteColor(rawValue: sender.representedObject as? String ?? "") else { return }
        windowManager.setCurrentNoteColor(color)
    }

    @objc private func toggleFloatOnTop(_ sender: Any?) {
        windowManager.toggleCurrentNoteFloatOnTop()
    }

    @objc private func toggleTranslucent(_ sender: Any?) {
        windowManager.toggleCurrentNoteTranslucent()
    }

    @objc private func applyBody(_ sender: Any?) {
        if performMarkdownEditorCommand("body") { return }
        currentNoteTextView()?.applyBody(sender)
    }

    @objc private func applyHeading1(_ sender: Any?) {
        if performMarkdownEditorCommand("heading1") { return }
        currentNoteTextView()?.applyHeading1(sender)
    }

    @objc private func applyHeading2(_ sender: Any?) {
        if performMarkdownEditorCommand("heading2") { return }
        currentNoteTextView()?.applyHeading2(sender)
    }

    @objc private func applyHeading3(_ sender: Any?) {
        if performMarkdownEditorCommand("heading3") { return }
        currentNoteTextView()?.applyHeading3(sender)
    }

    @objc private func applyBulletList(_ sender: Any?) {
        if performMarkdownEditorCommand("bullet") { return }
        currentNoteTextView()?.applyBulletList(sender)
    }

    @objc private func applyNumberedList(_ sender: Any?) {
        if performMarkdownEditorCommand("numbered") { return }
        currentNoteTextView()?.applyNumberedList(sender)
    }

    @objc private func applyQuote(_ sender: Any?) {
        if performMarkdownEditorCommand("quote") { return }
        currentNoteTextView()?.applyQuote(sender)
    }

    @objc private func applyCheckbox(_ sender: Any?) {
        if performMarkdownEditorCommand("checkbox") { return }
        currentNoteTextView()?.applyCheckbox(sender)
    }

    @objc private func applyCodeBlock(_ sender: Any?) {
        if performMarkdownEditorCommand("codeBlock") { return }
        currentNoteTextView()?.applyCodeBlock(sender)
    }

    @objc private func applyBold(_ sender: Any?) {
        if performMarkdownEditorCommand("bold") { return }
        currentNoteTextView()?.applyBold(sender)
    }

    @objc private func applyItalic(_ sender: Any?) {
        if performMarkdownEditorCommand("italic") { return }
        currentNoteTextView()?.applyItalic(sender)
    }

    @objc private func applyInlineCode(_ sender: Any?) {
        if performMarkdownEditorCommand("inlineCode") { return }
        currentNoteTextView()?.applyInlineCode(sender)
    }

    @objc private func insertDivider(_ sender: Any?) {
        if performMarkdownEditorCommand("divider") { return }
        currentNoteTextView()?.insertDivider(sender)
    }

    @objc private func addLink(_ sender: Any?) {
        if performMarkdownEditorCommand("link") { return }
        currentNoteTextView()?.addLink(sender)
    }

    @objc private func resetFormatting(_ sender: Any?) {
        if performMarkdownEditorCommand("reset") { return }
        currentNoteTextView()?.resetFormatting(sender)
    }

    @objc private func increaseFontSize(_ sender: Any?) {
        adjustCurrentTextViewFontSize(by: 1)
    }

    @objc private func decreaseFontSize(_ sender: Any?) {
        adjustCurrentTextViewFontSize(by: -1)
    }

    private func adjustCurrentTextViewFontSize(by delta: CGFloat) {
        guard let textView = currentTextView() else { return }
        let currentFont = textView.font ?? RichTextArchive.baseFont
        let nextSize = max(8, min(32, currentFont.pointSize + delta))
        textView.font = NSFontManager.shared.convert(currentFont, toSize: nextSize)
    }

    private func currentTextView() -> NSTextView? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.orderedWindows

        for window in candidateWindows {
            if let contentView = window.contentView,
               let textView = findTextView(in: contentView) {
                return textView
            }
        }

        return nil
    }

    private func performMarkdownEditorCommand(_ command: String) -> Bool {
        guard let webView = currentMarkdownWebView() else { return false }
        webView.evaluateJavaScript(
            "window.memoEditorCommand && window.memoEditorCommand(\(javascriptStringLiteral(command)));"
        )
        return true
    }

    private func currentMarkdownWebView() -> WKWebView? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.orderedWindows

        for window in candidateWindows {
            if let contentView = window.contentView,
               let webView = findWebView(in: contentView) {
                return webView
            }
        }

        return nil
    }

    private func currentNoteTextView() -> NoteTextView? {
        currentTextView() as? NoteTextView
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }

        for subview in view.subviews {
            if let webView = findWebView(in: subview) {
                return webView
            }
        }

        return nil
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }

        return encoded
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFloatOnTop(_:)):
            menuItem.state = windowManager.currentNoteFloatsOnTop() ? .on : .off
            return true
        case #selector(toggleTranslucent(_:)):
            menuItem.state = windowManager.currentNoteIsTranslucent() ? .on : .off
            return true
        case #selector(setNoteColor(_:)):
            guard let rawValue = menuItem.representedObject as? String,
                  let itemColor = NoteColor(rawValue: rawValue)
            else {
                return false
            }
            menuItem.state = windowManager.currentNoteColor() == itemColor ? .on : .off
            return true
        default:
            return true
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "MemoDolmaeng")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MemoDolmaeng", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide MemoDolmaeng", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MemoDolmaeng", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let newNoteItem = NSMenuItem(title: "New Note", action: #selector(newNote(_:)), keyEquivalent: "n")
        newNoteItem.target = self
        fileMenu.addItem(newNoteItem)

        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = nil
        fileMenu.addItem(closeItem)

        let closeAllItem = NSMenuItem(title: "Close All", action: #selector(closeAllNotes(_:)), keyEquivalent: "w")
        closeAllItem.target = self
        closeAllItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(closeAllItem)
        fileMenu.addItem(NSMenuItem.separator())

        let showAllItem = NSMenuItem(title: "Show All Notes", action: #selector(showAllNotes(_:)), keyEquivalent: "")
        showAllItem.target = self
        fileMenu.addItem(showAllItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z"))

        let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pasteMatchItem = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatchItem.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pasteMatchItem)
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)

        let formatMenu = NSMenu(title: "Format")
        formatMenuItem.submenu = formatMenu

        let bodyItem = NSMenuItem(title: "Body", action: #selector(applyBody(_:)), keyEquivalent: "0")
        bodyItem.target = self
        bodyItem.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(bodyItem)

        let heading1Item = NSMenuItem(title: "Heading 1", action: #selector(applyHeading1(_:)), keyEquivalent: "1")
        heading1Item.target = self
        heading1Item.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(heading1Item)

        let heading2Item = NSMenuItem(title: "Heading 2", action: #selector(applyHeading2(_:)), keyEquivalent: "2")
        heading2Item.target = self
        heading2Item.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(heading2Item)

        let heading3Item = NSMenuItem(title: "Heading 3", action: #selector(applyHeading3(_:)), keyEquivalent: "3")
        heading3Item.target = self
        heading3Item.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(heading3Item)
        formatMenu.addItem(NSMenuItem.separator())

        let bulletItem = NSMenuItem(title: "Bulleted List", action: #selector(applyBulletList(_:)), keyEquivalent: "8")
        bulletItem.target = self
        bulletItem.keyEquivalentModifierMask = [.command, .shift]
        formatMenu.addItem(bulletItem)

        let numberedItem = NSMenuItem(title: "Numbered List", action: #selector(applyNumberedList(_:)), keyEquivalent: "7")
        numberedItem.target = self
        numberedItem.keyEquivalentModifierMask = [.command, .shift]
        formatMenu.addItem(numberedItem)

        let quoteItem = NSMenuItem(title: "Quote", action: #selector(applyQuote(_:)), keyEquivalent: "q")
        quoteItem.target = self
        quoteItem.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(quoteItem)

        let checkboxItem = NSMenuItem(title: "Checkbox", action: #selector(applyCheckbox(_:)), keyEquivalent: "c")
        checkboxItem.target = self
        checkboxItem.keyEquivalentModifierMask = [.command, .option]
        formatMenu.addItem(checkboxItem)

        let codeBlockItem = NSMenuItem(title: "Code Block", action: #selector(applyCodeBlock(_:)), keyEquivalent: "")
        codeBlockItem.target = self
        formatMenu.addItem(codeBlockItem)

        let dividerItem = NSMenuItem(title: "Divider", action: #selector(insertDivider(_:)), keyEquivalent: "")
        dividerItem.target = self
        formatMenu.addItem(dividerItem)
        formatMenu.addItem(NSMenuItem.separator())

        let boldFormatItem = NSMenuItem(title: "Bold", action: #selector(applyBold(_:)), keyEquivalent: "b")
        boldFormatItem.target = self
        formatMenu.addItem(boldFormatItem)

        let italicFormatItem = NSMenuItem(title: "Italic", action: #selector(applyItalic(_:)), keyEquivalent: "i")
        italicFormatItem.target = self
        formatMenu.addItem(italicFormatItem)

        let inlineCodeItem = NSMenuItem(title: "Inline Code", action: #selector(applyInlineCode(_:)), keyEquivalent: "e")
        inlineCodeItem.target = self
        inlineCodeItem.keyEquivalentModifierMask = [.command]
        formatMenu.addItem(inlineCodeItem)

        let addLinkItem = NSMenuItem(title: "Add Link...", action: #selector(addLink(_:)), keyEquivalent: "k")
        addLinkItem.target = self
        formatMenu.addItem(addLinkItem)
        formatMenu.addItem(NSMenuItem.separator())

        let resetFormattingItem = NSMenuItem(title: "Reset Formatting", action: #selector(resetFormatting(_:)), keyEquivalent: "")
        resetFormattingItem.target = self
        formatMenu.addItem(resetFormattingItem)

        let fontMenuItem = NSMenuItem()
        mainMenu.addItem(fontMenuItem)

        let fontMenu = NSMenu(title: "Font")
        fontMenuItem.submenu = fontMenu
        fontMenu.addItem(NSMenuItem(title: "Show Fonts", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "t"))
        fontMenu.addItem(NSMenuItem.separator())
        let boldItem = NSMenuItem(title: "Bold", action: #selector(applyBold(_:)), keyEquivalent: "b")
        boldItem.target = self
        fontMenu.addItem(boldItem)
        let italicItem = NSMenuItem(title: "Italic", action: #selector(applyItalic(_:)), keyEquivalent: "i")
        italicItem.target = self
        fontMenu.addItem(italicItem)
        let underlineItem = NSMenuItem(title: "Underline", action: nil, keyEquivalent: "u")
        underlineItem.isEnabled = false
        fontMenu.addItem(underlineItem)
        fontMenu.addItem(NSMenuItem.separator())
        let biggerItem = NSMenuItem(title: "Bigger", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        biggerItem.target = self
        fontMenu.addItem(biggerItem)
        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        smallerItem.target = self
        fontMenu.addItem(smallerItem)
        fontMenu.addItem(NSMenuItem.separator())
        let showColorsItem = NSMenuItem(title: "Show Colors", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "c")
        showColorsItem.keyEquivalentModifierMask = [.command, .shift]
        fontMenu.addItem(showColorsItem)

        let colorMenuItem = NSMenuItem()
        mainMenu.addItem(colorMenuItem)

        let colorMenu = NSMenu(title: "Color")
        colorMenuItem.submenu = colorMenu

        for color in NoteColor.allCases {
            let colorItem = NSMenuItem(title: color.title, action: #selector(setNoteColor(_:)), keyEquivalent: "")
            colorItem.target = self
            colorItem.representedObject = color.rawValue
            colorMenu.addItem(colorItem)
        }

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Collapse", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        let collapseAllItem = NSMenuItem(title: "Collapse All", action: #selector(NSApplication.miniaturizeAll(_:)), keyEquivalent: "m")
        collapseAllItem.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(collapseAllItem)
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())

        let floatItem = NSMenuItem(title: "Float on Top", action: #selector(toggleFloatOnTop(_:)), keyEquivalent: "f")
        floatItem.target = self
        floatItem.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(floatItem)

        let translucentItem = NSMenuItem(title: "Translucent", action: #selector(toggleTranslucent(_:)), keyEquivalent: "t")
        translucentItem.target = self
        translucentItem.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(translucentItem)

        let useDefaultItem = NSMenuItem(title: "Use as Default", action: nil, keyEquivalent: "")
        useDefaultItem.isEnabled = false
        windowMenu.addItem(useDefaultItem)

        windowMenu.addItem(NSMenuItem.separator())
        let bringAllItem = NSMenuItem(title: "Bring All to Front", action: #selector(bringAllNotesToFront(_:)), keyEquivalent: "s")
        bringAllItem.target = self
        bringAllItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(bringAllItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
