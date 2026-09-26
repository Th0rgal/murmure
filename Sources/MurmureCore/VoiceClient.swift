import Darwin
import Foundation

public struct VoiceError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
}

public struct Transcript: Sendable {
    public let text: String
    public let durationSecs: Double
    public let inferSecs: Double
}

/// Blocking client for voiced's protocol v1 over a Unix socket (the same
/// framing Orb's worker uses on stdio). Not thread-safe: drive it from one
/// serial queue.
public final class VoiceClient {
    public static var defaultSocketPath: String {
        if let p = ProcessInfo.processInfo.environment["VOICED_SOCKET"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/Library/Application Support/md.thomas.voice/voiced.sock"
    }

    public let path: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextId = 0

    public init(path: String = VoiceClient.defaultSocketPath) { self.path = path }
    deinit { close() }

    public var isConnected: Bool { fd >= 0 }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buffer.removeAll()
    }

    func connect() throws {
        if fd >= 0 { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw VoiceError("io", "socket(): \(errno)") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(s); throw VoiceError("io", "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(s)
            throw VoiceError("daemon_missing", "voiced is not reachable at \(path) (errno \(e)). Run scripts/install-voiced.sh.")
        }
        fd = s
    }

    private func setTimeout(_ secs: Double) {
        var tv = timeval(tv_sec: Int(secs), tv_usec: Int32((secs - Double(Int(secs))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VoiceError("worker_exited", "write failed (errno \(errno))")
                }
                off += n
            }
        }
    }

    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< nl]
                buffer.removeSubrange(buffer.startIndex ... nl)
                return Data(line)
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0 ..< n])
                if buffer.count > 1 << 20 { throw VoiceError("protocol", "response too large") }
            } else if n == 0 {
                throw VoiceError("worker_exited", "voiced closed the connection")
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw VoiceError("timeout", "voiced did not answer in time")
            } else {
                throw VoiceError("worker_exited", "read failed (errno \(errno))")
            }
        }
    }

    /// One request/response round trip. Reconnects once if the daemon went
    /// away between requests (launchd restarts it on connect).
    public func request(_ op: String, fields: [String: Any] = [:], payload: Data? = nil, timeout: Double = 120) throws -> [String: Any] {
        do {
            return try roundTrip(op, fields: fields, payload: payload, timeout: timeout)
        } catch let e as VoiceError where e.code == "worker_exited" {
            close()
            return try roundTrip(op, fields: fields, payload: payload, timeout: timeout)
        }
    }

    private func roundTrip(_ op: String, fields: [String: Any], payload: Data?, timeout: Double) throws -> [String: Any] {
        try connect()
        setTimeout(timeout)
        nextId += 1
        var req = fields
        req["id"] = nextId
        req["op"] = op
        if let payload { req["audio_bytes"] = payload.count }
        var frame = try JSONSerialization.data(withJSONObject: req)
        frame.append(0x0A)
        if let payload { frame.append(payload) }
        do {
            try writeAll(frame)
            let line = try readLine()
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["id"] as? Int) == nextId
            else { throw VoiceError("protocol", "malformed or out-of-order response") }
            if obj["ok"] as? Bool == true { return obj["result"] as? [String: Any] ?? [:] }
            let err = obj["error"] as? [String: Any] ?? [:]
            throw VoiceError(err["code"] as? String ?? "internal", err["message"] as? String ?? "voiced error")
        } catch let e as VoiceError where ["timeout", "protocol", "worker_exited"].contains(e.code) {
            close()  // stream state unknown: never reuse it
            throw e
        }
    }

    public func hello() throws -> [String: Any] { try request("hello", timeout: 10) }

    public func load() throws { _ = try request("load", timeout: 240) }

    public func transcribe(wav: Data, language: String) throws -> Transcript {
        let r = try request("transcribe", fields: ["language": language, "punctuation": true], payload: wav, timeout: 240)
        return Transcript(
            text: r["text"] as? String ?? "",
            durationSecs: r["duration_secs"] as? Double ?? 0,
            inferSecs: r["infer_secs"] as? Double ?? 0
        )
    }
}
