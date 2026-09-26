import AppKit
import CoreGraphics
import MurmureCore

/// Global dictation shortcut through a CGEventTap. While a session is live
/// it also consumes Esc (cancel) and Return (commit).
final class HotkeyMonitor {
    var onAction: ((HotkeyState.Action) -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Set by the controller: swallow Esc / Return only while a session is live.
    var captureEscape = false
    var captureReturn = false
    /// Paused while the settings window records a new shortcut.
    var paused = false

    var shortcut: Shortcut {
        didSet { state.reset(); keyHeld = false }
    }

    private var state = HotkeyState()
    private var keyHeld = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let esc: Int64 = 53
    private static let returnKeys: Set<Int64> = [36, 76]

    init(shortcut: Shortcut) { self.shortcut = shortcut }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            }, userInfo: refcon)
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func resetChord() { state.reset() }

    private func feed(_ pressed: Bool) {
        if let action = state.update(pressed: pressed, at: ProcessInfo.processInfo.systemUptime) {
            DispatchQueue.main.async { self.onAction?(action) }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if paused { return pass }
        let held = Modifier.held(in: event.flags.rawValue)
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged where shortcut.keyCode == nil:
            feed(shortcut.modifiersMatch(held))
        case .keyDown:
            if shortcut.keyMatches(code, held: held) || (keyHeld && code == shortcut.keyCode) {
                if !keyHeld { keyHeld = true; feed(true) }
                return nil  // ours, including auto-repeat
            }
            if code == Self.esc, captureEscape {
                DispatchQueue.main.async { self.onEscape?() }
                return nil
            }
            if captureReturn, Self.returnKeys.contains(Int64(code)), held.subtracting([.fn]).isEmpty {
                DispatchQueue.main.async { self.onReturn?() }
                return nil
            }
        case .keyUp where keyHeld && code == shortcut.keyCode:
            keyHeld = false
            feed(false)
            return nil
        default:
            break
        }
        return pass
    }
}
