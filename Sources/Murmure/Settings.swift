import Foundation
import MurmureCore

enum Settings {
    private static let d = UserDefaults.standard

    static var language: Language {
        get { d.string(forKey: "language").flatMap(Language.named) ?? Language.systemDefault(Locale.preferredLanguages) }
        set { d.set(newValue.code, forKey: "language") }
    }

    /// Transcribe finished sentences while the user is still speaking.
    static var liveChunks: Bool {
        get { d.object(forKey: "liveChunks") as? Bool ?? true }
        set { d.set(newValue, forKey: "liveChunks") }
    }

    static var shortcut: Shortcut {
        get { d.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    /// The settings window has been shown once (first-launch onboarding).
    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    /// "Open at login" has been turned on once by default; after that the
    /// user's choice in Settings wins.
    static var loginDefaultApplied: Bool {
        get { d.bool(forKey: "loginDefaultApplied") }
        set { d.set(newValue, forKey: "loginDefaultApplied") }
    }

    /// Put the clipboard back after pasting.
    static var restoreClipboard: Bool {
        get { d.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreClipboard") }
    }

    /// Keep recording for this many milliseconds after push-to-talk key release so the last word is not clipped.
    static var releaseTailMs: Double {
        get { d.object(forKey: "releaseTailMs") as? Double ?? 250 }
        set { d.set(newValue, forKey: "releaseTailMs") }
    }

    /// Seconds of pre-buffered audio kept while the microphone stays warm.
    static var prebufferSecs: Double {
        get { d.object(forKey: "prebufferSecs") as? Double ?? 0.8 }
        set { d.set(newValue, forKey: "prebufferSecs") }
    }

    /// Minutes to keep the microphone stream open in the background after a dictation so the next start has 0ms spin-up latency.
    static var keepWarmMinutes: Double {
        get { d.object(forKey: "keepWarmMinutes") as? Double ?? 5.0 }
        set { d.set(newValue, forKey: "keepWarmMinutes") }
    }

    /// Auto-commit toggle dictation after this many seconds of silence once speech has occurred (0 = off).
    static var autoStopSilenceSecs: Double {
        get { d.object(forKey: "autoStopSilenceSecs") as? Double ?? 5.0 }
        set { d.set(newValue, forKey: "autoStopSilenceSecs") }
    }

    /// Auto-stop toggle dictation if no speech is detected for this many seconds (0 = off).
    static var autoStopNoSpeechSecs: Double {
        get { d.object(forKey: "autoStopNoSpeechSecs") as? Double ?? 20.0 }
        set { d.set(newValue, forKey: "autoStopNoSpeechSecs") }
    }

    /// Strip filler words ("um", "uh", "euh") and immediate stutters.
    static var removeDisfluencies: Bool {
        get { d.object(forKey: "removeDisfluencies") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeDisfluencies") }
    }

    /// Interpret spoken editing/formatting commands ("new line", "new paragraph", "scratch that").
    static var voiceCommands: Bool {
        get { d.object(forKey: "voiceCommands") as? Bool ?? false }
        set { d.set(newValue, forKey: "voiceCommands") }
    }

    /// Convert compound spoken numbers ("twenty five" → "25").
    static var convertNumbers: Bool {
        get { d.object(forKey: "convertNumbers") as? Bool ?? false }
        set { d.set(newValue, forKey: "convertNumbers") }
    }

    /// Insert completed chunks into the active app as they finish while speaking.
    static var streamInline: Bool {
        get { d.object(forKey: "streamInline") as? Bool ?? false }
        set { d.set(newValue, forKey: "streamInline") }
    }
}
