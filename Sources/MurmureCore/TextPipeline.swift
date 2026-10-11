import Foundation

/// Composable text post-processing pipeline inspired by `voiceio`:
/// 1. Disfluency removal ("um", "uh", "euh" and stuttered word pairs)
/// 2. Voice commands ("new line", "new paragraph", "scratch that")
/// 3. Spoken number conversion ("twenty five" → "25")
/// 4. Corrections dictionary (case-preserving phrase & word replacements)
/// 5. Vocabulary fuzzy snapping (snaps single-token near-misses to known vocabulary terms)
/// 6. Smart cross-chunk joiner (fixes mid-sentence capitalization across VAD chunk boundaries)
public struct TextPipeline: Sendable {
    public var removeDisfluencies: Bool
    public var voiceCommands: Bool
    public var convertNumbers: Bool
    public var corrections: [String: String]
    public var vocabulary: [String]

    public init(
        removeDisfluencies: Bool = true,
        voiceCommands: Bool = false,
        convertNumbers: Bool = false,
        corrections: [String: String] = [:],
        vocabulary: [String] = []
    ) {
        self.removeDisfluencies = removeDisfluencies
        self.voiceCommands = voiceCommands
        self.convertNumbers = convertNumbers
        self.corrections = corrections
        self.vocabulary = vocabulary
    }

    /// Runs the configured pipeline on a single transcript or joined transcript.
    public func process(_ text: String, language: String = "en") -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "" }

        if voiceCommands {
            out = Self.applyVoiceCommands(out, language: language)
        }
        if removeDisfluencies {
            out = Self.stripDisfluencies(out, language: language)
        }
        if convertNumbers && language == "en" {
            out = Self.convertSpokenNumbers(out)
        }
        if !corrections.isEmpty {
            out = Self.applyCorrections(out, rules: corrections)
        }
        if !vocabulary.isEmpty {
            out = Self.snapToVocabulary(out, vocabulary: vocabulary)
        }
        return Self.cleanSpacingAndPunctuation(out)
    }

    /// Joins multiple VAD-cut chunks intelligently, avoiding spurious mid-sentence
    /// capitalization when a chunk was cut at a comma or breath pause, then runs
    /// the post-processing pipeline.
    public func joinAndProcess(_ chunks: [String], language: Language) -> String {
        let nonEmpty = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        let vocabLower = Set(vocabulary.map { $0.lowercased() })
        var merged = nonEmpty[0]

        for nextRaw in nonEmpty.dropFirst() {
            var next = nextRaw
            let prevTrimmed = merged.trimmingCharacters(in: .whitespaces)
            let prevEndsSentence = prevTrimmed.last.map { ".!?…:;\"')]\n".contains($0) } ?? true

            if !prevEndsSentence, let firstSpace = next.firstIndex(of: " ") {
                let firstWord = String(next[..<firstSpace]).trimmingCharacters(in: .punctuationCharacters)
                if !firstWord.isEmpty,
                   firstWord != "I",
                   !firstWord.hasPrefix("I'"),
                   firstWord.uppercased() != firstWord || firstWord.count == 1,
                   !vocabLower.contains(firstWord.lowercased())
                {
                    next = next.prefix(1).lowercased() + next.dropFirst()
                }
            } else if !prevEndsSentence {
                let firstWord = next.trimmingCharacters(in: .punctuationCharacters)
                if !firstWord.isEmpty,
                   firstWord != "I",
                   firstWord.uppercased() != firstWord,
                   !vocabLower.contains(firstWord.lowercased())
                {
                    next = next.prefix(1).lowercased() + next.dropFirst()
                }
            }

            merged += language.joiner + next
        }

        return process(merged, language: language.code)
    }

    // MARK: - Stage 1: Disfluencies

    private static let fillersByLang: [String: Set<String>] = [
        "en": ["um", "uh", "erm", "er", "hm", "hmm", "uhm"],
        "fr": ["euh", "heu", "bah", "ben", "hmm", "hm"],
        "de": ["äh", "ähm", "hm", "hmm"],
        "es": ["eh", "este", "em", "hm"],
    ]

    public static func stripDisfluencies(_ text: String, language: String = "en") -> String {
        let fillers = fillersByLang[language] ?? fillersByLang["en"]!
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []

        for token in tokens {
            let bare = token.trimmingCharacters(in: CharacterSet.punctuationCharacters).lowercased()
            if fillers.contains(bare) {
                continue
            }
            // Drop immediate exact word stutters like "the the" or "I I"
            if let prev = kept.last {
                let prevBare = prev.trimmingCharacters(in: CharacterSet.punctuationCharacters).lowercased()
                if !bare.isEmpty, bare == prevBare, bare.count <= 4, !prev.hasSuffix(","), !prev.hasSuffix(".") {
                    continue
                }
            }
            kept.append(token)
        }

        var result = kept.joined(separator: " ")
        // Clean up leading comma if the first word was a filler ("Um, hello" -> "Hello")
        if result.hasPrefix(", ") {
            result = String(result.dropFirst(2))
        }
        if let first = text.first, first.isUppercase, let rFirst = result.first, rFirst.isLowercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        return result
    }

    // MARK: - Stage 2: Voice Commands

    public static func applyVoiceCommands(_ text: String, language: String = "en") -> String {
        var current = text
        // Handle "scratch that" / "efface ça": remove the sentence/clause before the phrase
        let scratchPatterns = language == "fr" ? ["efface ça", "annule ça"] : ["scratch that", "delete that"]
        for pat in scratchPatterns {
            while let range = current.range(of: pat, options: [.caseInsensitive]) {
                let before = current[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let after = current[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // Drop back to the previous sentence boundary if any
                if let lastBoundary = before.dropLast().lastIndex(where: { ".!?\n".contains($0) }) {
                    let prefix = String(before[...lastBoundary])
                    current = (prefix + " " + after).trimmingCharacters(in: .whitespaces)
                } else {
                    current = String(after.drop(while: { ".,!?;: ".contains($0) }))
                }
            }
        }

        let replacements: [(String, String)] = language == "fr"
            ? [("nouveau paragraphe", "\n\n"), ("nouvelle ligne", "\n"), ("à la ligne", "\n")]
            : [("new paragraph", "\n\n"), ("new line", "\n")]

        for (phrase, rep) in replacements {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b[.,!?;:]?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                current = regex.stringByReplacingMatches(
                    in: current,
                    range: NSRange(current.startIndex..., in: current),
                    withTemplate: rep
                )
            }
        }
        return current
    }

    // MARK: - Stage 3: Spoken Numbers (English)

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Converts compound spoken numbers (≥ 20 or multi-word numbers like "twenty five" → "25")
    /// while leaving single small words like "one" alone ("no one" stays "no one", as noted in voiceio).
    public static func convertSpokenNumbers(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return text }
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w1 = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let t = tens[w1], i + 1 < words.count {
                let raw2 = words[i + 1]
                let w2 = raw2.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let o = ones[w2], o > 0 && o < 10 {
                    let trailingPunct = raw2.ReversedPrefixWhilePunctuation()
                    out.append("\(t + o)\(trailingPunct)")
                    i += 2
                    continue
                }
            }
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: - Stage 4: Corrections Dictionary

    public static func applyCorrections(_ text: String, rules: [String: String]) -> String {
        var out = text
        // Sort longest wrong phrase first so multi-word rules ("post grass") win over single words
        let sorted = rules.sorted { $0.key.count > $1.key.count }
        for (wrong, right) in sorted where !wrong.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: right)
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    // MARK: - Stage 5: Vocabulary Fuzzy Snapping

    /// Snaps words of length >= 5 that are within Levenshtein edit distance <= 1 (or <= 2 for >= 8 chars)
    /// or exact case-insensitive match to the canonical spelling in `vocabulary`.
    public static func snapToVocabulary(_ text: String, vocabulary: [String]) -> String {
        guard !vocabulary.isEmpty else { return text }
        var out = text
        // First apply multi-word or exact case-insensitive vocabulary terms
        var exactRules: [String: String] = [:]
        for term in vocabulary where !term.isEmpty {
            exactRules[term.lowercased()] = term
        }
        out = applyCorrections(out, rules: exactRules)

        let singleTerms = vocabulary.filter { !$0.contains(" ") && $0.count >= 5 }
        guard !singleTerms.isEmpty else { return out }

        let tokens = out.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let snapped = tokens.map { token -> String in
            let leading = String(token.prefix(while: { $0.isPunctuation }))
            let trailing = token.ReversedPrefixWhilePunctuation()
            let coreStart = token.index(token.startIndex, offsetBy: leading.count)
            let coreEnd = token.index(token.endIndex, offsetBy: -trailing.count)
            guard coreStart < coreEnd else { return token }
            let core = String(token[coreStart ..< coreEnd])
            guard core.count >= 5 else { return token }
            let coreLower = core.lowercased()
            if exactRules[coreLower] != nil {
                return leading + exactRules[coreLower]! + trailing
            }
            var bestTerm: String?
            var bestDist = Int.max
            for term in singleTerms {
                let termLower = term.lowercased()
                guard abs(termLower.count - coreLower.count) <= 2,
                      termLower.first == coreLower.first
                else { continue }
                let maxAllowed = termLower.count >= 8 ? 2 : 1
                let d = levenshtein(coreLower, termLower)
                if d <= maxAllowed && d < bestDist {
                    bestDist = d
                    bestTerm = term
                }
            }
            if let bestTerm {
                return leading + bestTerm + trailing
            }
            return token
        }
        return snapped.joined(separator: " ")
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0 ... bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)
        for (i, ca) in aChars.enumerated() {
            curr[0] = i + 1
            for (j, cb) in bChars.enumerated() {
                let cost = (ca == cb) ? 0 : 1
                curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }

    // MARK: - Formatting cleanup

    private static func cleanSpacingAndPunctuation(_ text: String) -> String {
        var out = text
        // Collapse multiple horizontal spaces while preserving newlines
        if let regex = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        // Remove space before period/comma
        if let regex = try? NSRegularExpression(pattern: " +([.,!?;:])") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        // Trim spaces around newlines
        out = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func ReversedPrefixWhilePunctuation() -> String {
        let rev = self.reversed().prefix(while: { $0.isPunctuation })
        return String(rev.reversed())
    }
}
