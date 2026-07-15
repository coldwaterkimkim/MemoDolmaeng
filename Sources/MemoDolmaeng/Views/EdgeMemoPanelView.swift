import Foundation
import SwiftUI

struct EdgeMemoPanelView: View {
    @ObservedObject var viewModel: NoteEditorViewModel
    @ObservedObject private var editorPreferences = AppPreferences.shared

    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onPointerChange: (Bool) -> Void

    var body: some View {
        MarkdownEditorView(
            markdown: viewModel.content,
            theme: MarkdownEditorTheme.current(
                preferences: editorPreferences,
                textColor: viewModel.textColor
            ),
            assetRootURL: assetRootURL,
            onMarkdownChange: viewModel.updateMarkdownContent,
            onImageUpload: onImageUpload
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(viewModel.color.bodyColor.opacity(viewModel.opacity))
        .overlay {
            Rectangle()
                .stroke(.black.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover(perform: onPointerChange)
    }
}
