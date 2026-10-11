import Foundation

/// Fixed-capacity circular buffer of Float audio samples for keeping a rolling
/// pre-buffer (e.g. 1.0 s at 16 kHz) while the microphone stream stays warm.
/// When a dictation starts, the pre-buffer is drained so the first syllable
/// spoken right as the shortcut is pressed is never clipped.
public struct RingBuffer: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    public mutating func append<S: Collection>(contentsOf samples: S) where S.Element == Float {
        let n = samples.count
        guard n > 0 else { return }
        if n >= capacity {
            let tail = samples.suffix(capacity)
            var idx = 0
            for s in tail {
                storage[idx] = s
                idx += 1
            }
            writeIndex = 0
            count = capacity
            return
        }
        for s in samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(capacity, count + n)
    }

    /// Returns the buffered samples in chronological order and resets the buffer.
    public mutating func drain() -> [Float] {
        defer { clear() }
        return snapshot()
    }

    /// Returns the buffered samples in chronological order without clearing.
    public func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity {
            let start = (writeIndex - count + capacity) % capacity
            if start + count <= capacity {
                return Array(storage[start ..< start + count])
            }
        }
        let firstPart = storage[writeIndex ..< capacity]
        let secondPart = storage[0 ..< writeIndex]
        return Array(firstPart) + Array(secondPart)
    }

    public mutating func clear() {
        writeIndex = 0
        count = 0
    }
}
