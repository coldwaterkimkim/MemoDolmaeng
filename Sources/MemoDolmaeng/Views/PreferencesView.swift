import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var workspace: EdgeWorkspaceController
    @ObservedObject var edgePreferences: EdgePreferences
    @ObservedObject var editorPreferences: AppPreferences
    @State private var selectedNoteID: UUID?

    var body: some View {
        TabView {
            commonSettings
                .tabItem { Label("공통", systemImage: "gearshape") }
            noteSettings
                .tabItem { Label("메모별", systemImage: "note.text") }
        }
        .padding(18)
        .frame(width: 540, height: 430)
        .onAppear {
            if selectedNoteID == nil { selectedNoteID = workspace.activeNotes.first?.id }
        }
    }

    private var commonSettings: some View {
        Form {
            Picker("모니터", selection: displayBinding) {
                Text("마우스가 있는 화면").tag(UInt32?.none)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    Text("디스플레이 \(index + 1)").tag(screen.memoDisplayID as UInt32?)
                }
            }

            Picker("기본 가장자리", selection: $edgePreferences.defaultEdge) {
                ForEach(EdgeDock.allCases) { edge in Text(edge.title).tag(edge) }
            }
            .pickerStyle(.segmented)

            Picker("새 메모 기본 비율", selection: $edgePreferences.defaultAspectRawValue) {
                Text("1:1").tag(MemoAspectRatio.square.rawValue)
                Text("3:4").tag(MemoAspectRatio.portrait.rawValue)
            }
            .pickerStyle(.segmented)

            sliderRow("새 메모 투명도", value: $edgePreferences.defaultOpacity, range: 0.4...1, suffix: "%")
            sliderRow("인덱스 표시 대기", value: $edgePreferences.revealDelay, range: 0...1, suffix: "초")
            sliderRow("인덱스 숨김 지연", value: $edgePreferences.hideDelay, range: 0.05...2, suffix: "초")
            sliderRow("PEEK 접힘 지연", value: $edgePreferences.peekDelay, range: 0.1...2, suffix: "초")
            fontSizeRow

            LabeledContent("전역 단축키") {
                Text("⌘⇧M")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var noteSettings: some View {
        Form {
            Picker("활성 메모", selection: selectedNoteBinding) {
                ForEach(workspace.activeNotes) { note in
                    Text(note.title).tag(note.id as UUID?)
                }
            }

            if let note = selectedNote {
                TextField("인덱스 제목", text: Binding(
                    get: { note.title },
                    set: { workspace.updateTitle(noteID: note.id, title: $0) }
                ))

                LabeledContent("현재 배치") {
                    HStack {
                        Text(workspace.edge(for: note.id)?.title ?? "기본")
                            .foregroundStyle(.secondary)
                        Button {
                            workspace.attachToDefaultGroup(noteID: note.id)
                        } label: {
                            Label("기본 그룹에 붙이기", systemImage: "rectangle.3.group")
                        }
                    }
                }

                Picker("메모 비율", selection: Binding(
                    get: { note.aspectRatio },
                    set: { workspace.updateAppearance(noteID: note.id, aspectRatio: $0) }
                )) {
                    Text("1:1").tag(MemoAspectRatio.square)
                    Text("3:4").tag(MemoAspectRatio.portrait)
                }
                .pickerStyle(.segmented)

                LabeledContent("배경색") {
                    HStack(spacing: 8) {
                        ForEach(NoteColor.allCases, id: \.rawValue) { color in
                            Button {
                                workspace.updateAppearance(noteID: note.id, color: color)
                            } label: {
                                Circle()
                                    .fill(color.bodyColor)
                                    .overlay(Circle().stroke(note.color == color ? Color.accentColor : .secondary.opacity(0.35), lineWidth: note.color == color ? 3 : 1))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(color.title)
                        }
                    }
                }

                ColorPicker("글자색", selection: textColorBinding(note), supportsOpacity: false)
                sliderRow(
                    "투명도",
                    value: Binding(
                        get: { note.opacity },
                        set: { workspace.updateAppearance(noteID: note.id, opacity: $0) }
                    ),
                    range: 0.4...1,
                    suffix: "%"
                )
            } else {
                ContentUnavailableView("활성 메모가 없어", systemImage: "note.text")
            }
        }
        .formStyle(.grouped)
    }

    private var selectedNote: MemoNote? {
        guard let selectedNoteID else { return nil }
        return workspace.note(withID: selectedNoteID)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(get: { edgePreferences.targetDisplayID }, set: { edgePreferences.targetDisplayID = $0 })
    }

    private var selectedNoteBinding: Binding<UUID?> {
        Binding(
            get: { selectedNoteID ?? workspace.activeNotes.first?.id },
            set: { selectedNoteID = $0 }
        )
    }

    private var fontSizeRow: some View {
        let value = Binding<Double>(
            get: { Double(editorPreferences.bodyFontSize) },
            set: { editorPreferences.bodyFontSize = CGFloat($0) }
        )
        return sliderRow("편집기 글꼴", value: value, range: 9...22, suffix: "pt")
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                    .frame(width: 230)
                Text(formatted(value.wrappedValue, range: range, suffix: suffix))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }

    private func formatted(_ value: Double, range: ClosedRange<Double>, suffix: String) -> String {
        if suffix == "%" { return "\(Int((value * 100).rounded()))%" }
        return String(format: "%.1f%@", value, suffix)
    }

    private func textColorBinding(_ note: MemoNote) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor.memoColor(hex: note.textColorHex) ?? .labelColor) },
            set: { color in
                let converted = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
                let hex = String(
                    format: "#%02X%02X%02X",
                    Int(converted.redComponent * 255),
                    Int(converted.greenComponent * 255),
                    Int(converted.blueComponent * 255)
                )
                workspace.updateAppearance(noteID: note.id, textColorHex: hex)
            }
        )
    }
}
