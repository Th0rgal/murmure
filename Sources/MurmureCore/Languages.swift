/// Languages the pinned Cohere Transcribe checkpoint accepts. It does not
/// auto-detect: every request names one.
public struct Language: Hashable, Sendable {
    public let code: String
    public let name: String

    public static let all: [Language] = [
        .init(code: "fr", name: "Français"), .init(code: "en", name: "English"),
        .init(code: "de", name: "Deutsch"), .init(code: "es", name: "Español"),
        .init(code: "it", name: "Italiano"), .init(code: "pt", name: "Português"),
        .init(code: "nl", name: "Nederlands"), .init(code: "pl", name: "Polski"),
        .init(code: "el", name: "Ελληνικά"), .init(code: "ar", name: "العربية"),
        .init(code: "ja", name: "日本語"), .init(code: "zh", name: "中文"),
        .init(code: "vi", name: "Tiếng Việt"), .init(code: "ko", name: "한국어"),
    ]

    public static func named(_ code: String) -> Language? { all.first { $0.code == code } }

    /// Separator used when joining independently transcribed chunks.
    public var joiner: String { ["ja", "zh"].contains(code) ? "" : " " }

    /// First preferred system language the model supports, else English.
    public static func systemDefault(_ preferred: [String]) -> Language {
        for id in preferred {
            let code = String(id.prefix(2)).lowercased()
            if let l = named(code) { return l }
        }
        return named("en")!
    }
}
