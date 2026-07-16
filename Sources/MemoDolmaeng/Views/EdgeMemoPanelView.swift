import AppKit
import Foundation
import SwiftUI

struct UnifiedEdgeMemoSurfaceView: View {
    @ObservedObject var viewModel: NoteEditorViewModel

    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onRequestIce: () -> Void
    let onRequestFold: () -> Void
    let onPointerChange: (Bool) -> Void
    let onTitleDragBegan: (NSPoint) -> Void
    let onTitleDragChanged: (NSPoint) -> Void
    let onTitleDragEnded: (NSPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            let expansionProgress = min(
                1,
                max(0, (proxy.size.height - EdgeLayoutEngine.sideHandleHeight) / 110)
            )
            EdgeMemoPanelView(
                viewModel: viewModel,
                expansionProgress: expansionProgress,
                assetRootURL: assetRootURL,
                onImageUpload: onImageUpload,
                onRequestIce: onRequestIce,
                onRequestFold: onRequestFold,
                onTitleDragBegan: onTitleDragBegan,
                onTitleDragChanged: onTitleDragChanged,
                onTitleDragEnded: onTitleDragEnded
            )
        }
        .onHover(perform: onPointerChange)
    }
}

struct EdgeMemoPanelView: View {
    @ObservedObject var viewModel: NoteEditorViewModel
    @State private var isDraggingTitle = false

    let expansionProgress: CGFloat
    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onRequestIce: () -> Void
    let onRequestFold: () -> Void
    let onTitleDragBegan: (NSPoint) -> Void
    let onTitleDragChanged: (NSPoint) -> Void
    let onTitleDragEnded: (NSPoint) -> Void

    var body: some View {
        let textColor = Color(nsColor: viewModel.textColor)
        let cornerRadius = EdgeLayoutEngine.handleCornerRadius
            + (EdgeLayoutEngine.panelCornerRadius - EdgeLayoutEngine.handleCornerRadius) * expansionProgress

        VStack(spacing: 0) {
            titleBar(textColor: textColor)

            Rectangle()
                .fill(textColor.opacity(0.18 * bodyRevealProgress))
                .frame(height: 1)

            MarkdownEditorView(
                markdown: Binding(
                    get: { viewModel.content },
                    set: viewModel.updateMarkdownContent
                ),
                documentID: viewModel.noteID,
                textColor: viewModel.textColor,
                assetRootURL: assetRootURL,
                onInteraction: onRequestIce,
                onImageUpload: onImageUpload
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(bodyRevealProgress)
            .allowsHitTesting(bodyRevealProgress > 0.96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(viewModel.color.bodyColor.opacity(viewModel.opacity))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    textColor.opacity(0.28 - 0.08 * expansionProgress),
                    lineWidth: 1.5 - 0.5 * expansionProgress
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

            HStack(spacing: 6) {
                TextField(
                    "제목",
                    text: Binding(
                        get: { viewModel.title },
                        set: viewModel.updateTitle
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded(onRequestIce))

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.48))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .gesture(titleDragGesture)
                    .help("메모 이동")
                    .accessibilityLabel("메모 이동")

                Button(action: onRequestFold) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("메모 접기")
                .accessibilityLabel("메모 접기")
            }
            .padding(.horizontal, 10)
            .opacity(expandedTitleOpacity)
            .allowsHitTesting(expansionProgress > 0.96)
        }
        .frame(height: interpolatedTitleBarHeight)
        .background(textColor.opacity(0.035 * expansionProgress))
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
        Double(min(1, max(0, (expansionProgress - 0.16) / 0.84)))
    }

    private var titleDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let point = NSEvent.mouseLocation
                if !isDraggingTitle {
                    isDraggingTitle = true
                    onTitleDragBegan(point)
                }
                onTitleDragChanged(point)
            }
            .onEnded { _ in
                guard isDraggingTitle else { return }
                isDraggingTitle = false
                onTitleDragEnded(NSEvent.mouseLocation)
            }
    }
}
