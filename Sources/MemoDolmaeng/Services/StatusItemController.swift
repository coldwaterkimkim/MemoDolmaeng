import AppKit

@MainActor
final class StatusItemController: NSObject {
    var onCreateNote: (() -> Void)?
    var onToggleRecent: (() -> Void)?
    var onShowSettings: (() -> Void)?

    private let statusItem: NSStatusItem
    private let recentItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        recentItem = NSMenuItem(title: "최근 메모 열기", action: #selector(toggleRecent), keyEquivalent: "")
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "메모돌맹")
        statusItem.button?.toolTip = "메모돌맹"

        let menu = NSMenu(title: "메모돌맹")
        let newItem = NSMenuItem(title: "새 메모", action: #selector(createNote), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        recentItem.target = self
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "설정", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "메모돌맹 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func setPanelOpen(_ isOpen: Bool) {
        recentItem.title = isOpen ? "현재 메모 접기" : "최근 메모 열기"
    }

    @objc private func createNote() {
        onCreateNote?()
    }

    @objc private func toggleRecent() {
        onToggleRecent?()
    }

    @objc private func showSettings() {
        onShowSettings?()
    }
}
