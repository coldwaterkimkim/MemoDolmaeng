import AppKit
import QuartzCore

enum EdgeMotionCurve {
    case reveal
    case hide
    case easeOut
}

/// One accessibility-aware motion contract for every edge surface.
///
/// Geometry changes are intentionally immediate when Reduce Motion is enabled.
/// A short fade may still communicate appearance/disappearance without moving a
/// surface across the screen or scaling it between the index and ICE frames.
struct EdgeMotionPolicy {
    let reduceMotion: Bool
    let increaseContrast: Bool
    let reduceTransparency: Bool

    static var current: EdgeMotionPolicy {
        let workspace = NSWorkspace.shared
        return EdgeMotionPolicy(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
    }

    var animatesGeometry: Bool { !reduceMotion }

    func geometryDuration(_ regularDuration: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : regularDuration
    }

    func fadeDuration(_ regularDuration: TimeInterval) -> TimeInterval {
        reduceMotion ? min(0.08, regularDuration) : regularDuration
    }

    func timingFunction(_ curve: EdgeMotionCurve) -> CAMediaTimingFunction {
        switch curve {
        case .reveal:
            CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        case .hide:
            CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        case .easeOut:
            CAMediaTimingFunction(name: .easeOut)
        }
    }
}
