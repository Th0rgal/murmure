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

    /// Put the clipboard back after pasting.
    static var restoreClipboard: Bool {
        get { d.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreClipboard") }
    }
}
