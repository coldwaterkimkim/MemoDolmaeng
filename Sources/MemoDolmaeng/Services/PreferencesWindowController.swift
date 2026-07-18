import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let hostingController: NSHostingController<PreferencesView>

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
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 540, height: 430)
        hostingController.view.autoresizingMask = [.width, .height]
        self.hostingController = hostingController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "메모돌맹 설정"
        window.contentView = hostingController.view
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        let motion = EdgeMotionPolicy.current
        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible { window.center() }
        window.alphaValue = wasVisible || motion.reduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        guard !wasVisible, !motion.reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeDuration(0.14)
            context.timingFunction = motion.timingFunction(.easeOut)
            window.animator().alphaValue = 1
        }
    }
}
