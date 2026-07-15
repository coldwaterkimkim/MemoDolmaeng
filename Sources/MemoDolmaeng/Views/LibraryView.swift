import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var workspace: EdgeWorkspaceController
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                Text("보관함")
                    .font(.title2.weight(.semibold))
                Text("활성 \(workspace.activeNotes.count)/\(NoteStore.maxActiveNotes)")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("제목이나 본문 검색", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(16)

            Divider()

            Table(filteredNotes) {
                TableColumn("상태") { note in
                    Button {
                        toggleActive(note)
                    } label: {
                        Image(systemName: note.isActive ? "pin.fill" : "archivebox")
                            .foregroundStyle(note.isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(note.isActive ? "보관하기" : "활성화하기")
                }
                .width(42)

                TableColumn("제목") { note in
                    Button(note.title) {
                        workspace.openFromLibrary(noteID: note.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(!note.isActive)
                    .fontWeight(.medium)
                }
                .width(min: 90, ideal: 130)

                TableColumn("본문 미리보기") { note in
                    Text(preview(note.content))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TableColumn("수정일") { note in
                    Text(note.updatedAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 150)

                TableColumn("") { note in
                    Button(role: .destructive) {
                        confirmDelete(note)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("영구 삭제")
                }
                .width(34)
            }
        }
        .frame(minWidth: 720, minHeight: 430)
    }

    private var filteredNotes: [MemoNote] {
        let ordered = workspace.notes.sorted { $0.updatedAt > $1.updatedAt }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ordered }
        return ordered.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.content.localizedCaseInsensitiveContains(normalized)
        }
    }

    private func preview(_ content: String) -> String {
        content
            .replacingOccurrences(of: #"[#*_`~>\[\]()]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func toggleActive(_ note: MemoNote) {
        if note.isActive {
            workspace.archive(noteID: note.id)
        } else if workspace.restore(noteID: note.id) == .capacityReached {
            let alert = NSAlert()
            alert.messageText = "활성 메모가 10개야"
            alert.informativeText = "먼저 활성 메모 하나를 보관해줘."
            alert.runModal()
        }
    }

    private func confirmDelete(_ note: MemoNote) {
        let alert = NSAlert()
        alert.messageText = "‘\(note.title)’ 메모를 삭제할까?"
        alert.informativeText = "본문과 메모에 복사된 이미지가 함께 삭제되며 되돌릴 수 없어."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspace.delete(noteID: note.id)
    }
}
