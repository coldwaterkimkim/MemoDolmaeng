import Foundation
import SwiftUI

struct UnifiedEdgeMemoSurfaceView: View {
    @ObservedObject var viewModel: NoteEditorViewModel

    let edge: EdgeDock
    let handleSize: CGSize
    let handleOffset: CGFloat
    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onRequestIce: () -> Void
    let onRequestFold: () -> Void
    let onPointerChange: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = surfaceLayout(in: proxy.size)

            ZStack(alignment: .topLeading) {
                EdgeMemoPanelView(
                    viewModel: viewModel,
                    assetRootURL: assetRootURL,
                    onImageUpload: onImageUpload,
                    onRequestIce: onRequestIce
                )
                .frame(width: layout.body.width, height: layout.body.height)
                .offset(x: layout.body.minX, y: layout.body.minY)

                MemoAnchorHandleView(
                    title: viewModel.title,
                    fillColor: viewModel.color.bodyColor.opacity(viewModel.opacity),
                    textColor: Color(nsColor: viewModel.textColor),
                    edge: edge
                )
                .frame(width: layout.handle.width, height: layout.handle.height)
                .offset(x: layout.handle.minX, y: layout.handle.minY)
                .contentShape(Rectangle())
                .onTapGesture(perform: onRequestFold)
            }
        }
        .onHover(perform: onPointerChange)
    }

    private func surfaceLayout(in size: CGSize) -> (body: CGRect, handle: CGRect) {
        switch edge {
        case .right:
            let bodyWidth = max(1, size.width - handleSize.width)
            let y = min(max(0, handleOffset), max(0, size.height - handleSize.height))
            return (
                CGRect(x: 0, y: 0, width: bodyWidth, height: size.height),
                CGRect(x: bodyWidth, y: y, width: handleSize.width, height: handleSize.height)
            )
        case .left:
            let bodyWidth = max(1, size.width - handleSize.width)
            let y = min(max(0, handleOffset), max(0, size.height - handleSize.height))
            return (
                CGRect(x: handleSize.width, y: 0, width: bodyWidth, height: size.height),
                CGRect(x: 0, y: y, width: handleSize.width, height: handleSize.height)
            )
        case .top:
            let bodyHeight = max(1, size.height - handleSize.height)
            let x = min(max(0, handleOffset), max(0, size.width - handleSize.width))
            return (
                CGRect(x: 0, y: handleSize.height, width: size.width, height: bodyHeight),
                CGRect(x: x, y: 0, width: handleSize.width, height: handleSize.height)
            )
        }
    }
}

struct EdgeMemoPanelView: View {
    @ObservedObject var viewModel: NoteEditorViewModel

    let assetRootURL: URL
    let onImageUpload: (Data, String) throws -> URL
    let onRequestIce: () -> Void

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
    }
}

private struct MemoAnchorHandleView: View {
    let title: String
    let fillColor: Color
    let textColor: Color
    let edge: EdgeDock

    var body: some View {
        let shape = connectedShape

        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 7)
            .background(shape.fill(fillColor))
            .overlay(shape.stroke(textColor.opacity(0.28), lineWidth: 1.5))
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }

    private var connectedShape: UnevenRoundedRectangle {
        let radius = EdgeLayoutEngine.handleCornerRadius
        switch edge {
        case .right:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        case .left:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .top:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }
}
