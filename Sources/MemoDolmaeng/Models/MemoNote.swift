import CoreGraphics
import Foundation

enum MemoAspectRatio: String, Codable, CaseIterable, Equatable {
    case square
    case portrait

    var value: CGFloat {
        switch self {
        case .square: 1
        case .portrait: 3 / 4
        }
    }

    static func closest(to value: CGFloat) -> MemoAspectRatio {
        abs(value - square.value) <= abs(value - portrait.value) ? .square : .portrait
    }
}

struct MemoPanelSize: Codable, Equatable {
    static let minimum = CGSize(width: 280, height: 240)
    static let maximum = CGSize(width: 720, height: 900)

    var width: Double
    var height: Double

    init(width: CGFloat, height: CGFloat) {
        self.width = Double(width)
        self.height = Double(height)
        normalize()
    }

    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    mutating func normalize() {
        width = Self.clamped(
            width,
            minimum: Double(Self.minimum.width),
            maximum: Double(Self.maximum.width),
            fallback: Double(EdgeLayoutEngine.panelWidth)
        )
        height = Self.clamped(
            height,
            minimum: Double(Self.minimum.height),
            maximum: Double(Self.maximum.height),
            fallback: Double(EdgeLayoutEngine.panelWidth / MemoAspectRatio.portrait.value)
        )
    }

    private static func clamped(
        _ value: Double,
        minimum: Double,
        maximum: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(maximum, max(minimum, value))
    }
}

struct MemoAttachment: Codable, Equatable, Identifiable {
    let id: UUID
    var fileName: String
    var originalName: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        originalName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.originalName = originalName
        self.createdAt = createdAt
    }
}

struct MemoPlacement: Codable, Equatable {
    var groupID: UUID
    var order: Int

    init(groupID: UUID, order: Int) {
        self.groupID = groupID
        self.order = max(0, order)
    }
}

struct MemoEdgeGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var edge: EdgeDock
    var normalizedCenter: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        edge: EdgeDock,
        normalizedCenter: Double = 0.5,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.edge = edge
        self.normalizedCenter = Self.normalizedUnitValue(normalizedCenter)
        self.createdAt = createdAt
    }

    mutating func normalize() {
        normalizedCenter = Self.normalizedUnitValue(normalizedCenter)
    }

    private static func normalizedUnitValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }
}

struct MemoNote: Codable, Equatable, Identifiable {
    static let translucentOpacity = 0.72
    static let maxTitleLength = 40

    let id: UUID
    var title: String {
        didSet {
            let normalized = Self.normalizedTitle(title, fallback: "메모")
            if title != normalized { title = normalized }
        }
    }
    var isTitleExplicit: Bool
    var content: String
    var color: NoteColor
    var textColorHex: String
    var placement: MemoPlacement
    var aspectRatio: MemoAspectRatio
    var panelSize: MemoPanelSize?
    var opacity: Double {
        didSet {
            let normalized = Self.normalizedUnitValue(opacity, fallback: 1)
            if opacity != normalized { opacity = normalized }
        }
    }
    var attachments: [MemoAttachment]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String? = nil,
        isTitleExplicit: Bool = false,
        content: String = "",
        color: NoteColor = .black,
        textColorHex: String? = nil,
        placement: MemoPlacement,
        aspectRatio: MemoAspectRatio = .portrait,
        panelSize: MemoPanelSize? = nil,
        opacity: Double = 1,
        attachments: [MemoAttachment] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = Self.normalizedTitle(
            title ?? Self.deriveTitle(from: content, fallbackIndex: 1),
            fallback: "메모"
        )
        self.isTitleExplicit = isTitleExplicit
        self.content = content
        self.color = color
        self.textColorHex = textColorHex ?? Self.defaultTextColorHex(for: color)
        self.placement = MemoPlacement(groupID: placement.groupID, order: placement.order)
        self.aspectRatio = aspectRatio
        self.panelSize = panelSize
        self.panelSize?.normalize()
        self.opacity = Self.normalizedUnitValue(opacity, fallback: 1)
        self.attachments = attachments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func deriveTitle(from content: String, fallbackIndex: Int) -> String {
        for line in content.components(separatedBy: .newlines) {
            let candidate = markdownTitleCandidate(from: line)
            if !candidate.isEmpty {
                return normalizedTitle(candidate, fallback: "메모\(max(1, fallbackIndex))")
            }
        }

        return normalizedTitle("메모\(max(1, fallbackIndex))", fallback: "메모")
    }

    var displayTitle: String {
        guard !isTitleExplicit, title.count <= 6 else { return title }
        let derived = Self.deriveTitle(from: content, fallbackIndex: 1)
        guard derived.count > title.count,
              derived.lowercased().hasPrefix(title.lowercased())
        else { return title }
        return derived
    }

    static func defaultTextColorHex(for color: NoteColor) -> String {
        color == .black ? "#FFFFFF" : "#1F1F1F"
    }

    static func hasMeaningfulContent(_ content: String) -> Bool {
        let trimmed = content
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.range(of: #"!\[[^\]]*\]\([^)]+\)"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"^\s*[-+*]\s+\[[ xX]\]"#, options: [.regularExpression]) != nil {
            return true
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.contains("|") {
            return true
        }

        var visible = trimmed
        visible = replacingMatches(in: visible, pattern: #"<[^>]+>"#, with: "")
        visible = visible.replacingOccurrences(of: #"[\s`*_~#>\[\](){}:;,.!\-+]"#, with: "", options: .regularExpression)
        return !visible.isEmpty
    }

    mutating func normalize(fallbackIndex: Int) {
        title = Self.normalizedTitle(title, fallback: "메모\(max(1, fallbackIndex))")
        placement = MemoPlacement(groupID: placement.groupID, order: placement.order)
        panelSize?.normalize()
        opacity = Self.normalizedUnitValue(opacity, fallback: 1)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case isTitleExplicit
        case content
        case color
        case textColorHex
        case placement
        case aspectRatio
        case panelSize
        case opacity
        case attachments
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        title = Self.normalizedTitle(
            try container.decodeIfPresent(String.self, forKey: .title)
                ?? Self.deriveTitle(from: content, fallbackIndex: 1),
            fallback: "메모"
        )
        isTitleExplicit = try container.decodeIfPresent(Bool.self, forKey: .isTitleExplicit) ?? false
        color = try container.decodeIfPresent(NoteColor.self, forKey: .color) ?? .black
        textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex)
            ?? Self.defaultTextColorHex(for: color)
        placement = try container.decode(MemoPlacement.self, forKey: .placement)
        aspectRatio = try container.decodeIfPresent(MemoAspectRatio.self, forKey: .aspectRatio) ?? .portrait
        panelSize = try container.decodeIfPresent(MemoPanelSize.self, forKey: .panelSize)
        panelSize?.normalize()
        opacity = Self.normalizedUnitValue(
            try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            fallback: 1
        )
        attachments = try container.decodeIfPresent([MemoAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(isTitleExplicit, forKey: .isTitleExplicit)
        try container.encode(content, forKey: .content)
        try container.encode(color, forKey: .color)
        try container.encode(textColorHex, forKey: .textColorHex)
        try container.encode(placement, forKey: .placement)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(panelSize, forKey: .panelSize)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func normalizedTitle(_ title: String, fallback: String) -> String {
        let collapsed = title
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let resolved = collapsed.isEmpty ? fallback : collapsed
        return String(resolved.prefix(maxTitleLength))
    }

    private static func normalizedUnitValue(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private static func markdownTitleCandidate(from line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("```") && !value.hasPrefix("~~~") else { return "" }

        value = replacingMatches(in: value, pattern: #"^(?:#{1,6}|>+|[-+*]|\d+[.)])\s+"#, with: "")
        value = replacingMatches(in: value, pattern: #"^\[[ xX]\]\s*"#, with: "")
        value = replacingMatches(in: value, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        value = replacingMatches(in: value, pattern: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
        value = replacingMatches(in: value, pattern: #"<[^>]+>"#, with: "")
        value = value.replacingOccurrences(of: #"[\`*_~#]"#, with: "", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}:;,.!?-| ").union(.whitespaces))

        return value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func replacingMatches(in value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
