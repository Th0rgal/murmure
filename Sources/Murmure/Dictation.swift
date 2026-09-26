import AppKit
import MurmureCore
import os

/// One dictation session at a time: record, transcribe pauses in the
/// background while the user speaks, transcribe the tail on commit, paste.
final class Dictation {
    enum State { case idle, recording, transcribing }
    private(set) var state = State.idle {
        didSet {
            if state != .recording { meterTimer?.invalidate(); meterTimer = nil }
            onStateChange?(state)
        }
    }
    var onStateChange: ((State) -> Void)?

    let model = OverlayModel()
    private lazy var panel = OverlayPanel(model: model)
    private let recorder = Recorder()
    private let client = VoiceClient()
    /// Every daemon call goes through this queue (VoiceClient is not thread-safe).
    private let voice = DispatchQueue(label: "md.thomas.murmure.voice", qos: .userInitiated)
    private let log = Logger(subsystem: "md.thomas.murmure", category: "dictation")

    private var session = 0
    private var chunker = Chunker()
    private var chunkStart = 0
    private var fedUpTo = 0
    private var chunkTexts: [Int: String] = [:]
    private var chunkCount = 0
    private var chunkError: VoiceError?
    private var language = Settings.language
    private var startedAt = Date()
    private var meterTimer: Timer?
    private static let maxSeconds: Double = 15 * 60

    init() {
        model.onCancel = { [weak self] in self?.cancel() }
        model.onCommit = { [weak self] in self?.commit() }
        model.onLanguage = { [weak self] in self?.showLanguageMenu() }
        recorder.onSamples = { [weak self] in
            DispatchQueue.main.async { self?.maybeCutChunk() }
        }
    }

    // MARK: Session

    func start() {
        guard state == .idle else { return }
        Recorder.requestPermission { [weak self] ok in
            guard let self else { return }
            guard ok else { return self.flash("Micro refusé — Réglages › Confidentialité") }
            self.begin()
        }
    }

    private func begin() {
        session += 1
        language = Settings.language
        chunker = Chunker()
        chunkStart = 0
        fedUpTo = 0
        chunkTexts = [:]
        chunkCount = 0
        chunkError = nil
        startedAt = Date()
        model.language = language.code
        model.phase = .recording
        model.levels = Array(repeating: 0, count: OverlayModel.bars)
        do {
            try recorder.start()
        } catch {
            return flash(error.localizedDescription)
        }
        state = .recording
        panel.show()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.tick(self.recorder.drainLevels())
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
        // Load the model while the user speaks; later requests queue behind it.
        voice.async { [client, log] in
            do { try client.load() } catch { log.error("prewarm failed: \(String(describing: error))") }
        }
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: commit()
        case .transcribing: break
        }
    }

    func cancel() {
        guard state != .idle else { return }
        if state == .recording { recorder.stop() }
        session += 1  // results for the old session are dropped
        state = .idle
        panel.hide()
    }

    func commit() {
        guard state == .recording else { return }
        let all = recorder.stop()
        state = .transcribing
        model.phase = .transcribing
        let tail = Array(all[min(chunkStart, all.count)...])
        submitChunk(tail, final: true)
    }

    // MARK: Chunks

    private func maybeCutChunk() {
        guard state == .recording else { return }
        if Date().timeIntervalSince(startedAt) > Self.maxSeconds { return commit() }
        guard Settings.liveChunks else { return }
        let end = recorder.count
        let fresh = recorder.samples(fedUpTo ..< end)
        fedUpTo = end
        guard let cut = chunker.feed(fresh), cut > chunkStart else { return }
        let piece = recorder.samples(chunkStart ..< cut)
        chunkStart = cut
        submitChunk(piece, final: false)
    }

    private func submitChunk(_ samples: [Float], final: Bool) {
        let index = chunkCount
        chunkCount += 1
        let id = session
        let lang = language.code
        voice.async { [weak self, client] in
            var text = ""
            var failure: VoiceError?
            if samples.count >= 16_000 / 5 {
                do {
                    let t = try client.transcribe(wav: Wav.encode(samples), language: lang)
                    text = t.text
                    self?.log.info("chunk \(index) \(t.durationSecs, format: .fixed(precision: 2))s infer=\(t.inferSecs, format: .fixed(precision: 2))s")
                } catch let e as VoiceError {
                    failure = e
                } catch {
                    failure = VoiceError("internal", error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.session == id else { return }
                self.chunkTexts[index] = text
                if let failure { self.chunkError = failure }
                if final || self.state == .transcribing { self.finishIfDone() }
            }
        }
    }

    private func finishIfDone() {
        guard state == .transcribing, chunkTexts.count == chunkCount else { return }
        let text = (0 ..< chunkCount).compactMap { chunkTexts[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: language.joiner)
        session += 1
        if let e = chunkError, text.isEmpty {
            state = .idle
            return flash(e.code == "daemon_missing" ? "voiced absent — scripts/install-voiced.sh" : e.message)
        }
        state = .idle
        panel.hide()
        guard !text.isEmpty else { return }
        Paster.insert(text, restore: Settings.restoreClipboard)
        if !Paster.canPost { flash("Copié — autorise l'Accessibilité pour coller") }
    }

    private func flash(_ message: String) {
        log.error("\(message, privacy: .public)")
        model.phase = .message(message)
        panel.show()
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.state == .idle, self.session == id else { return }
            self.panel.hide()
        }
    }

    // MARK: Language

    func showLanguageMenu() {
        let menu = NSMenu()
        for l in Language.all {
            let item = NSMenuItem(title: l.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l.code
            item.state = l.code == Settings.language.code ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let l = Language.named(code) else { return }
        Settings.language = l
        setLanguage(l)
    }

    func setLanguage(_ l: Language) {
        model.language = l.code
        // Chunks already sent keep their language; the rest follow the new one.
        if state != .idle { language = l }
    }

    /// Warm the daemon (and so the model) ahead of the first dictation.
    func prewarm() {
        voice.async { [client, log] in
            do { try client.load() } catch { log.error("prewarm failed: \(String(describing: error))") }
        }
    }
}
