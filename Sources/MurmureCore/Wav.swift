import Foundation

/// 16-bit PCM mono WAV, the format voiced (and Orb's worker) accepts.
public enum Wav {
    public static func encode(_ samples: ArraySlice<Float>, sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    public static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        encode(samples[...], sampleRate: sampleRate)
    }
}
