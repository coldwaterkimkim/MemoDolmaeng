import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var workspace: EdgeWorkspaceController
    @State private var query = ""
    @State private var filter: LibraryFilter = .all

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

                Picker("메모 상태 필터", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { filter in
                        Text("\(filter.title) \(noteCount(for: filter))")
                            .tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .accessibilityLabel("메모 상태 필터")

                TextField("제목이나 본문 검색", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("메모 검색")
            }
            .padding(16)

            Divider()

            if filteredNotes.isEmpty {
                emptyState
            } else {
                Table(filteredNotes) {
                    TableColumn("상태") { note in
                        Button {
                            toggleActive(note)
                        } label: {
                            Label(
                                note.isActive ? "활성" : "보관",
                                systemImage: note.isActive ? "pin.fill" : "archivebox"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(note.isActive ? Color.accentColor : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background {
                                Capsule()
                                    .fill(
                                        note.isActive
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.secondary.opacity(0.12)
                                    )
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(note.isActive ? "보관하기" : "활성화하기")
                        .accessibilityLabel(note.isActive ? "메모 보관하기" : "메모 활성화하기")
                        .accessibilityHint(note.isActive ? "현재 상태: 활성" : "현재 상태: 보관")
                    }
                    .width(min: 84, ideal: 90, max: 96)

                    TableColumn("메모") { note in
                        titleCell(for: note)
                    }
                    .width(min: 140, ideal: 190)

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
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("영구 삭제")
                        .accessibilityLabel("\(note.displayTitle) 메모 영구 삭제")
                    }
                    .width(34)
                }
                .alternatingRowBackgrounds(.disabled)
            }
        }
        .frame(minWidth: 720, minHeight: 430)
    }

    private var filteredNotes: [MemoNote] {
        let ordered = workspace.notes
            .filter(filter.includes)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !normalizedQuery.isEmpty else { return ordered }
        return ordered.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.content.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: emptyStateSymbol)
        } description: {
            Text(emptyStateDescription)
        } actions: {
            Button(emptyStateActionTitle, action: performEmptyStateAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !normalizedQuery.isEmpty { return "검색 결과가 없어" }
        switch filter {
        case .all: return "아직 메모가 없어"
        case .active: return "활성 메모가 없어"
        case .archived: return "보관한 메모가 없어"
        }
    }

    private var emptyStateSymbol: String {
        if !normalizedQuery.isEmpty { return "magnifyingglass" }
        switch filter {
        case .all: return "note.text"
        case .active: return "pin"
        case .archived: return "archivebox"
        }
    }

    private var emptyStateDescription: String {
        if !normalizedQuery.isEmpty {
            return "검색어를 다르게 입력하거나 필터를 바꿔봐."
        }
        switch filter {
        case .all:
            return "새 메모를 만들면 엣지에 바로 열려."
        case .active:
            return workspace.notes.contains(where: { !$0.isActive })
                ? "보관한 메모를 다시 활성화할 수 있어."
                : "새 메모를 만들어 시작해봐."
        case .archived:
            return "보관한 메모는 여기에 모여."
        }
    }

    private var emptyStateActionTitle: String {
        if !normalizedQuery.isEmpty { return "검색어 지우기" }
        switch filter {
        case .all: return "새 메모 만들기"
        case .active:
            return workspace.notes.contains(where: { !$0.isActive })
                ? "보관 메모 보기"
                : "새 메모 만들기"
        case .archived: return "전체 메모 보기"
        }
    }

    private func performEmptyStateAction() {
        if !normalizedQuery.isEmpty {
            query = ""
            return
        }
        switch filter {
        case .all:
            workspace.createNote()
        case .active:
            if workspace.notes.contains(where: { !$0.isActive }) {
                filter = .archived
            } else {
                workspace.createNote()
            }
        case .archived:
            filter = .all
        }
    }

    @ViewBuilder
    private func titleCell(for note: MemoNote) -> some View {
        if note.isActive {
            Button {
                workspace.openFromLibrary(noteID: note.id)
            } label: {
                titleLabel(for: note, showsOpenIndicator: true)
            }
            .buttonStyle(.plain)
            .help("메모 열기")
            .accessibilityLabel("\(note.displayTitle) 메모 열기")
            .accessibilityHint("엣지에 편집 창을 열어")
        } else {
            titleLabel(for: note, showsOpenIndicator: false)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(note.displayTitle), 보관된 메모")
        }
    }

    private func titleLabel(for note: MemoNote, showsOpenIndicator: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(note.color.bodyColor)
                .overlay {
                    Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                }
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            Text(note.displayTitle)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer(minLength: 6)

            if showsOpenIndicator {
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func noteCount(for filter: LibraryFilter) -> Int {
        workspace.notes.lazy.filter(filter.includes).count
    }

    private func preview(_ content: String) -> String {
        let value = content
            .replacingOccurrences(of: #"[#*_`~>\[\]()]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return value.isEmpty ? "내용 없음" : value
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
        alert.messageText = "‘\(note.displayTitle)’ 메모를 삭제할까?"
        alert.informativeText = "본문과 메모에 복사된 이미지가 함께 삭제되며 되돌릴 수 없어."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "삭제").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        workspace.delete(noteID: note.id)
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case archived

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "전체"
        case .active: "활성"
        case .archived: "보관"
        }
    }

    func includes(_ note: MemoNote) -> Bool {
        switch self {
        case .all: true
        case .active: note.isActive
        case .archived: !note.isActive
        }
    }
}
