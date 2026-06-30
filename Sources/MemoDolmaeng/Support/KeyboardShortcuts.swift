import AppKit

enum KeyboardShortcuts {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    enum KeyCode {
        static let a: UInt16 = 0
        static let f: UInt16 = 3
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let b: UInt16 = 11
        static let q: UInt16 = 12
        static let w: UInt16 = 13
        static let e: UInt16 = 14
        static let t: UInt16 = 17
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20
        static let seven: UInt16 = 26
        static let eight: UInt16 = 28
        static let zero: UInt16 = 29
        static let i: UInt16 = 34
        static let k: UInt16 = 40
        static let n: UInt16 = 45
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
    }

    static func normalizedModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(relevantModifiers)
    }
}
