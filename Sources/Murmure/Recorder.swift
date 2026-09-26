import AVFoundation
import Foundation

/// Microphone → 16 kHz mono Float32, accumulated in memory.
final class Recorder {
    /// Called on the audio thread after new samples arrive.
    var onSamples: (() -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    // Level meter: one envelope value per 10 ms, drained by the overlay.
    private var envelope: Float = 0
    private var levels: [Float] = []
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            levels.removeAll()
            envelope = 0
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Murmure", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Murmure", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, converter)
        }
        engine.prepare()
        try engine.start()
    }

    private func consume(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch, count: n)
        lock.withLock {
            samples.append(contentsOf: chunk)
            meter(chunk)
        }
        onSamples?()
    }

    /// Same perceptual mapping as Orb: -55 dBFS → 0, -10 dBFS → 1, fast
    /// attack (45 ms), slower release (180 ms). Called under `lock`.
    private func meter(_ chunk: UnsafeBufferPointer<Float>) {
        let block = 160  // 10 ms at 16 kHz
        var i = 0
        while i + block <= chunk.count {
            var e: Float = 0
            for s in chunk[i ..< i + block] { e += s * s }
            let db = 20 * log10(max((e / Float(block)).squareRoot(), 1e-6))
            let target = max(0, min(1, (db + 55) / 45))
            let tau: Float = target > envelope ? 45 : 180
            envelope += (target - envelope) * (1 - exp(-10 / tau))
            levels.append(envelope)
            i += block
        }
        if levels.count > 200 { levels.removeFirst(levels.count - 200) }
    }

    /// Envelope values produced since the last call.
    func drainLevels() -> [Float] {
        lock.withLock {
            defer { levels.removeAll(keepingCapacity: true) }
            return levels
        }
    }

    var count: Int { lock.withLock { samples.count } }

    func samples(_ range: Range<Int>) -> [Float] {
        lock.withLock {
            let r = range.clamped(to: 0 ..< samples.count)
            return Array(samples[r])
        }
    }

    @discardableResult
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }
}
