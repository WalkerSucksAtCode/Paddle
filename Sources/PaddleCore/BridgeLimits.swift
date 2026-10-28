import Foundation

/// The control bridge's resource limits and the line splitter that enforces the size limit.
public enum BridgeLimits {
    /// Connected clients at once; more are refused.
    public static let maxClients = 8
    /// Calls one client may have unanswered; more are answered with a JSON-RPC error.
    public static let maxPendingCalls = 16
    /// Seconds a write to a client may block before the client is dropped.
    public static let writeTimeoutSeconds = 5
    /// The longest single line taken (1 MB); a client that sends more is dropped.
    public static let maxLineBytes = 1 << 20

    /// The JSON-RPC error answering a request line refused for being over the pending-calls limit, carrying the
    /// request's id. Nil for a line with no id (a notification) or one that isn't a JSON object: nothing to answer.
    public static func busyReply(forLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"], id is String || id is NSNumber else { return nil }
        let reply: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32000, "message": "too many calls in flight (at most \(maxPendingCalls)); wait for an answer"],
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Splits a byte stream into lines without copying the buffer after every newline: lines are cut by index, and the
/// unfinished tail moves down once per `append`.
public struct BridgeLineSplitter {
    public struct Output: Equatable {
        public var lines: [String]
        /// A line (finished or not) is longer than the limit: the client should be dropped.
        public var overflow: Bool
    }

    private var buffer: [UInt8] = []
    /// The first byte not yet looked at for a newline.
    private var scanned = 0
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = BridgeLimits.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Adds `bytes` and returns the lines now complete: a trailing carriage return removed, blank lines left out.
    public mutating func append(_ bytes: ArraySlice<UInt8>) -> Output {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        var index = scanned
        while index < buffer.count {
            if buffer[index] == 0x0A {
                var end = index
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                if index - start > maxLineBytes {
                    buffer.removeAll()
                    scanned = 0
                    return Output(lines: lines, overflow: true)
                }
                let line = String(decoding: buffer[start..<end], as: UTF8.self)
                if !line.allSatisfy(\.isWhitespace) { lines.append(line) }
                start = index + 1
            }
            index += 1
        }
        if start > 0 { buffer.removeSubrange(0..<start) }
        scanned = buffer.count
        if buffer.count > maxLineBytes {
            buffer.removeAll()
            scanned = 0
            return Output(lines: lines, overflow: true)
        }
        return Output(lines: lines, overflow: false)
    }
}
