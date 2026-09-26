import AppKit
import CoreGraphics
import MurmureCore

/// Global Fn + Right Shift chord through a CGEventTap. While the overlay is
/// up it also consumes Esc (cancel) and Return (commit).
final class HotkeyMonitor {
    var onAction: ((HotkeyState.Action) -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Set by the controller: swallow Esc / Return only while a session is live.
    var captureEscape = false
    var captureReturn = false

    private(set) var state = HotkeyState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let fnKey: Int64 = 63
    private static let rightShiftKey: Int64 = 60
    private static let rightShiftMask: UInt64 = 0x04  // NX_DEVICERSHIFTKEYMASK
    private static let esc: Int64 = 53
    private static let returnKeys: Set<Int64> = [36, 76]

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let t = ProcessInfo.processInfo.systemUptime
            var action: HotkeyState.Action?
            if code == Self.fnKey {
                action = state.update(fn: flags.contains(.maskSecondaryFn), at: t)
            } else if code == Self.rightShiftKey {
                action = state.update(rightShift: flags.rawValue & Self.rightShiftMask != 0, at: t)
            } else if !flags.contains(.maskSecondaryFn) || flags.rawValue & Self.rightShiftMask == 0 {
                // Resync after missed events (e.g. keys released during a secure input field).
                action = state.update(fn: flags.contains(.maskSecondaryFn), rightShift: flags.rawValue & Self.rightShiftMask != 0, at: t)
            }
            if let action { DispatchQueue.main.async { self.onAction?(action) } }
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.esc, captureEscape {
                DispatchQueue.main.async { self.onEscape?() }
                return nil
            }
            if captureReturn, Self.returnKeys.contains(code), event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
                DispatchQueue.main.async { self.onReturn?() }
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
