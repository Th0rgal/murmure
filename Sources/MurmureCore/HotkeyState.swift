import Foundation

/// Fn + Right Shift chord logic, independent of CGEventTap so it is testable.
///
/// - Tap the chord: start recording; tap it again: stop and transcribe.
/// - Hold the chord longer than `holdThreshold`: push-to-talk, releasing
///   stops and transcribes.
public struct HotkeyState {
    public enum Action: Equatable { case start, commit }

    public var holdThreshold: TimeInterval
    public private(set) var fnDown = false
    public private(set) var rightShiftDown = false
    public private(set) var recording = false
    private var chordDown = false
    private var startedAt: TimeInterval?

    public init(holdThreshold: TimeInterval = 0.35) { self.holdThreshold = holdThreshold }

    /// Feed one modifier change; returns what to do, if anything.
    public mutating func update(fn: Bool? = nil, rightShift: Bool? = nil, at t: TimeInterval) -> Action? {
        if let fn { fnDown = fn }
        if let rightShift { rightShiftDown = rightShift }
        let now = fnDown && rightShiftDown
        defer { chordDown = now }
        if now && !chordDown {
            if recording {
                recording = false
                startedAt = nil
                return .commit
            }
            recording = true
            startedAt = t
            return .start
        }
        if !now && chordDown, recording, let s = startedAt {
            startedAt = nil  // later releases never commit: toggle mode
            if t - s >= holdThreshold {
                recording = false
                return .commit
            }
        }
        return nil
    }

    /// The session ended some other way (button, Esc, Return, error).
    public mutating func reset() {
        recording = false
        startedAt = nil
    }
}
