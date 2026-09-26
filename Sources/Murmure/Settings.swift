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

    /// Put the clipboard back after pasting.
    static var restoreClipboard: Bool {
        get { d.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreClipboard") }
    }
}
