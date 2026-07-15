import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    init(workspace: EdgeWorkspaceController) {
        let controller = NSHostingController(rootView: LibraryView(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "메모돌맹 보관함"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 430)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
