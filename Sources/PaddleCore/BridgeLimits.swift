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
    /// The most characters of text one tool result carries (about 200 KB): page text, script results and anything a
    /// page can inflate are cut to it before the reply is built.
    public static let maxReplyChars = 200_000
    /// The most characters of a page-written title in a tool result.
    public static let maxTitleChars = 300
    /// The most characters of a page-written URL in a tool result: a page can inflate a query string without end,
    /// and one such URL would otherwise push a whole state listing past the reply clamp and get it cut wholesale.
    public static let maxURLChars = 2_000
    /// The most characters of base64 image one tool result carries (about 768 KB of PNG). The line the server sends
    /// to the client has no cap in that direction, so this is the cap.
    public static let maxImageChars = 768_000

    /// `text` cut to `limit` characters with a note saying how much was dropped, or `text` itself when it fits.
    public static func truncated(_ text: String, limit: Int) -> String {
        // UTF-16 length bounds the character count from above: most replies are decided without walking the string.
        guard text.utf16.count > limit else { return text }
        let total = text.count
        guard total > limit else { return text }
        return String(text.prefix(limit)) + "\n[truncated: \(limit) of \(total) characters]"
    }

    /// A page title cut to `maxTitleChars`, ending in an ellipsis when cut.
    public static func title(_ text: String) -> String {
        guard text.utf16.count > maxTitleChars, text.count > maxTitleChars else { return text }
        return String(text.prefix(maxTitleChars - 1)) + "\u{2026}"
    }

    /// A page URL cut to `maxURLChars`, ending in an ellipsis when cut.
    public static func url(_ text: String) -> String {
        guard text.utf16.count > maxURLChars, text.count > maxURLChars else { return text }
        return String(text.prefix(maxURLChars - 1)) + "\u{2026}"
    }

    /// Room past `maxReplyChars` for what a tool adds around text it already cut: the untrusted-content tags, a
    /// heading note, the truncation note.
    public static let replyOverheadChars = 1_000

    /// The backstop for every reply: each text item cut to `maxReplyChars` once it passes that plus
    /// `replyOverheadChars` (a tool that cut its own text stays as it is), the closing untrusted-content tag kept.
    /// An image past `maxImageChars` (a tall window) is refused rather than sent as a multi-megabyte line.
    public static func clamped(_ result: MCPToolResult) -> MCPToolResult {
        var result = result
        if result.content.contains(where: { item in
            if case .image(let base64, _) = item { return base64.count > maxImageChars }
            return false
        }) {
            return .error("the snapshot is too large to send; shrink the window and try again")
        }
        result.content = result.content.map { item in
            guard case .text(let text) = item, text.utf16.count > maxReplyChars + replyOverheadChars,
                  text.count > maxReplyChars + replyOverheadChars else { return item }
            let close = "\n</untrusted-page-content>"
            let wrapped = text.hasSuffix(close)
            let cut = truncated(wrapped ? String(text.dropLast(close.count)) : text, limit: maxReplyChars)
            return .text(wrapped ? cut + close : cut)
        }
        return result
    }

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
