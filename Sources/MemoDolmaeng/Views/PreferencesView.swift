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
            reconcileSelectedNote()
        }
        .onChange(of: activeNoteIDs) { _, _ in
            reconcileSelectedNote()
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

            Picker("새 메모가 열릴 쪽", selection: $edgePreferences.defaultEdge) {
                ForEach(EdgeDock.interactiveCases) { edge in Text(edge.title).tag(edge) }
            }
            .pickerStyle(.segmented)

            sliderRow("새 메모 투명도", value: $edgePreferences.defaultOpacity, range: 0.4...1, suffix: "%")
            sliderRow("인덱스 표시 대기", value: $edgePreferences.revealDelay, range: 0...1, suffix: "초")
            sliderRow("인덱스 숨김 지연", value: $edgePreferences.hideDelay, range: 0.05...10, suffix: "초")
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
            if workspace.activeNotes.isEmpty {
                ContentUnavailableView("활성 메모가 없어", systemImage: "note.text")
            } else {
                Picker("활성 메모", selection: selectedNoteBinding) {
                    ForEach(workspace.activeNotes) { note in
                        Text(note.displayTitle).tag(note.id as UUID?)
                    }
                }

                if let note = selectedNote {
                    TextField("인덱스 제목", text: Binding(
                        get: { note.displayTitle },
                        set: { workspace.updateTitle(noteID: note.id, title: $0) }
                    ))

                    if let panelSize = note.panelSize {
                        LabeledContent("메모 폭") {
                            Text("\(Int(panelSize.width.rounded())) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("배경색") {
                        HStack(spacing: 4) {
                            ForEach(NoteColor.allCases, id: \.rawValue) { color in
                                let isSelected = note.color == color
                                Button {
                                    workspace.updateAppearance(noteID: note.id, color: color)
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(color.bodyColor)
                                            .overlay {
                                                Circle().stroke(
                                                    isSelected ? Color.accentColor : .secondary.opacity(0.35),
                                                    lineWidth: isSelected ? 3 : 1
                                                )
                                            }
                                            .frame(width: 24, height: 24)

                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(
                                                    color == .black
                                                        ? Color.white
                                                        : Color.black.opacity(0.72)
                                                )
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(color.title)
                                .accessibilityLabel("\(color.title) 배경색")
                                .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedNote: MemoNote? {
        guard let selectedNoteID else { return nil }
        return workspace.activeNotes.first(where: { $0.id == selectedNoteID })
    }

    private var activeNoteIDs: [UUID] {
        workspace.activeNotes.map(\.id)
    }

    private var displayBinding: Binding<UInt32?> {
        Binding(get: { edgePreferences.targetDisplayID }, set: { edgePreferences.targetDisplayID = $0 })
    }

    private var selectedNoteBinding: Binding<UUID?> {
        Binding(
            get: {
                if let selectedNoteID, activeNoteIDs.contains(selectedNoteID) {
                    return selectedNoteID
                }
                return activeNoteIDs.first
            },
            set: { selectedNoteID = $0 }
        )
    }

    private func reconcileSelectedNote() {
        if let selectedNoteID, activeNoteIDs.contains(selectedNoteID) { return }
        selectedNoteID = activeNoteIDs.first
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
        if suffix == "초", range.upperBound <= 1 { return String(format: "%.2f%@", value, suffix) }
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
