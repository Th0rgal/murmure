import Foundation
@testable import MurmureCore
import XCTest

final class HotkeyStateTests: XCTestCase {
    func testTapTogglesRecording() {
        var s = HotkeyState()
        XCTAssertEqual(s.update(pressed: true, at: 0), .start)
        XCTAssertNil(s.update(pressed: false, at: 0.1))  // quick release: toggle mode
        XCTAssertTrue(s.recording)
        XCTAssertEqual(s.update(pressed: true, at: 3), .commit)
        XCTAssertNil(s.update(pressed: false, at: 3.1))
        XCTAssertFalse(s.recording)
    }

    func testHoldIsPushToTalk() {
        var s = HotkeyState()
        XCTAssertEqual(s.update(pressed: true, at: 0), .start)
        XCTAssertNil(s.update(pressed: true, at: 1))  // repeated flags events
        XCTAssertEqual(s.update(pressed: false, at: 2), .releaseCommit)
        XCTAssertFalse(s.recording)
    }

    func testResetAfterExternalStop() {
        var s = HotkeyState()
        _ = s.update(pressed: true, at: 0)
        _ = s.update(pressed: false, at: 0.1)
        s.reset()  // e.g. ✓ clicked
        XCTAssertEqual(s.update(pressed: true, at: 5), .start)
    }
}

final class RingBufferTests: XCTestCase {
    func testWrapAroundAndChronologicalDrain() {
        var rb = RingBuffer(capacity: 5)
        rb.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(rb.snapshot(), [1, 2, 3])
        rb.append(contentsOf: [4, 5, 6, 7])
        XCTAssertEqual(rb.count, 5)
        XCTAssertEqual(rb.drain(), [3, 4, 5, 6, 7])
        XCTAssertEqual(rb.count, 0)
        XCTAssertTrue(rb.snapshot().isEmpty)
    }

    func testOversizedAppendKeepsLatestSuffix() {
        var rb = RingBuffer(capacity: 4)
        rb.append(contentsOf: [10, 20, 30, 40, 50, 60])
        XCTAssertEqual(rb.drain(), [30, 40, 50, 60])
    }
}

final class ShortcutTests: XCTestCase {
    let fn: UInt64 = 0x80_0000, rshift: UInt64 = 0x04, lshift: UInt64 = 0x02, lcmd: UInt64 = 0x08, ropt: UInt64 = 0x40

    func testModifierOnlyNeedsExactSides() {
        let s = Shortcut.default
        XCTAssertEqual(s.label, "Fn + Right ⇧")
        XCTAssertTrue(s.modifiersMatch(Modifier.held(in: fn | rshift)))
        XCTAssertFalse(s.modifiersMatch(Modifier.held(in: fn | lshift)))
        XCTAssertFalse(s.modifiersMatch(Modifier.held(in: fn | rshift | lcmd)))
        XCTAssertFalse(s.modifiersMatch(Modifier.held(in: fn)))
    }

    func testKeyShortcutIgnoresImplicitFn() {
        let s = Shortcut(modifiers: [.rightOption], keyCode: 49, keyLabel: "Space")
        XCTAssertEqual(s.label, "Right ⌥ + Space")
        XCTAssertTrue(s.keyMatches(49, held: Modifier.held(in: ropt)))
        XCTAssertTrue(s.keyMatches(49, held: Modifier.held(in: ropt | fn)))
        XCTAssertFalse(s.keyMatches(49, held: []))
        XCTAssertFalse(s.keyMatches(50, held: Modifier.held(in: ropt)))
    }

    func testValidity() {
        XCTAssertFalse(Shortcut(modifiers: [], keyCode: 0, keyLabel: "A").isValid)
        XCTAssertTrue(Shortcut(modifiers: [], keyCode: 96, keyLabel: "F5").isValid)
        XCTAssertTrue(Shortcut(modifiers: [.rightCommand]).isValid)
        XCTAssertFalse(Shortcut(modifiers: []).isValid)
    }

    func testCaptureModifierChordOnRelease() {
        var c = ShortcutCapture()
        XCTAssertNil(c.flagsChanged(Modifier.held(in: fn)))
        XCTAssertNil(c.flagsChanged(Modifier.held(in: fn | rshift)))
        XCTAssertNil(c.flagsChanged(Modifier.held(in: rshift)))
        XCTAssertEqual(c.flagsChanged([]), Shortcut.default)
    }

    func testCaptureKeyChord() {
        var c = ShortcutCapture()
        _ = c.flagsChanged(Modifier.held(in: ropt))
        let s = c.keyDown(49, label: "Space", held: Modifier.held(in: ropt))
        XCTAssertEqual(s, Shortcut(modifiers: [.rightOption], keyCode: 49, keyLabel: "Space"))
        XCTAssertNil(c.keyDown(0, label: "A", held: []))  // bare letter rejected
        XCTAssertEqual(c.keyDown(96, label: "F5", held: Modifier.held(in: fn))?.modifiers, [])  // implicit fn dropped
    }

    func testCodableRoundTrip() throws {
        let s = Shortcut(modifiers: [.leftControl, .leftOption], keyCode: 2, keyLabel: "D")
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s)), s)
    }
}

final class WavTests: XCTestCase {
    func testHeaderAndSamples() {
        let d = Wav.encode([0, 1, -1, 0.5])
        XCTAssertEqual(d.count, 44 + 8)
        XCTAssertEqual(String(decoding: d[0 ..< 4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[36 ..< 40], as: UTF8.self), "data")
        let rate = d[24 ..< 28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16000)
        let s1 = d[46 ..< 48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int16(littleEndian: s1), 32767)
    }
}

final class ChunkerTests: XCTestCase {
    func speech(_ secs: Double) -> [Float] {
        (0 ..< Int(secs * 16000)).map { Float(sin(Double($0) * 0.05) * 0.2) }
    }

    func silence(_ secs: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(secs * 16000)) }

    func feed(_ c: inout Chunker, _ s: [Float]) -> [Int] {
        var cuts: [Int] = []
        var i = 0
        while i < s.count {
            let j = min(s.count, i + 1600)
            if let cut = c.feed(s[i ..< j]) { cuts.append(cut) }
            i = j
        }
        return cuts
    }

    func testCutsInsidePauseAfterMinChunk() {
        var c = Chunker()
        let audio = speech(3) + silence(0.8) + speech(5) + silence(0.8) + speech(3)
        let cuts = feed(&c, audio)
        XCTAssertEqual(cuts.count, 1)
        let t = Double(cuts[0]) / 16000
        XCTAssertGreaterThan(t, 8.8)  // second pause: 8.8–9.6 s
        XCTAssertLessThan(t, 9.6)
    }

    func testNoCutWithoutPauseUntilMax() {
        var c = Chunker()
        XCTAssertTrue(feed(&c, speech(20)).isEmpty)
        let cuts = feed(&c, speech(10))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertLessThanOrEqual(Double(cuts[0]) / 16000, 28.1)
    }

    func testShortRecordingNeverCut() {
        var c = Chunker()
        XCTAssertTrue(feed(&c, speech(2) + silence(1) + speech(2)).isEmpty)
    }

    func testAutoStopOnSilenceAfterSpeechAndNoSpeech() {
        var c = Chunker()
        _ = feed(&c, silence(4))
        XCTAssertFalse(c.hasSpoken)
        XCTAssertFalse(c.shouldAutoStop(noSpeechSecs: 6.0, silenceAfterSpeechSecs: 3.0))
        _ = feed(&c, silence(3))
        XCTAssertTrue(c.shouldAutoStop(noSpeechSecs: 6.0, silenceAfterSpeechSecs: 3.0))

        var c2 = Chunker()
        _ = feed(&c2, speech(1.0) + silence(1.0))
        XCTAssertTrue(c2.hasSpoken)
        XCTAssertFalse(c2.shouldAutoStop(noSpeechSecs: 20.0, silenceAfterSpeechSecs: 3.0))
        _ = feed(&c2, silence(2.5))
        XCTAssertTrue(c2.shouldAutoStop(noSpeechSecs: 20.0, silenceAfterSpeechSecs: 3.0))
    }
}

final class TextPipelineTests: XCTestCase {
    func testDisfluencyAndStutterRemoval() {
        let p = TextPipeline(removeDisfluencies: true)
        XCTAssertEqual(p.process("Um, I think uh we should ship the the patch."), "I think we should ship the patch.")
        XCTAssertEqual(p.process("Euh je pense que euh oui.", language: "fr"), "Je pense que oui.")
    }

    func testCorrectionsAndVocabularyFuzzySnap() {
        let p = TextPipeline(
            removeDisfluencies: true,
            convertNumbers: true,
            corrections: ["post grass": "PostgreSQL", "graph ana": "Grafana"],
            vocabulary: ["Murmure", "Kalshi", "Cohere", "Hetzner"]
        )
        let input = "Ship the post grass migration, fix the graph Ana alert, and rerun twenty five kalchi backtests on Hertzner with murmure."
        let out = p.process(input, language: "en")
        XCTAssertEqual(out, "Ship the PostgreSQL migration, fix the Grafana alert, and rerun 25 Kalshi backtests on Hetzner with Murmure.")
    }

    func testVoiceCommandsAndScratchThat() {
        let p = TextPipeline(voiceCommands: true)
        XCTAssertEqual(p.process("First sentence. Wrong draft scratch that Second sentence new line Third line."), "First sentence. Second sentence\nThird line.")
    }

    func testSmartChunkJoiner() {
        let p = TextPipeline(vocabulary: ["Murmure", "Cohere"])
        let fr = Language.named("fr")!
        let en = Language.named("en")!
        // Mid-sentence pause (comma or no period) lowercases non-vocabulary start word of chunk 2
        XCTAssertEqual(
            p.joinAndProcess(["When we tested the model,", "The latency was under one second."], language: en),
            "When we tested the model, the latency was under one second."
        )
        // Vocabulary term at start of chunk 2 keeps its capital
        XCTAssertEqual(
            p.joinAndProcess(["When we tested", "Murmure on Apple Silicon."], language: en),
            "When we tested Murmure on Apple Silicon."
        )
        // Sentence-ending period keeps capital on chunk 2
        XCTAssertEqual(
            p.joinAndProcess(["Premier test terminé.", "Le suivant démarre."], language: fr),
            "Premier test terminé. Le suivant démarre."
        )
    }
}

final class VocabularyStoreTests: XCTestCase {
    func testParseAndPersistVocabularyAndCorrections() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("murmure-vocab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = VocabularyStore(directory: tmp)
        let parsed = VocabularyStore.parseVocabulary("# comment\nMurmure\nPostgreSQL # database\nmurmure\n")
        XCTAssertEqual(parsed, ["Murmure", "PostgreSQL"])
        try store.saveVocabulary(parsed)
        XCTAssertEqual(store.loadVocabulary(), ["Murmure", "PostgreSQL"])
        try store.saveCorrections(["post grass": "PostgreSQL"])
        XCTAssertEqual(store.loadCorrections(), ["post grass": "PostgreSQL"])
    }
}

final class LanguageTests: XCTestCase {
    func testSystemDefault() {
        XCTAssertEqual(Language.systemDefault(["fr-FR", "en-US"]).code, "fr")
        XCTAssertEqual(Language.systemDefault(["sv-SE"]).code, "en")
        XCTAssertEqual(Language.named("ja")?.joiner, "")
    }
}

/// Live test against the installed daemon; skipped when voiced is absent.
final class VoiceClientLiveTests: XCTestCase {
    func testHelloOverSocket() throws {
        let c = VoiceClient()
        guard FileManager.default.fileExists(atPath: c.path) else { throw XCTSkip("voiced not installed") }
        let h = try c.hello()
        XCTAssertEqual(h["protocol"] as? Int, 1)
        XCTAssertEqual(h["shared"] as? Bool, true)
        let silent = try c.transcribe(wav: Wav.encode([Float](repeating: 0, count: 16000)), language: "fr")
        XCTAssertEqual(silent.text, "")
    }
}

/// End to end through the real model: chunk the bundled demo clip at its
/// pauses, transcribe the pieces, and compare with the whole-clip result.
final class LiveTranscriptionTests: XCTestCase {
    func testDemoClipWholeAndChunked() throws {
        let c = VoiceClient()
        guard FileManager.default.fileExists(atPath: c.path) else { throw XCTSkip("voiced not installed") }
        let snap = NSHomeDirectory() + "/.cache/huggingface/hub/models--MarkChen1214--cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit/snapshots/553445e84959f9ec3fcd43443bce75ea05c400f3/demo/voxpopuli_test_en_demo.wav"
        guard let data = FileManager.default.contents(atPath: snap) else { throw XCTSkip("demo clip missing") }
        let samples = try Self.decode16kMono(data)
        let whole = try c.transcribe(wav: Wav.encode(samples), language: "en")
        XCTAssertTrue(whole.text.lowercased().contains("european parliament"), whole.text)

        // Two sentences separated by a pause, as a live dictation would be.
        let long = samples + [Float](repeating: 0.0005, count: 16000) + samples
        var chunker = Chunker(minChunk: 4)
        var cuts = [0]
        var i = 0
        while i < long.count {
            let j = min(long.count, i + 1600)
            if let cut = chunker.feed(long[i ..< j]) { cuts.append(cut) }
            i = j
        }
        cuts.append(long.count)
        XCTAssertEqual(cuts.count - 1, 2, "one cut, inside the pause")
        let texts = try zip(cuts, cuts.dropFirst()).map { a, b in
            try c.transcribe(wav: Wav.encode(long[a ..< b]), language: "en").text
        }
        let joined = texts.filter { !$0.isEmpty }.joined(separator: " ")
        print("chunks=\(cuts.count - 1) whole=\(whole.text) | chunked=\(joined)")
        XCTAssertEqual(joined.lowercased().components(separatedBy: "european parliament").count - 1, 2, joined)
    }

    /// Minimal PCM16 WAV reader with naive resampling to 16 kHz mono.
    static func decode16kMono(_ d: Data) throws -> [Float] {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var pos = 12, channels = 1, rate = 16000
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos ..< pos + 4], as: UTF8.self), size = u32(pos + 4)
            if id == "fmt " { channels = u16(pos + 10); rate = u32(pos + 12) }
            if id == "data" {
                let n = min(size, b.count - pos - 8) / (2 * channels)
                var mono = [Float](repeating: 0, count: n)
                for f in 0 ..< n {
                    var acc = 0
                    for ch in 0 ..< channels { acc += Int(Int16(bitPattern: UInt16(u16(pos + 8 + (f * channels + ch) * 2)))) }
                    mono[f] = Float(acc) / Float(channels) / 32768
                }
                if rate == 16000 { return mono }
                let ratio = Double(rate) / 16000
                return (0 ..< Int(Double(n) / ratio)).map { mono[Int(Double($0) * ratio)] }
            }
            pos += 8 + size + (size & 1)
        }
        throw VoiceError("bad_wav", "no data chunk")
    }
}
