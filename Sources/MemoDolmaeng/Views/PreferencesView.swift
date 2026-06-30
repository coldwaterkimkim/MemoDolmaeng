import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Text") {
                    ColorPicker("Fill", selection: colorBinding(\.textColor))
                    ColorPicker("Stroke", selection: colorBinding(\.strokeColor))
                    slider("Stroke Weight", value: $preferences.strokeWidth, range: 0...2, step: 0.05)
                    slider("Body Size", value: $preferences.bodyFontSize, range: 8...24, step: 0.5)
                    slider("Heading 1", value: $preferences.heading1FontSize, range: 12...36, step: 0.5)
                    slider("Heading 2", value: $preferences.heading2FontSize, range: 10...30, step: 0.5)
                    slider("Heading 3", value: $preferences.heading3FontSize, range: 9...26, step: 0.5)
                    slider("Code Size", value: $preferences.codeFontSize, range: 8...24, step: 0.5)
                }

                section("Spacing") {
                    slider("Paragraph", value: $preferences.paragraphSpacing, range: 0...10, step: 0.5)
                    slider("Heading 1 Gap", value: $preferences.heading1Spacing, range: 0...16, step: 0.5)
                    slider("Heading 2 Gap", value: $preferences.heading2Spacing, range: 0...14, step: 0.5)
                    slider("Heading 3 Gap", value: $preferences.heading3Spacing, range: 0...12, step: 0.5)
                    slider("Code Block Gap", value: $preferences.codeBlockSpacing, range: 0...12, step: 0.5)
                    slider("List Indent", value: $preferences.listIndent, range: 0...40, step: 1)
                    slider("Quote Indent", value: $preferences.quoteIndent, range: 0...40, step: 1)
                }

                section("Window") {
                    slider("Width", value: $preferences.windowWidth, range: 220...520, step: 5)
                    slider("Min Height", value: $preferences.minimumHeight, range: 24...120, step: 1)
                    slider("Max Auto Height", value: $preferences.maximumAutomaticHeight, range: 180...900, step: 10)
                    slider("Horizontal Padding", value: $preferences.horizontalInset, range: 0...40, step: 1)
                    slider("Vertical Padding", value: $preferences.verticalInset, range: 0...40, step: 1)
                    slider("Drag Strip", value: $preferences.dragHandleHeight, range: 0...28, step: 1)
                    slider("Translucent Alpha", value: $preferences.translucentAlpha, range: 0...1, step: 0.01)
                    ColorPicker("Edge Stroke", selection: colorBinding(\.windowEdgeStrokeColor))
                    slider("Edge Stroke Weight", value: $preferences.windowEdgeStrokeWidth, range: 0...4, step: 0.1)
                    slider("Edge Stroke Opacity", value: $preferences.windowEdgeStrokeOpacity, range: 0...1, step: 0.01)
                    Toggle("Shadow", isOn: $preferences.windowShadowEnabled)
                }

                HStack {
                    Spacer()
                    Button("Reset") {
                        preferences.resetToDefaults()
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 520, height: 620)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        let doubleValue = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = CGFloat($0) }
        )

        return HStack(spacing: 10) {
            Text(title)
                .frame(width: 140, alignment: .leading)
            Slider(value: doubleValue, in: range, step: step)
            Text(String(format: "%.2g", Double(value.wrappedValue)))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<AppPreferences, NSColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: preferences[keyPath: keyPath]) },
            set: { preferences[keyPath: keyPath] = NSColor($0) }
        )
    }
}
