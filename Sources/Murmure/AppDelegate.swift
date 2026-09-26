import AppKit
import ApplicationServices
import MurmureCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor(shortcut: Settings.shortcut)
    private let dictation = Dictation()
    private let prefs = Preferences()
    private lazy var settings = SettingsWindowController(prefs: prefs)
    private var status: NSStatusItem!
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmure")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        dictation.onStateChange = { [weak self] state in
            guard let self else { return }
            self.hotkey.captureEscape = state != .idle
            self.hotkey.captureReturn = state == .recording
            if state == .idle { self.hotkey.resetChord() }
            self.status.button?.image = NSImage(
                systemSymbolName: state == .recording ? "waveform.circle.fill" : "waveform",
                accessibilityDescription: "Murmure")
        }
        hotkey.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .start: self.dictation.start()
            case .commit: self.dictation.commit()
            }
        }
        hotkey.onEscape = { [weak self] in self?.dictation.cancel() }
        hotkey.onReturn = { [weak self] in self?.dictation.commit() }

        prefs.onShortcutChange = { [weak self] s in self?.hotkey.shortcut = s }
        prefs.onRecordingShortcut = { [weak self] on in self?.hotkey.paused = on }
        prefs.onLanguageChange = { [weak self] l in self?.dictation.setLanguage(l) }

        // Open at login by default (only from /Applications, never from a dev build).
        if !Settings.loginDefaultApplied, Bundle.main.bundlePath.hasPrefix("/Applications/") {
            Settings.loginDefaultApplied = true
            try? SMAppService.mainApp.register()
        }

        if Settings.onboarded {
            startHotkey(prompt: false)
            if !AXIsProcessTrusted() { showSettings() }
        } else {
            // First launch: show the settings (shortcut, language, permissions).
            Settings.onboarded = true
            showSettings()
            startHotkey(prompt: false)
        }
    }

    /// Launching the app again (Finder, Spotlight, Raycast) opens the settings.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc func showSettings() {
        settings.show()
    }

    /// The event tap needs Accessibility; poll until it is granted.
    private func startHotkey(prompt: Bool) {
        if !AXIsProcessTrusted(), prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if AXIsProcessTrusted(), hotkey.start() {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.startHotkey(prompt: false)
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if hotkey.isRunning {
            menu.addItem(withTitle: "Dictate (\(hotkey.shortcut.label))", action: #selector(dictateNow), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Allow Accessibility…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in Language.all {
            let i = NSMenuItem(title: l.name, action: #selector(Dictation.pickLanguage(_:)), keyEquivalent: "")
            i.target = dictation
            i.representedObject = l.code
            i.state = l.code == Settings.language.code ? .on : .off
            sub.addItem(i)
        }
        langItem.submenu = sub
        menu.addItem(langItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Murmure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openAccessibility() {
        startHotkey(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func dictateNow() { dictation.toggle() }

}
