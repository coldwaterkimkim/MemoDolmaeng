import SwiftUI

struct NoteWindowView: View {
    @ObservedObject var viewModel: NoteEditorViewModel
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some View {
        ZStack(alignment: .top) {
            paperBodyColor
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: NoteWindowMetrics.dragHandleHeight)
                    .allowsHitTesting(false)

                MarkdownEditorView(
                    markdown: viewModel.content,
                    theme: MarkdownEditorTheme.current(preferences: preferences),
                    onMarkdownChange: viewModel.updateMarkdownContent
                )
                .frame(minWidth: 240, minHeight: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WindowDragHandle()
                .frame(height: NoteWindowMetrics.dragHandleHeight)
                .background(paperStripColor)

            dragHandleBottomLine
        }
        .background(paperBodyColor)
        .overlay(edgeStroke)
        .clipShape(Rectangle())
    }

    private var paperBodyColor: Color {
        viewModel.color.bodyColor.opacity(paperOpacity)
    }

    private var paperStripColor: Color {
        viewModel.color.stripColor.opacity(paperOpacity)
    }

    private var paperOpacity: Double {
        guard viewModel.isTranslucent else { return 1 }
        let alpha = Double(max(0, min(1, preferences.translucentAlpha)))
        // Fully transparent pixels in a borderless clear window can become click-through.
        // One alpha step keeps the window interactive while still reading as invisible.
        return alpha == 0 ? 1 / 255 : alpha
    }

    private var edgeStroke: some View {
        Rectangle()
            .stroke(
                Color(nsColor: preferences.windowEdgeStrokeColor)
                    .opacity(Double(max(0, min(1, preferences.windowEdgeStrokeOpacity)))),
                lineWidth: max(0, preferences.windowEdgeStrokeWidth)
            )
            .allowsHitTesting(false)
    }

    private var dragHandleBottomLine: some View {
        Group {
            if let countdown = viewModel.autoDeleteCountdown {
                AutoDeleteProgressLine(
                    countdown: countdown,
                    lineHeight: dragHandleLineHeight,
                    color: autoDeleteLineColor
                )
                .id(countdown.id)
            } else {
                Rectangle()
                    .fill(dragHandleStrokeColor)
                    .frame(height: dragHandleLineHeight)
            }
        }
        .padding(.top, max(0, NoteWindowMetrics.dragHandleHeight - dragHandleLineHeight))
    }

    private var dragHandleLineHeight: CGFloat {
        max(0, preferences.windowEdgeStrokeWidth)
    }

    private var dragHandleStrokeColor: Color {
        Color(nsColor: preferences.windowEdgeStrokeColor)
            .opacity(Double(max(0, min(1, preferences.windowEdgeStrokeOpacity))))
    }

    private var autoDeleteLineColor: Color {
        Color(nsColor: preferences.textColor)
    }
}

private struct AutoDeleteProgressLine: View {
    let countdown: NoteAutoDeleteCountdown
    let lineHeight: CGFloat
    let color: Color

    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(color)
                .frame(width: max(0, proxy.size.width * progress), height: lineHeight)
                .frame(width: proxy.size.width, height: lineHeight, alignment: .leading)
        }
        .frame(height: lineHeight)
        .allowsHitTesting(false)
        .onAppear(perform: startCountdownAnimation)
    }

    private func startCountdownAnimation() {
        progress = 1

        DispatchQueue.main.async {
            withAnimation(.linear(duration: countdown.duration)) {
                progress = 0
            }
        }
    }
}
