import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private let hostingController: NSHostingController<LibraryView>

    init(workspace: EdgeWorkspaceController) {
        let controller = NSHostingController(rootView: LibraryView(workspace: workspace))
        controller.view.frame = NSRect(x: 0, y: 0, width: 780, height: 500)
        controller.view.autoresizingMask = [.width, .height]
        hostingController = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "메모돌맹 보관함"
        window.contentView = controller.view
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 430)
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
