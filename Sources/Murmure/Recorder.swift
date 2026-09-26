import AVFoundation
import Foundation

/// Microphone → 16 kHz mono Float32, accumulated in memory.
final class Recorder {
    var onLevel: ((Float) -> Void)?
    /// Called on the audio thread after new samples arrive.
    var onSamples: (() -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Murmure", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aucun micro disponible"])
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Murmure", code: 2, userInfo: [NSLocalizedDescriptionKey: "Format micro non supporté"])
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
        var e: Float = 0
        for s in chunk { e += s * s }
        lock.withLock { samples.append(contentsOf: chunk) }
        let rms = n > 0 ? (e / Float(n)).squareRoot() : 0
        onLevel?(rms)
        onSamples?()
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
