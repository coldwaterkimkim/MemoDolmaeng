import AppKit
import Combine

final class EdgePreferences: ObservableObject {
    static let shared = EdgePreferences()
    private static let hideDelayMigrationVersion = 2

    @Published var defaultEdge: EdgeDock {
        didSet { defaults.set(defaultEdge.rawValue, forKey: Key.defaultEdge); notifyChanged() }
    }

    @Published var targetDisplayID: UInt32? {
        didSet {
            if let targetDisplayID {
                defaults.set(Int(targetDisplayID), forKey: Key.targetDisplayID)
            } else {
                defaults.removeObject(forKey: Key.targetDisplayID)
            }
            notifyChanged()
        }
    }

    @Published var defaultAspectRawValue: String {
        didSet { defaults.set(defaultAspectRawValue, forKey: Key.defaultAspect); notifyChanged() }
    }

    @Published var defaultOpacity: Double {
        didSet { defaults.set(defaultOpacity, forKey: Key.defaultOpacity); notifyChanged() }
    }

    @Published var revealDelay: Double {
        didSet { defaults.set(revealDelay, forKey: Key.revealDelay); notifyChanged() }
    }

    @Published var hideDelay: Double {
        didSet { defaults.set(hideDelay, forKey: Key.hideDelay); notifyChanged() }
    }

    var lastNoteID: UUID? {
        get { defaults.string(forKey: Key.lastNoteID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.lastNoteID) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEdge = defaults.string(forKey: Key.defaultEdge)
            ?? defaults.string(forKey: Key.legacySide)
        let resolvedEdge = (EdgeDock(rawValue: storedEdge ?? "") ?? .right).interactiveSide
        defaultEdge = resolvedEdge
        defaults.set(resolvedEdge.rawValue, forKey: Key.defaultEdge)
        if defaults.object(forKey: Key.targetDisplayID) != nil {
            targetDisplayID = UInt32(defaults.integer(forKey: Key.targetDisplayID))
        } else {
            targetDisplayID = nil
        }
        defaultAspectRawValue = defaults.string(forKey: Key.defaultAspect) ?? "square"
        defaultOpacity = defaults.object(forKey: Key.defaultOpacity) == nil
            ? 1
            : max(0.4, min(1, defaults.double(forKey: Key.defaultOpacity)))
        revealDelay = defaults.object(forKey: Key.revealDelay) == nil
            ? 0.18
            : max(0, min(1, defaults.double(forKey: Key.revealDelay)))
        if defaults.integer(forKey: Key.hideDelayMigrationVersion) < Self.hideDelayMigrationVersion {
            hideDelay = 2
            defaults.set(hideDelay, forKey: Key.hideDelay)
            defaults.set(Self.hideDelayMigrationVersion, forKey: Key.hideDelayMigrationVersion)
        } else {
            hideDelay = defaults.object(forKey: Key.hideDelay) == nil
                ? 2
                : max(0.05, min(10, defaults.double(forKey: Key.hideDelay)))
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .memoDolmaengEdgePreferencesChanged, object: self)
    }

    private enum Key {
        static let defaultEdge = "edge.defaultDock"
        static let legacySide = "edge.side"
        static let targetDisplayID = "edge.targetDisplayID"
        static let defaultAspect = "edge.defaultAspect"
        static let defaultOpacity = "edge.defaultOpacity"
        static let revealDelay = "edge.revealDelay"
        static let hideDelay = "edge.hideDelay"
        static let hideDelayMigrationVersion = "edge.hideDelayMigrationVersion"
        static let lastNoteID = "edge.lastNoteID"
    }
}

extension NSScreen {
    var memoDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
