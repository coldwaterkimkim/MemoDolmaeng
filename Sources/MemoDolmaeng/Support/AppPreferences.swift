import AppKit
import Combine

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var textColor: NSColor {
        didSet { saveColor(textColor, key: Key.textColor); notifyChanged() }
    }

    @Published var strokeColor: NSColor {
        didSet { saveColor(strokeColor, key: Key.strokeColor); notifyChanged() }
    }

    @Published var strokeWidth: CGFloat {
        didSet { save(strokeWidth, key: Key.strokeWidth); notifyChanged() }
    }

    @Published var windowEdgeStrokeColor: NSColor {
        didSet { saveColor(windowEdgeStrokeColor, key: Key.windowEdgeStrokeColor); notifyChanged() }
    }

    @Published var windowEdgeStrokeWidth: CGFloat {
        didSet { save(windowEdgeStrokeWidth, key: Key.windowEdgeStrokeWidth); notifyChanged() }
    }

    @Published var windowEdgeStrokeOpacity: CGFloat {
        didSet { save(windowEdgeStrokeOpacity, key: Key.windowEdgeStrokeOpacity); notifyChanged() }
    }

    @Published var bodyFontSize: CGFloat {
        didSet { save(bodyFontSize, key: Key.bodyFontSize); notifyChanged() }
    }

    @Published var heading1FontSize: CGFloat {
        didSet { save(heading1FontSize, key: Key.heading1FontSize); notifyChanged() }
    }

    @Published var heading2FontSize: CGFloat {
        didSet { save(heading2FontSize, key: Key.heading2FontSize); notifyChanged() }
    }

    @Published var heading3FontSize: CGFloat {
        didSet { save(heading3FontSize, key: Key.heading3FontSize); notifyChanged() }
    }

    @Published var codeFontSize: CGFloat {
        didSet { save(codeFontSize, key: Key.codeFontSize); notifyChanged() }
    }

    @Published var paragraphSpacing: CGFloat {
        didSet { save(paragraphSpacing, key: Key.paragraphSpacing); notifyChanged() }
    }

    @Published var heading1Spacing: CGFloat {
        didSet { save(heading1Spacing, key: Key.heading1Spacing); notifyChanged() }
    }

    @Published var heading2Spacing: CGFloat {
        didSet { save(heading2Spacing, key: Key.heading2Spacing); notifyChanged() }
    }

    @Published var heading3Spacing: CGFloat {
        didSet { save(heading3Spacing, key: Key.heading3Spacing); notifyChanged() }
    }

    @Published var codeBlockSpacing: CGFloat {
        didSet { save(codeBlockSpacing, key: Key.codeBlockSpacing); notifyChanged() }
    }

    @Published var windowWidth: CGFloat {
        didSet { save(windowWidth, key: Key.windowWidth); notifyChanged() }
    }

    @Published var minimumHeight: CGFloat {
        didSet { save(minimumHeight, key: Key.minimumHeight); notifyChanged() }
    }

    @Published var maximumAutomaticHeight: CGFloat {
        didSet { save(maximumAutomaticHeight, key: Key.maximumAutomaticHeight); notifyChanged() }
    }

    @Published var horizontalInset: CGFloat {
        didSet { save(horizontalInset, key: Key.horizontalInset); notifyChanged() }
    }

    @Published var verticalInset: CGFloat {
        didSet { save(verticalInset, key: Key.verticalInset); notifyChanged() }
    }

    @Published var dragHandleHeight: CGFloat {
        didSet { save(dragHandleHeight, key: Key.dragHandleHeight); notifyChanged() }
    }

    @Published var listIndent: CGFloat {
        didSet { save(listIndent, key: Key.listIndent); notifyChanged() }
    }

    @Published var quoteIndent: CGFloat {
        didSet { save(quoteIndent, key: Key.quoteIndent); notifyChanged() }
    }

    @Published var translucentAlpha: CGFloat {
        didSet { save(translucentAlpha, key: Key.translucentAlpha); notifyChanged() }
    }

    @Published var windowShadowEnabled: Bool {
        didSet { defaults.set(windowShadowEnabled, forKey: Key.windowShadowEnabled); notifyChanged() }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textColor = Self.color(forKey: Key.textColor, default: Defaults.textColor, defaults: defaults)
        strokeColor = Self.color(forKey: Key.strokeColor, default: Defaults.strokeColor, defaults: defaults)
        strokeWidth = Self.value(forKey: Key.strokeWidth, default: Defaults.strokeWidth, defaults: defaults)
        windowEdgeStrokeColor = Self.color(forKey: Key.windowEdgeStrokeColor, default: Defaults.windowEdgeStrokeColor, defaults: defaults)
        windowEdgeStrokeWidth = Self.value(forKey: Key.windowEdgeStrokeWidth, default: Defaults.windowEdgeStrokeWidth, defaults: defaults)
        windowEdgeStrokeOpacity = Self.value(forKey: Key.windowEdgeStrokeOpacity, default: Defaults.windowEdgeStrokeOpacity, defaults: defaults)
        bodyFontSize = Self.value(forKey: Key.bodyFontSize, default: Defaults.bodyFontSize, defaults: defaults)
        heading1FontSize = Self.value(forKey: Key.heading1FontSize, default: Defaults.heading1FontSize, defaults: defaults)
        heading2FontSize = Self.value(forKey: Key.heading2FontSize, default: Defaults.heading2FontSize, defaults: defaults)
        heading3FontSize = Self.value(forKey: Key.heading3FontSize, default: Defaults.heading3FontSize, defaults: defaults)
        codeFontSize = Self.value(forKey: Key.codeFontSize, default: Defaults.codeFontSize, defaults: defaults)
        paragraphSpacing = Self.value(forKey: Key.paragraphSpacing, default: Defaults.paragraphSpacing, defaults: defaults)
        heading1Spacing = Self.value(forKey: Key.heading1Spacing, default: Defaults.heading1Spacing, defaults: defaults)
        heading2Spacing = Self.value(forKey: Key.heading2Spacing, default: Defaults.heading2Spacing, defaults: defaults)
        heading3Spacing = Self.value(forKey: Key.heading3Spacing, default: Defaults.heading3Spacing, defaults: defaults)
        codeBlockSpacing = Self.value(forKey: Key.codeBlockSpacing, default: Defaults.codeBlockSpacing, defaults: defaults)
        windowWidth = Self.value(forKey: Key.windowWidth, default: Defaults.windowWidth, defaults: defaults)
        minimumHeight = Self.value(forKey: Key.minimumHeight, default: Defaults.minimumHeight, defaults: defaults)
        maximumAutomaticHeight = Self.value(forKey: Key.maximumAutomaticHeight, default: Defaults.maximumAutomaticHeight, defaults: defaults)
        horizontalInset = Self.value(forKey: Key.horizontalInset, default: Defaults.horizontalInset, defaults: defaults)
        verticalInset = Self.value(forKey: Key.verticalInset, default: Defaults.verticalInset, defaults: defaults)
        dragHandleHeight = Self.value(forKey: Key.dragHandleHeight, default: Defaults.dragHandleHeight, defaults: defaults)
        listIndent = Self.value(forKey: Key.listIndent, default: Defaults.listIndent, defaults: defaults)
        quoteIndent = Self.value(forKey: Key.quoteIndent, default: Defaults.quoteIndent, defaults: defaults)
        translucentAlpha = Self.value(forKey: Key.translucentAlpha, default: Defaults.translucentAlpha, defaults: defaults)
        windowShadowEnabled = defaults.object(forKey: Key.windowShadowEnabled) as? Bool ?? Defaults.windowShadowEnabled
    }

    func resetToDefaults() {
        textColor = Defaults.textColor
        strokeColor = Defaults.strokeColor
        strokeWidth = Defaults.strokeWidth
        windowEdgeStrokeColor = Defaults.windowEdgeStrokeColor
        windowEdgeStrokeWidth = Defaults.windowEdgeStrokeWidth
        windowEdgeStrokeOpacity = Defaults.windowEdgeStrokeOpacity
        bodyFontSize = Defaults.bodyFontSize
        heading1FontSize = Defaults.heading1FontSize
        heading2FontSize = Defaults.heading2FontSize
        heading3FontSize = Defaults.heading3FontSize
        codeFontSize = Defaults.codeFontSize
        paragraphSpacing = Defaults.paragraphSpacing
        heading1Spacing = Defaults.heading1Spacing
        heading2Spacing = Defaults.heading2Spacing
        heading3Spacing = Defaults.heading3Spacing
        codeBlockSpacing = Defaults.codeBlockSpacing
        windowWidth = Defaults.windowWidth
        minimumHeight = Defaults.minimumHeight
        maximumAutomaticHeight = Defaults.maximumAutomaticHeight
        horizontalInset = Defaults.horizontalInset
        verticalInset = Defaults.verticalInset
        dragHandleHeight = Defaults.dragHandleHeight
        listIndent = Defaults.listIndent
        quoteIndent = Defaults.quoteIndent
        translucentAlpha = Defaults.translucentAlpha
        windowShadowEnabled = Defaults.windowShadowEnabled
    }

    private func save(_ value: CGFloat, key: String) {
        defaults.set(Double(value), forKey: key)
    }

    private func saveColor(_ color: NSColor, key: String) {
        defaults.set(Self.hexString(from: color), forKey: key)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .memoDolmaengPreferencesChanged, object: self)
    }

    private static func value(forKey key: String, default defaultValue: CGFloat, defaults: UserDefaults) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return CGFloat(defaults.double(forKey: key))
    }

    private static func color(forKey key: String, default defaultValue: NSColor, defaults: UserDefaults) -> NSColor {
        guard let hex = defaults.string(forKey: key),
              let color = color(from: hex)
        else {
            return defaultValue
        }

        return color
    }

    private static func color(from hex: String) -> NSColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 8,
              let value = UInt32(cleaned, radix: 16)
        else {
            return nil
        }

        let red = CGFloat((value >> 24) & 0xFF) / 255
        let green = CGFloat((value >> 16) & 0xFF) / 255
        let blue = CGFloat((value >> 8) & 0xFF) / 255
        let alpha = CGFloat(value & 0xFF) / 255
        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hexString(from color: NSColor) -> String {
        let color = color.usingColorSpace(.sRGB) ?? color
        let red = UInt8(round(max(0, min(1, color.redComponent)) * 255))
        let green = UInt8(round(max(0, min(1, color.greenComponent)) * 255))
        let blue = UInt8(round(max(0, min(1, color.blueComponent)) * 255))
        let alpha = UInt8(round(max(0, min(1, color.alphaComponent)) * 255))
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    private enum Key {
        static let textColor = "preferences.textColor"
        static let strokeColor = "preferences.strokeColor"
        static let strokeWidth = "preferences.strokeWidth"
        static let windowEdgeStrokeColor = "preferences.windowEdgeStrokeColor"
        static let windowEdgeStrokeWidth = "preferences.windowEdgeStrokeWidth"
        static let windowEdgeStrokeOpacity = "preferences.windowEdgeStrokeOpacity"
        static let bodyFontSize = "preferences.bodyFontSize"
        static let heading1FontSize = "preferences.heading1FontSize"
        static let heading2FontSize = "preferences.heading2FontSize"
        static let heading3FontSize = "preferences.heading3FontSize"
        static let codeFontSize = "preferences.codeFontSize"
        static let paragraphSpacing = "preferences.paragraphSpacing"
        static let heading1Spacing = "preferences.heading1Spacing"
        static let heading2Spacing = "preferences.heading2Spacing"
        static let heading3Spacing = "preferences.heading3Spacing"
        static let codeBlockSpacing = "preferences.codeBlockSpacing"
        static let windowWidth = "preferences.windowWidth"
        static let minimumHeight = "preferences.minimumHeight"
        static let maximumAutomaticHeight = "preferences.maximumAutomaticHeight"
        static let horizontalInset = "preferences.horizontalInset"
        static let verticalInset = "preferences.verticalInset"
        static let dragHandleHeight = "preferences.dragHandleHeight"
        static let listIndent = "preferences.listIndent"
        static let quoteIndent = "preferences.quoteIndent"
        static let translucentAlpha = "preferences.translucentAlpha"
        static let windowShadowEnabled = "preferences.windowShadowEnabled"
    }

    private enum Defaults {
        static let textColor = NSColor.white
        static let strokeColor = NSColor.black
        static let strokeWidth: CGFloat = 0.3
        static let windowEdgeStrokeColor = NSColor.black
        static let windowEdgeStrokeWidth: CGFloat = 0.5
        static let windowEdgeStrokeOpacity: CGFloat = 0.22
        static let bodyFontSize: CGFloat = 12
        static let heading1FontSize: CGFloat = 19
        static let heading2FontSize: CGFloat = 16.5
        static let heading3FontSize: CGFloat = 14
        static let codeFontSize: CGFloat = 12
        static let paragraphSpacing: CGFloat = 2
        static let heading1Spacing: CGFloat = 4
        static let heading2Spacing: CGFloat = 3
        static let heading3Spacing: CGFloat = 2.5
        static let codeBlockSpacing: CGFloat = 3
        static let windowWidth: CGFloat = 300
        static let minimumHeight: CGFloat = 48
        static let maximumAutomaticHeight: CGFloat = 560
        static let horizontalInset: CGFloat = 12
        static let verticalInset: CGFloat = 10
        static let dragHandleHeight: CGFloat = 10
        static let listIndent: CGFloat = 15
        static let quoteIndent: CGFloat = 10
        static let translucentAlpha: CGFloat = 0.72
        static let windowShadowEnabled = true
    }
}
