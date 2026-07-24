import AppKit
import Foundation
import SwiftUI

enum EdgeMemoPanelLayoutPolicy {
    static let minimumExpandedBodySize = CGSize(
        width: 180,
        height: EdgeLayoutEngine.titleBarHeight + 1 + 36 + 1
    )

    static func showsExpandedBody(in size: CGSize) -> Bool {
        size.width >= minimumExpandedBodySize.width
            && size.height >= minimumExpandedBodySize.height
    }

    static func bodyRevealProgress(expansionProgress: CGFloat) -> Double {
        Double(min(1, max(0, (expansionProgress - 0.42) / 0.58)))
    }
}

struct UnifiedEdgeMemoSurfaceView: View {
    @ObservedObject var viewModel: NoteEditorViewModel

    let isBodyMounted: Bool
    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL

    var body: some View {
        GeometryReader { proxy in
            let expansionProgress = min(
                1,
                max(0, (proxy.size.height - EdgeLayoutEngine.sideHandleHeight) / 110)
            )
            let showsExpandedBody = isBodyMounted
                && EdgeMemoPanelLayoutPolicy.showsExpandedBody(in: proxy.size)
            EdgeMemoPanelView(
                viewModel: viewModel,
                expansionProgress: expansionProgress,
                showsExpandedBody: showsExpandedBody,
                assetRootURL: assetRootURL,
                onImageUpload: onImageUpload
            )
        }
    }
}

struct EdgeMemoPanelView: View {
    @ObservedObject var viewModel: NoteEditorViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let expansionProgress: CGFloat
    let showsExpandedBody: Bool
    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL

    var body: some View {
        let textColor = Color(nsColor: viewModel.textColor)
        let increaseContrast = colorSchemeContrast == .increased
        let effectiveOpacity = reduceTransparency ? 1 : viewModel.opacity
        let cornerRadius = EdgeLayoutEngine.handleCornerRadius
            + (EdgeLayoutEngine.panelCornerRadius - EdgeLayoutEngine.handleCornerRadius) * expansionProgress

        VStack(spacing: 0) {
            titleBar(textColor: textColor)

            if showsExpandedBody {
                Rectangle()
                    .fill(
                        textColor.opacity(
                            (increaseContrast ? 0.38 : 0.18) * bodyRevealProgress
                        )
                    )
                    .frame(height: 1)

                MarkdownEditorView(
                    markdown: Binding(
                        get: { viewModel.content },
                        set: viewModel.updateMarkdownContent
                    ),
                    documentID: viewModel.noteID,
                    textColor: viewModel.textColor,
                    assetRootURL: assetRootURL,
                    onImageUpload: onImageUpload
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(bodyRevealProgress)
                .allowsHitTesting(bodyRevealProgress > 0.96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(viewModel.color.bodyColor.opacity(effectiveOpacity))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    textColor.opacity(
                        increaseContrast
                            ? 0.62
                            : (0.28 - 0.08 * expansionProgress)
                    ),
                    lineWidth: increaseContrast
                        ? 1.5
                        : (1.5 - 0.5 * expansionProgress)
                )
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func titleBar(textColor: Color) -> some View {
        ZStack {
            Text(viewModel.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .opacity(compactTitleOpacity)
                .help(viewModel.title)
                .allowsHitTesting(false)

            NativeMemoTitleField(
                text: Binding(
                    get: { viewModel.title },
                    set: viewModel.updateTitle
                ),
                textColor: viewModel.textColor,
                focusRequest: viewModel.titleFocusRequest
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .opacity(expandedTitleOpacity)
            .allowsHitTesting(expansionProgress > 0.96)
            .accessibilityLabel("메모 제목")
            .help("메모 제목")
        }
        .frame(height: interpolatedTitleBarHeight)
        .background(
            textColor.opacity(
                (colorSchemeContrast == .increased ? 0.075 : 0.035) * expansionProgress
            )
        )
        .contentShape(Rectangle())
    }

    private var interpolatedTitleBarHeight: CGFloat {
        EdgeLayoutEngine.sideHandleHeight
            + (EdgeLayoutEngine.titleBarHeight - EdgeLayoutEngine.sideHandleHeight) * expansionProgress
    }

    private var compactTitleOpacity: Double {
        Double(max(0, 1 - expansionProgress * 1.6))
    }

    private var expandedTitleOpacity: Double {
        Double(min(1, max(0, (expansionProgress - 0.12) / 0.7)))
    }

    private var bodyRevealProgress: Double {
        EdgeMemoPanelLayoutPolicy.bodyRevealProgress(expansionProgress: expansionProgress)
    }

}

private struct NativeMemoTitleField: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = "제목"
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        field.setAccessibilityLabel("메모 제목")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.textColor = textColor
        guard focusRequest > context.coordinator.handledFocusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeKeyAndOrderFront(nil)
            guard window.makeFirstResponder(field),
                  let fieldEditor = window.firstResponder as? NSTextView
            else { return }
            fieldEditor.setSelectedRange(
                NSRange(location: (fieldEditor.string as NSString).length, length: 0)
            )
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var handledFocusRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
