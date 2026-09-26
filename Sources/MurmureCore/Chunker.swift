import Foundation

/// Cuts a live 16 kHz recording at pauses so earlier parts can be
/// transcribed while the user is still talking. When they stop, only the
/// tail is left to transcribe, so latency no longer grows with length.
///
/// Cohere Transcribe works on ≤35 s windows; chunks are cut at the middle of
/// a pause once `minChunk` seconds have accumulated, and forced at the
/// quietest frame before `maxChunk`.
public struct Chunker {
    public let sampleRate: Int
    public var minChunk: Double
    public var maxChunk: Double
    public var minPause: Double
    let frame: Int

    private var frameRms: [Float] = []
    private var cutFrame = 0  // frame index where the pending chunk starts
    private var carry: [Float] = []

    public init(sampleRate: Int = 16_000, minChunk: Double = 7, maxChunk: Double = 28, minPause: Double = 0.45) {
        self.sampleRate = sampleRate
        self.minChunk = minChunk
        self.maxChunk = maxChunk
        self.minPause = minPause
        self.frame = sampleRate * 30 / 1000
    }

    /// Feed the samples recorded since the last call; returns the absolute
    /// sample index at which to cut the next chunk, if one is ready.
    public mutating func feed<S: Collection>(_ samples: S) -> Int? where S.Element == Float {
        carry.append(contentsOf: samples)
        var used = 0
        while carry.count - used >= frame {
            var e: Float = 0
            for s in carry[used ..< used + frame] { e += s * s }
            frameRms.append((e / Float(frame)).squareRoot())
            used += frame
        }
        carry.removeFirst(used)
        let fps = Double(sampleRate) / Double(frame)
        let pending = frameRms.count - cutFrame
        guard Double(pending) >= minChunk * fps else { return nil }
        let threshold = silenceThreshold(fps: fps)
        let needed = Int(minPause * fps)
        // Latest pause long enough, searched backwards from the end.
        var run = 0
        var i = frameRms.count - 1
        let lowest = cutFrame + Int(minChunk * fps / 2)
        while i >= lowest {
            if frameRms[i] < threshold {
                run += 1
            } else if run >= needed {
                return cut(at: i + 1 + run / 2)
            } else {
                run = 0
            }
            i -= 1
        }
        if Double(pending) >= maxChunk * fps {
            // No pause: cut at the quietest frame in the last 3 seconds.
            let from = max(cutFrame + 1, frameRms.count - Int(3 * fps))
            let q = (from ..< frameRms.count).min { frameRms[$0] < frameRms[$1] }!
            return cut(at: q)
        }
        return nil
    }

    /// Between the noise floor and the speech level of the last 10 seconds:
    /// 3× the 10th percentile, capped at 30% of the 90th, never below 0.006.
    private func silenceThreshold(fps: Double) -> Float {
        let recent = frameRms.suffix(Int(10 * fps)).sorted()
        let floor = recent[recent.count / 10]
        let speech = recent[recent.count * 9 / 10]
        return max(0.006, min(floor * 3, speech * 0.3))
    }

    private mutating func cut(at f: Int) -> Int {
        cutFrame = f
        return f * frame
    }
}
