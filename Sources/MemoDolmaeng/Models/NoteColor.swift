import SwiftUI

enum NoteColor: String, Codable, CaseIterable, Equatable {
    case black
    case yellow
    case blue
    case green
    case pink
    case purple
    case gray
    case white

    var title: String {
        switch self {
        case .black: "Black"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .green: "Green"
        case .pink: "Pink"
        case .purple: "Purple"
        case .gray: "Gray"
        case .white: "White"
        }
    }

    var bodyColor: Color {
        switch self {
        case .black:
            Color(red: 0, green: 0, blue: 0)
        case .yellow:
            Color(red: 254 / 255, green: 243 / 255, blue: 155 / 255)
        case .blue:
            Color(red: 188 / 255, green: 224 / 255, blue: 255 / 255)
        case .green:
            Color(red: 206 / 255, green: 239 / 255, blue: 173 / 255)
        case .pink:
            Color(red: 255 / 255, green: 205 / 255, blue: 221 / 255)
        case .purple:
            Color(red: 224 / 255, green: 207 / 255, blue: 255 / 255)
        case .gray:
            Color(red: 228 / 255, green: 228 / 255, blue: 222 / 255)
        case .white:
            Color(red: 1, green: 1, blue: 1)
        }
    }

    var stripColor: Color {
        switch self {
        case .black:
            Color(red: 0.04, green: 0.04, blue: 0.04)
        case .yellow:
            Color(red: 253 / 255, green: 232 / 255, blue: 82 / 255)
        case .blue:
            Color(red: 132 / 255, green: 197 / 255, blue: 250 / 255)
        case .green:
            Color(red: 168 / 255, green: 220 / 255, blue: 121 / 255)
        case .pink:
            Color(red: 248 / 255, green: 154 / 255, blue: 187 / 255)
        case .purple:
            Color(red: 190 / 255, green: 163 / 255, blue: 247 / 255)
        case .gray:
            Color(red: 198 / 255, green: 198 / 255, blue: 191 / 255)
        case .white:
            Color(red: 238 / 255, green: 238 / 255, blue: 232 / 255)
        }
    }
}
