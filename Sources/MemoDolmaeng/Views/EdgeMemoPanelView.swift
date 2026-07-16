import Foundation
import SwiftUI

struct EdgeMemoPanelView: View {
    @ObservedObject var viewModel: NoteEditorViewModel
    @ObservedObject private var editorPreferences = AppPreferences.shared

    let isIce: Bool
    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onRequestIce: () -> Void
    let onPointerChange: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                "제목",
                text: Binding(
                    get: { viewModel.title },
                    set: viewModel.updateTitle
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(nsColor: viewModel.textColor))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onRequestIce))

            Rectangle()
                .fill(Color(nsColor: viewModel.textColor).opacity(0.16))
                .frame(height: 1)

            MarkdownEditorView(
                markdown: viewModel.content,
                theme: MarkdownEditorTheme.current(
                    preferences: editorPreferences,
                    textColor: viewModel.textColor,
                    showsTopBar: isIce
                ),
                assetRootURL: assetRootURL,
                onInteraction: onRequestIce,
                onMarkdownChange: viewModel.updateMarkdownContent,
                onImageUpload: onImageUpload
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(viewModel.color.bodyColor.opacity(viewModel.opacity))
        .overlay {
            RoundedRectangle(
                cornerRadius: EdgeLayoutEngine.panelCornerRadius,
                style: .continuous
            )
                .stroke(.black.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: EdgeLayoutEngine.panelCornerRadius,
                style: .continuous
            )
        )
        .onHover(perform: onPointerChange)
    }
}
