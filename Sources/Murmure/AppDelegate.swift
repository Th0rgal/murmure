import AppKit
import ApplicationServices
import MurmureCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let dictation = Dictation()
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

        startHotkey(prompt: true)
        Recorder.requestPermission { _ in }
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
        menu.addItem(withTitle: hotkey.isRunning ? "Fn + ⇧ droit pour dicter" : "⚠︎ Autoriser l'Accessibilité…",
                     action: hotkey.isRunning ? nil : #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Dicter maintenant", action: #selector(dictateNow), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let langItem = NSMenuItem(title: "Langue : \(Settings.language.name)", action: nil, keyEquivalent: "")
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

        let live = menu.addItem(withTitle: "Transcrire pendant que je parle", action: #selector(toggleLive), keyEquivalent: "")
        live.target = self
        live.state = Settings.liveChunks ? .on : .off
        let clip = menu.addItem(withTitle: "Restaurer le presse-papiers", action: #selector(toggleClipboard), keyEquivalent: "")
        clip.target = self
        clip.state = Settings.restoreClipboard ? .on : .off
        let login = menu.addItem(withTitle: "Lancer au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: daemonStatus(), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Précharger le modèle", action: #selector(prewarm), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Murmure", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func daemonStatus() -> String {
        // Cheap probe on a separate connection so it never waits behind inference.
        let probe = VoiceClient()
        defer { probe.close() }
        guard let s = try? probe.request("status", timeout: 0.5) else { return "voiced : occupé ou absent" }
        let loaded = s["loaded"] as? Bool == true
        let mem = (s["active_memory_bytes"] as? Double).map { String(format: " · %.2f GB", $0 / 1e9) } ?? ""
        return "voiced : " + (loaded ? "modèle chargé\(mem)" : "en veille")
    }

    @objc private func openAccessibility() {
        startHotkey(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func dictateNow() { dictation.toggle() }
    @objc private func prewarm() { dictation.prewarm() }
    @objc private func toggleLive() { Settings.liveChunks.toggle() }
    @objc private func toggleClipboard() { Settings.restoreClipboard.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }
}
