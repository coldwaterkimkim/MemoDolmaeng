import CoreGraphics

enum NoteWindowMetrics {
    static var automaticWidth: CGFloat { AppPreferences.shared.windowWidth }
    static var minimumAutomaticHeight: CGFloat { max(AppPreferences.shared.minimumHeight, 48) }
    static var maximumAutomaticHeight: CGFloat { AppPreferences.shared.maximumAutomaticHeight }
    static var contentHorizontalInset: CGFloat { AppPreferences.shared.horizontalInset }
    static var contentVerticalInset: CGFloat { AppPreferences.shared.verticalInset }
    static var dragHandleHeight: CGFloat { AppPreferences.shared.dragHandleHeight }
}
