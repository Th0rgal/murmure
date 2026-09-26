import Foundation

/// One physical modifier key. Left and right are distinct, so a shortcut
/// like Fn + Right Shift never fires on the left Shift.
public enum Modifier: String, Codable, CaseIterable, Sendable {
    case fn, leftControl, rightControl, leftOption, rightOption, leftShift, rightShift, leftCommand, rightCommand

    public var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .leftShift: 56
        case .rightShift: 60
        case .leftControl: 59
        case .rightControl: 62
        case .leftOption: 58
        case .rightOption: 61
        case .leftCommand: 55
        case .rightCommand: 54
        }
    }

    /// Device-dependent bits of CGEventFlags / NSEvent.ModifierFlags
    /// (NX_DEVICE*KEYMASK); fn uses the secondary-fn flag.
    var mask: UInt64 {
        switch self {
        case .fn: 0x80_0000
        case .leftControl: 0x01
        case .leftShift: 0x02
        case .rightShift: 0x04
        case .leftCommand: 0x08
        case .rightCommand: 0x10
        case .leftOption: 0x20
        case .rightOption: 0x40
        case .rightControl: 0x2000
        }
    }

    public var label: String {
        switch self {
        case .fn: "Fn"
        case .leftControl: "⌃ gauche"
        case .rightControl: "⌃ droit"
        case .leftOption: "⌥ gauche"
        case .rightOption: "⌥ droit"
        case .leftShift: "⇧ gauche"
        case .rightShift: "⇧ droit"
        case .leftCommand: "⌘ gauche"
        case .rightCommand: "⌘ droit"
        }
    }

    /// Modifiers held according to raw event flags.
    public static func held(in rawFlags: UInt64) -> Set<Modifier> {
        Set(allCases.filter { rawFlags & $0.mask != 0 })
    }
}

/// A global shortcut: either modifiers alone (Fn + ⇧ droit) or modifiers
/// plus one key (⌥ + Espace, F5…).
public struct Shortcut: Codable, Equatable, Sendable {
    public var modifiers: Set<Modifier>
    public var keyCode: UInt16?
    public var keyLabel: String?

    public init(modifiers: Set<Modifier>, keyCode: UInt16? = nil, keyLabel: String? = nil) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }

    public static let `default` = Shortcut(modifiers: [.fn, .rightShift])

    public var label: String {
        let mods = Modifier.allCases.filter(modifiers.contains).map(\.label)
        return (mods + [keyLabel].compactMap { $0 }).joined(separator: " + ")
    }

    public var usesFn: Bool { modifiers.contains(.fn) }

    /// Modifier-only shortcuts match the exact set held, so Fn + ⇧ droit
    /// does not fire while ⌘ is also down (⌘⇧… shortcuts stay usable).
    public func modifiersMatch(_ held: Set<Modifier>) -> Bool {
        held == modifiers
    }

    /// For a key shortcut: the key went down with exactly our modifiers.
    /// Fn is ignored unless required, because macOS sets it on arrow and
    /// function keys.
    public func keyMatches(_ code: UInt16, held: Set<Modifier>) -> Bool {
        guard let keyCode, code == keyCode else { return false }
        var h = held
        if !usesFn { h.remove(.fn) }
        return h == modifiers
    }

    /// Function keys that are acceptable without any modifier.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Reject shortcuts that would fire while typing (a bare letter) or that
    /// are empty.
    public var isValid: Bool {
        if let keyCode {
            return !modifiers.isEmpty || Self.functionKeys.contains(keyCode)
        }
        return !modifiers.isEmpty
    }
}

/// Captures a shortcut from raw key events, for the settings recorder.
/// Modifier-only shortcuts are committed once every key is released, using
/// the largest set held; a regular key commits immediately.
public struct ShortcutCapture {
    public private(set) var peak: Set<Modifier> = []
    public init() {}

    public mutating func flagsChanged(_ held: Set<Modifier>) -> Shortcut? {
        peak.formUnion(held)
        guard held.isEmpty, !peak.isEmpty else { return nil }
        defer { peak = [] }
        return Shortcut(modifiers: peak)
    }

    public mutating func keyDown(_ code: UInt16, label: String, held: Set<Modifier>) -> Shortcut? {
        var h = held
        // macOS sets the fn flag by itself on function and arrow keys.
        if Shortcut.functionKeys.contains(code) || (123 ... 126).contains(code) { h.remove(.fn) }
        peak = []
        let s = Shortcut(modifiers: h, keyCode: code, keyLabel: label)
        return s.isValid ? s : nil
    }
}
