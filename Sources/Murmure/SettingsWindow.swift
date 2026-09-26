import AppKit
import AVFoundation
import MurmureCore
import ServiceManagement
import SwiftUI

/// State shown in the settings window; writes go straight to `Settings`.
final class Preferences: ObservableObject {
    @Published var shortcut = Settings.shortcut {
        didSet { Settings.shortcut = shortcut; onShortcutChange(shortcut) }
    }
    @Published var language = Settings.language {
        didSet { Settings.language = language; onLanguageChange(language) }
    }
    @Published var liveChunks = Settings.liveChunks { didSet { Settings.liveChunks = liveChunks } }
    @Published var restoreClipboard = Settings.restoreClipboard { didSet { Settings.restoreClipboard = restoreClipboard } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var accessibility = AXIsProcessTrusted()
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var engine = "…"
    @Published var recordingShortcut = false {
        didSet { onRecordingShortcut(recordingShortcut) }
    }

    var onShortcutChange: (Shortcut) -> Void = { _ in }
    var onLanguageChange: (Language) -> Void = { _ in }
    var onRecordingShortcut: (Bool) -> Void = { _ in }
    var onPrewarm: () -> Void = {}
    var engineStatus: () -> String = { "" }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if Settings.language != language { language = Settings.language }
        let probe = engineStatus
        DispatchQueue.global(qos: .utility).async {
            let s = probe()
            DispatchQueue.main.async { self.engine = s }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.1)))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Murmure").font(.title2.weight(.semibold))
                    Text("Dictée locale. L'audio ne quitte pas ce Mac.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)

            Form {
                Section {
                    LabeledContent("Raccourci") {
                        ShortcutField(prefs: prefs)
                    }
                    Text("Un appui : démarre, un second : transcrit et colle. Maintenu : parle, relâche pour coller. Esc annule, Entrée valide.")
                        .font(.caption).foregroundStyle(.secondary)
                    if prefs.shortcut.usesFn {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Règle « Appuyer sur 🌐 pour » sur « Ne rien faire », sinon Fn ouvre aussi les emojis ou la dictée Apple.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Clavier…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Section {
                    Picker("Langue", selection: $prefs.language) {
                        ForEach(Language.all, id: \.self) { l in Text(l.name).tag(l) }
                    }
                    Text("Le modèle ne détecte pas la langue. Tu peux aussi la changer pendant la dictée avec la pastille.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Autorisations") {
                    PermissionRow(
                        title: "Accessibilité", detail: "Raccourci global et collage du texte",
                        granted: prefs.accessibility, action: "Ouvrir les réglages"
                    ) {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    PermissionRow(
                        title: "Micro", detail: "Enregistrer ta voix",
                        granted: prefs.microphone == .authorized,
                        action: prefs.microphone == .notDetermined ? "Autoriser" : "Ouvrir les réglages"
                    ) {
                        if prefs.microphone == .notDetermined {
                            Recorder.requestPermission { _ in prefs.refresh() }
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                }

                Section("Options") {
                    Toggle("Transcrire pendant que je parle", isOn: $prefs.liveChunks)
                    Toggle("Restaurer le presse-papiers après le collage", isOn: $prefs.restoreClipboard)
                    Toggle("Lancer au démarrage", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                }

                Section("Moteur") {
                    LabeledContent("Cohere Transcribe (MLX)") {
                        HStack {
                            Text(prefs.engine).foregroundStyle(.secondary)
                            Button("Précharger") { prefs.onPrewarm() }.controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)

            HStack {
                Spacer()
                Button("Terminé", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Autorisé").foregroundStyle(.secondary)
            } else {
                Button(action, action: perform)
            }
        }
    }
}

/// Click, then press the new shortcut. Modifiers alone (e.g. Fn + ⇧ droit)
/// are saved when released; a key with modifiers is saved on press.
struct ShortcutField: View {
    @ObservedObject var prefs: Preferences
    @State private var monitor: Any?
    @State private var capture = ShortcutCapture()
    @State private var preview = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                prefs.recordingShortcut ? stop() : start()
            } label: {
                Text(prefs.recordingShortcut ? (preview.isEmpty ? "Appuie sur ton raccourci…" : preview) : prefs.shortcut.label)
                    .frame(minWidth: 170)
                    .foregroundStyle(prefs.recordingShortcut ? Color.accentColor : .primary)
            }
            if prefs.shortcut != .default && !prefs.recordingShortcut {
                Button {
                    prefs.shortcut = .default
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Revenir à Fn + ⇧ droit")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        capture = ShortcutCapture()
        preview = ""
        prefs.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            let held = Modifier.held(in: UInt64(e.modifierFlags.rawValue))
            if e.type == .flagsChanged {
                preview = Shortcut(modifiers: capture.peak.union(held)).label
                if let s = capture.flagsChanged(held) { finish(s) }
                return nil
            }
            if e.keyCode == 53, held.isEmpty {  // Esc alone cancels
                stop()
                return nil
            }
            let label = Self.keyLabel(e)
            if let s = capture.keyDown(e.keyCode, label: label, held: held) { finish(s) } else { NSSound.beep() }
            return nil
        }
    }

    private func finish(_ s: Shortcut) {
        if s.isValid { prefs.shortcut = s } else { NSSound.beep() }
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if prefs.recordingShortcut { prefs.recordingShortcut = false }
    }

    static func keyLabel(_ e: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Espace", 36: "Entrée", 48: "Tab", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        if let n = named[e.keyCode] { return n }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Plain window hosting SettingsView; the app stays a menu bar accessory.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let prefs: Preferences
    private var timer: Timer?

    init(prefs: Preferences) {
        self.prefs = prefs
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Réglages de Murmure"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(prefs: prefs) { [weak window] in window?.close() })
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    func show() {
        prefs.refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Permissions change in System Settings while we are open.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.prefs.refresh() }
    }

    func windowWillClose(_: Notification) {
        timer?.invalidate()
        timer = nil
        prefs.recordingShortcut = false
    }
}
