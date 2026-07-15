import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    init(
        workspace: EdgeWorkspaceController,
        edgePreferences: EdgePreferences,
        editorPreferences: AppPreferences
    ) {
        let rootView = PreferencesView(
            workspace: workspace,
            edgePreferences: edgePreferences,
            editorPreferences: editorPreferences
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "메모돌맹 설정"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
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
