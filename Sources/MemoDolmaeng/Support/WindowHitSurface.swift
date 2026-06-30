import AppKit
import SwiftUI

struct WindowHitSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> HitSurfaceView {
        HitSurfaceView()
    }

    func updateNSView(_ nsView: HitSurfaceView, context: Context) {}
}

final class HitSurfaceView: NSView {
    private var inactiveDragContext: HitSurfaceDragContext?

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), !isEditorFocused else {
            return nil
        }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        inactiveDragContext = HitSurfaceDragContext(
            startOrigin: window.frame.origin,
            startPoint: window.convertPoint(toScreen: event.locationInWindow),
            didMove: false
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let inactiveDragContext,
              let window
        else {
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
        guard let inactiveDragContext else { return }
        self.inactiveDragContext = nil

        if !inactiveDragContext.didMove {
            focusEditor(at: event.locationInWindow)
        }
    }

    private var isEditorFocused: Bool {
        guard NSApp.isActive,
              window?.isKeyWindow == true,
              let contentView = window?.contentView,
              let textView = findTextView(in: contentView)
        else {
            return false
        }

        return window?.firstResponder === textView
    }

    private func focusEditor(at windowPoint: NSPoint) {
        guard let window,
              let contentView = window.contentView,
              let textView = findTextView(in: contentView)
        else {
            return
        }

        window.makeFirstResponder(textView)
        let textPoint = textView.convert(windowPoint, from: nil)
        let insertionIndex = min(
            textView.characterIndexForInsertion(at: textPoint),
            textView.textStorage?.length ?? 0
        )
        textView.setSelectedRange(NSRange(location: insertionIndex, length: 0))
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
}

private struct HitSurfaceDragContext {
    let startOrigin: NSPoint
    let startPoint: NSPoint
    var didMove: Bool
}
