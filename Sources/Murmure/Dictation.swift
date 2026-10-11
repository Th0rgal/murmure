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
    /// Rebuilt for every session: a long-lived panel can silently stop
    /// appearing on screen after sleep/wake or a display change.
    private var panel: OverlayPanel?
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
    private var streamedUpTo = 0
    private var chunkError: VoiceError?
    private var language = Settings.language
    private var startedAt = Date()
    private var meterTimer: Timer?
    private var releaseTailWork: DispatchWorkItem?
    private let vocabStore = VocabularyStore()
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
        if let pending = releaseTailWork {
            // Re-pressed during the push-to-talk release tail window: keep recording!
            pending.cancel()
            releaseTailWork = nil
            return
        }
        guard state == .idle else { return }
        Recorder.requestPermission { [weak self] ok in
            guard let self else { return }
            guard ok else { return self.flash("Microphone access denied") }
            self.begin()
        }
    }

    private func begin() {
        releaseTailWork?.cancel()
        releaseTailWork = nil
        session += 1
        language = Settings.language
        chunker = Chunker()
        chunkStart = 0
        fedUpTo = 0
        chunkTexts = [:]
        chunkCount = 0
        streamedUpTo = 0
        chunkError = nil
        startedAt = Date()
        model.language = language.code
        model.phase = .recording
        model.livePreview = ""
        model.levels = Array(repeating: 0, count: OverlayModel.bars)
        do {
            try recorder.start()
        } catch {
            return flash(error.localizedDescription)
        }
        state = .recording
        showPanel()
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
        releaseTailWork?.cancel()
        releaseTailWork = nil
        guard state != .idle else { return }
        if state == .recording { recorder.stop() }
        session += 1  // results for the old session are dropped
        model.livePreview = ""
        state = .idle
        hidePanel()
    }

    /// Triggered on push-to-talk key release: waits `Settings.releaseTailMs`
    /// before stopping the recorder so the final syllable is never clipped.
    func commitAfterReleaseTail() {
        guard state == .recording else { return }
        releaseTailWork?.cancel()
        let tailSecs = max(0, Settings.releaseTailMs / 1000.0)
        guard tailSecs > 0 else { return commit() }
        let id = session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == id, self.state == .recording else { return }
            self.releaseTailWork = nil
            self.commit()
        }
        releaseTailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tailSecs, execute: work)
    }

    func commit() {
        releaseTailWork?.cancel()
        releaseTailWork = nil
        guard state == .recording else { return }
        let all = recorder.stop()
        state = .transcribing
        model.phase = .transcribing
        let tail = Array(all[min(chunkStart, all.count)...])
        submitChunk(tail, final: true)
    }

    // MARK: Overlay

    private func showPanel() {
        if let panel, panel.isVisible { return }
        let p = OverlayPanel(model: model)
        panel = p
        p.show()
    }

    private func hidePanel() {
        panel?.hide()
        panel = nil
    }

    private func makePipeline() -> TextPipeline {
        TextPipeline(
            removeDisfluencies: Settings.removeDisfluencies,
            voiceCommands: Settings.voiceCommands,
            convertNumbers: Settings.convertNumbers,
            corrections: vocabStore.loadCorrections(),
            vocabulary: vocabStore.loadVocabulary()
        )
    }

    // MARK: Chunks

    private func maybeCutChunk() {
        guard state == .recording else { return }
        if Date().timeIntervalSince(startedAt) > Self.maxSeconds { return commit() }
        let end = recorder.count
        let fresh = recorder.samples(fedUpTo ..< end)
        fedUpTo = end
        let cut = chunker.feed(fresh)
        if releaseTailWork == nil,
           chunker.shouldAutoStop(
               noSpeechSecs: Settings.autoStopNoSpeechSecs,
               silenceAfterSpeechSecs: Settings.autoStopSilenceSecs
           )
        {
            return chunker.hasSpoken ? commit() : cancel()
        }
        guard Settings.liveChunks, let cut, cut > chunkStart else { return }
        let piece = recorder.samples(chunkStart ..< cut)
        chunkStart = cut
        submitChunk(piece, final: false)
    }

    private func submitChunk(_ samples: [Float], final: Bool) {
        let index = chunkCount
        chunkCount += 1
        let id = session
        let lang = language.code
        let prevContext = index > 0 ? chunkTexts[index - 1] : nil
        let vocab = vocabStore.loadVocabulary()
        voice.async { [weak self, client] in
            var text = ""
            var failure: VoiceError?
            if samples.count >= 16_000 / 5 {
                do {
                    let t = try client.transcribe(
                        wav: Wav.encode(samples),
                        language: lang,
                        context: prevContext,
                        vocabulary: vocab
                    )
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
                self.updateLivePreviewAndStream()
                if final || self.state == .transcribing { self.finishIfDone() }
            }
        }
    }

    private func updateLivePreviewAndStream() {
        let pipeline = makePipeline()
        let completed = (0 ..< chunkCount).compactMap { chunkTexts[$0] }
        let previewText = pipeline.joinAndProcess(completed, language: language)
        model.livePreview = previewText
        if let panel, panel.isVisible, let host = panel.contentView {
            panel.setContentSize(host.fittingSize)
        }
        guard Settings.streamInline, state == .recording else { return }
        while let nextChunk = chunkTexts[streamedUpTo] {
            let processed = pipeline.process(nextChunk, language: language.code)
            if !processed.isEmpty {
                let prefix = streamedUpTo > 0 ? language.joiner : ""
                Paster.insert(prefix + processed, restore: Settings.restoreClipboard, preferAX: true)
            }
            streamedUpTo += 1
        }
    }

    private func finishIfDone() {
        guard state == .transcribing, chunkTexts.count == chunkCount else { return }
        let pipeline = makePipeline()
        let remainingIndices = Settings.streamInline ? Array(streamedUpTo ..< chunkCount) : Array(0 ..< chunkCount)
        let rawChunks = remainingIndices.compactMap { chunkTexts[$0] }
        let text = pipeline.joinAndProcess(rawChunks, language: language)
        session += 1
        model.livePreview = ""
        if let e = chunkError, text.isEmpty, streamedUpTo == 0 {
            state = .idle
            return flash(e.code == "daemon_missing" ? "voiced not installed" : e.message)
        }
        state = .idle
        hidePanel()
        guard !text.isEmpty else { return }
        let prefix = (Settings.streamInline && streamedUpTo > 0) ? language.joiner : ""
        Paster.insert(prefix + text, restore: Settings.restoreClipboard, preferAX: Settings.streamInline)
        if !Paster.canPost { flash("Copied: allow Accessibility to paste") }
    }

    private func flash(_ message: String) {
        log.error("\(message, privacy: .public)")
        model.phase = .message(message)
        showPanel()
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.state == .idle, self.session == id else { return }
            self.hidePanel()
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

}
