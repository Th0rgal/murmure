import Foundation

/// Loads and saves user-defined `vocabulary.txt` (one term per line, `#` comments)
/// and `corrections.json` (`{"wrong phrase": "RightPhrase"}`) from the voice home
/// directory (`~/Library/Application Support/md.thomas.voice/`).
public struct VocabularyStore: Sendable {
    public let directory: String

    public static var defaultDirectory: String {
        if let h = ProcessInfo.processInfo.environment["VOICED_HOME"], !h.isEmpty { return h }
        return NSHomeDirectory() + "/Library/Application Support/md.thomas.voice"
    }

    public init(directory: String = VocabularyStore.defaultDirectory) {
        self.directory = directory
    }

    public var vocabularyPath: String { (directory as NSString).appendingPathComponent("vocabulary.txt") }
    public var correctionsPath: String { (directory as NSString).appendingPathComponent("corrections.json") }

    public func loadVocabulary() -> [String] {
        guard let raw = try? String(contentsOfFile: vocabularyPath, encoding: .utf8) else { return [] }
        return Self.parseVocabulary(raw)
    }

    public static func parseVocabulary(_ raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                terms.append(trimmed)
            }
        }
        return terms
    }

    public func saveVocabulary(_ terms: [String]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let body = terms.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
        try body.write(toFile: vocabularyPath, atomically: true, encoding: .utf8)
    }

    public func loadCorrections() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: correctionsPath)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    public func saveCorrections(_ rules: [String: String]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: URL(fileURLWithPath: correctionsPath), options: .atomic)
    }
}
