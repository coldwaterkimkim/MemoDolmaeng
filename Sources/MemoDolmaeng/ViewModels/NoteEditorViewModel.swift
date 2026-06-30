import AppKit
import SwiftUI

struct NoteAutoDeleteCountdown: Equatable {
    let id: UUID
    let duration: TimeInterval
}

@MainActor
final class NoteEditorViewModel: ObservableObject {
    let noteID: UUID
    private let store: NoteStore
    let initialAttributedText: NSAttributedString
    private var currentRichTextData: Data?

    @Published var color: NoteColor

    @Published private(set) var isTranslucent: Bool

    @Published private(set) var content: String

    @Published private(set) var autoDeleteCountdown: NoteAutoDeleteCountdown?

    var currentAttributedText: NSAttributedString {
        RichTextArchive.attributedString(
            plainText: content,
            richTextData: Self.shouldRestoreRichText(content: content) ? currentRichTextData : nil
        )
    }

    init(
        noteID: UUID,
        initialContent: String,
        initialRichTextData: Data?,
        color: NoteColor,
        isTranslucent: Bool,
        store: NoteStore
    ) {
        self.noteID = noteID
        self.content = initialContent
        self.color = color
        self.isTranslucent = isTranslucent
        self.store = store
        self.currentRichTextData = Self.shouldRestoreRichText(content: initialContent) ? initialRichTextData : nil
        self.initialAttributedText = RichTextArchive.attributedString(
            plainText: initialContent,
            richTextData: currentRichTextData
        )
    }

    func setColor(_ color: NoteColor) {
        self.color = color
        store.setColor(noteID: noteID, color: color)
    }

    func setTranslucent(_ isTranslucent: Bool) {
        self.isTranslucent = isTranslucent
    }

    func updateRichText(_ attributedText: NSAttributedString) {
        let richTextData = Self.containsAttachment(attributedText)
            ? RichTextArchive.data(from: attributedText)
            : nil

        content = attributedText.string
        currentRichTextData = richTextData
        store.updateRichContent(
            noteID: noteID,
            content: attributedText.string,
            richTextData: richTextData
        )
    }

    func updateMarkdownContent(_ markdown: String) {
        guard content != markdown || currentRichTextData != nil else { return }

        content = markdown
        currentRichTextData = nil
        store.updateRichContent(
            noteID: noteID,
            content: markdown,
            richTextData: nil
        )
    }

    func beginAutoDeleteCountdown(duration: TimeInterval) {
        autoDeleteCountdown = NoteAutoDeleteCountdown(id: UUID(), duration: duration)
    }

    func cancelAutoDeleteCountdown() {
        autoDeleteCountdown = nil
    }

    private static func shouldRestoreRichText(content: String) -> Bool {
        content.contains("\u{fffc}")
    }

    private static func containsAttachment(_ attributedText: NSAttributedString) -> Bool {
        var hasAttachment = false
        attributedText.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedText.length),
            options: []
        ) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }

        return hasAttachment
    }
}
