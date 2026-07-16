import AppKit
import Foundation

@MainActor
final class NoteEditorViewModel: ObservableObject {
    let noteID: UUID

    @Published private(set) var title: String
    @Published private(set) var content: String
    @Published private(set) var color: NoteColor
    @Published private(set) var opacity: Double
    @Published private(set) var textColor: NSColor

    private let onTitleChange: (String) -> Void
    private let onContentChange: (String) -> Void

    init(
        note: MemoNote,
        onTitleChange: @escaping (String) -> Void,
        onContentChange: @escaping (String) -> Void
    ) {
        noteID = note.id
        title = note.displayTitle
        content = note.content
        color = note.color
        opacity = note.opacity
        textColor = NSColor.memoColor(hex: note.textColorHex) ?? (note.color == .black ? .white : .labelColor)
        self.onTitleChange = onTitleChange
        self.onContentChange = onContentChange
    }

    func updateTitle(_ value: String) {
        guard title != value else { return }
        title = String(value.prefix(MemoNote.maxTitleLength))
        onTitleChange(title)
    }

    func updateMarkdownContent(_ markdown: String) {
        guard content != markdown else { return }
        content = markdown
        onContentChange(markdown)
    }

    func sync(note: MemoNote) {
        guard note.id == noteID else { return }
        if title != note.displayTitle { title = note.displayTitle }
        if content != note.content { content = note.content }
        if color != note.color { color = note.color }
        if opacity != note.opacity { opacity = note.opacity }
        let nextTextColor = NSColor.memoColor(hex: note.textColorHex) ?? (note.color == .black ? .white : .labelColor)
        if textColor != nextTextColor { textColor = nextTextColor }
    }
}

extension NSColor {
    static func memoColor(hex: String) -> NSColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
