import Foundation

/// Tap / hold logic for the dictation shortcut, independent of the event
/// source so it is testable.
///
/// - Tap the shortcut: start recording; tap it again: stop and transcribe.
/// - Hold it longer than `holdThreshold`: push-to-talk, releasing stops and
///   transcribes.
public struct HotkeyState {
    public enum Action: Equatable { case start, commit }

    public var holdThreshold: TimeInterval
    public private(set) var recording = false
    private var down = false
    private var startedAt: TimeInterval?

    public init(holdThreshold: TimeInterval = 0.35) { self.holdThreshold = holdThreshold }

    /// Feed whether the shortcut is currently pressed; returns what to do.
    public mutating func update(pressed: Bool, at t: TimeInterval) -> Action? {
        defer { down = pressed }
        if pressed && !down {
            if recording {
                recording = false
                startedAt = nil
                return .commit
            }
            recording = true
            startedAt = t
            return .start
        }
        if !pressed && down, recording, let s = startedAt {
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
