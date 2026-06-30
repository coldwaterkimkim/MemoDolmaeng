import Foundation

struct MemoNote: Codable, Equatable, Identifiable {
    let id: UUID
    var content: String
    var richTextData: Data?
    var frame: NoteFrame
    var isVisible: Bool
    var color: NoteColor
    var floatsOnTop: Bool
    var isTranslucent: Bool
    var usesAutomaticHeight: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String = "",
        richTextData: Data? = nil,
        frame: NoteFrame,
        isVisible: Bool = true,
        color: NoteColor = .black,
        floatsOnTop: Bool = false,
        isTranslucent: Bool = false,
        usesAutomaticHeight: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.richTextData = richTextData
        self.frame = frame
        self.isVisible = isVisible
        self.color = color
        self.floatsOnTop = floatsOnTop
        self.isTranslucent = isTranslucent
        self.usesAutomaticHeight = usesAutomaticHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case richTextData
        case frame
        case isVisible
        case color
        case floatsOnTop
        case isTranslucent
        case usesAutomaticHeight
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        richTextData = try container.decodeIfPresent(Data.self, forKey: .richTextData)
        frame = try container.decode(NoteFrame.self, forKey: .frame)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        color = try container.decodeIfPresent(NoteColor.self, forKey: .color) ?? .black
        floatsOnTop = try container.decodeIfPresent(Bool.self, forKey: .floatsOnTop) ?? false
        isTranslucent = try container.decodeIfPresent(Bool.self, forKey: .isTranslucent) ?? false
        usesAutomaticHeight = try container.decodeIfPresent(Bool.self, forKey: .usesAutomaticHeight) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
