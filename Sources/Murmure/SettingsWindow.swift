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
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var accessibility = AXIsProcessTrusted()
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var recordingShortcut = false {
        didSet { onRecordingShortcut(recordingShortcut) }
    }

    var onShortcutChange: (Shortcut) -> Void = { _ in }
    var onLanguageChange: (Language) -> Void = { _ in }
    var onRecordingShortcut: (Bool) -> Void = { _ in }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if Settings.language != language { language = Settings.language }
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(white: 0.1)))
                Text("Murmure").font(.title3.weight(.semibold))
                Text("Private, on-device dictation").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 22)
            .padding(.bottom, 6)

            Form {
                Section {
                    LabeledContent("Shortcut") { ShortcutField(prefs: prefs) }
                    Picker("Language", selection: $prefs.language) {
                        ForEach(Language.all, id: \.self) { l in Text(l.name).tag(l) }
                    }
                    Toggle("Open at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                } footer: {
                    Text("Tap to start and stop, or hold to talk. Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !prefs.accessibility || prefs.microphone != .authorized {
                    Section("Permissions") {
                        if !prefs.accessibility {
                            PermissionRow(title: "Accessibility", detail: "Global shortcut and pasting") {
                                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                                AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                        if prefs.microphone != .authorized {
                            PermissionRow(title: "Microphone", detail: "Recording your voice") {
                                if prefs.microphone == .notDetermined {
                                    Recorder.requestPermission { _ in prefs.refresh() }
                                } else {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.bottom, 6)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let grant: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant", action: grant)
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
                Text(prefs.recordingShortcut ? (preview.isEmpty ? "Press shortcut…" : preview) : prefs.shortcut.label)
                    .frame(minWidth: 130)
                    .foregroundStyle(prefs.recordingShortcut ? Color.accentColor : .primary)
            }
            if prefs.shortcut != .default && !prefs.recordingShortcut {
                Button {
                    prefs.shortcut = .default
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to Fn + Right ⇧")
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
            49: "Space", 36: "Return", 48: "Tab", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
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
        window.title = "Murmure"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(prefs: prefs))
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
