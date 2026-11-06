import Foundation
@testable import PaddleCore
import Testing

struct BridgeLimitsTests {
    private func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }

    @Test func limitsAreTheDecidedOnes() {
        #expect(BridgeLimits.maxClients == 8)
        #expect(BridgeLimits.maxPendingCalls == 16)
        #expect(BridgeLimits.writeTimeoutSeconds == 5)
        #expect(BridgeLimits.maxLineBytes == 1_048_576)
    }

    @Test func splitsLinesAcrossReads() {
        var splitter = BridgeLineSplitter()
        #expect(splitter.append(bytes("{\"a\":1}\n{\"b\"")) == .init(lines: ["{\"a\":1}"], overflow: false))
        #expect(splitter.append(bytes(":2}\r\n\n  \n{\"c\":3}\n")) == .init(lines: ["{\"b\":2}", "{\"c\":3}"], overflow: false))
        #expect(splitter.append(bytes("")) == .init(lines: [], overflow: false))
    }

    @Test func manyLinesInOneReadAreAllReturned() {
        var splitter = BridgeLineSplitter()
        let text = (0..<5000).map { "line\($0)\n" }.joined()
        let out = splitter.append(bytes(text))
        #expect(out.lines.count == 5000)
        #expect(out.lines.last == "line4999")
    }

    @Test func overLongUnfinishedLineOverflows() {
        var splitter = BridgeLineSplitter(maxLineBytes: 10)
        #expect(!splitter.append(bytes("0123456789")).overflow)
        #expect(splitter.append(bytes("x")).overflow)
    }

    @Test func overLongFinishedLineOverflows() {
        var splitter = BridgeLineSplitter(maxLineBytes: 10)
        #expect(splitter.append(bytes("0123456789ab\nok\n")).overflow)
        var exact = BridgeLineSplitter(maxLineBytes: 10)
        #expect(exact.append(bytes("0123456789\n")) == .init(lines: ["0123456789"], overflow: false))
    }

    @Test func busyReplyCarriesTheRequestID() throws {
        let reply = try #require(BridgeLimits.busyReply(forLine: #"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32000)
        let named = try #require(BridgeLimits.busyReply(forLine: #"{"id":"abc","method":"x"}"#))
        #expect(named.contains("\"abc\""))
    }

    @Test func busyReplyIsNilWithoutAnID() {
        #expect(BridgeLimits.busyReply(forLine: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(BridgeLimits.busyReply(forLine: #"{"id":null}"#) == nil)
        #expect(BridgeLimits.busyReply(forLine: "not json") == nil)
    }

    @Test func urlsAreCutAndOversizedImagesRefused() {
        let long = "https://example.com/?" + String(repeating: "a", count: 5_000)
        let cut = BridgeLimits.url(long)
        #expect(cut.count == BridgeLimits.maxURLChars)
        #expect(cut.hasSuffix("\u{2026}"))
        #expect(BridgeLimits.url("https://example.com/") == "https://example.com/")

        let fits = MCPToolResult(content: [.image(base64: String(repeating: "A", count: 1_000), mimeType: "image/png")])
        #expect(BridgeLimits.clamped(fits).isError == false)
        let huge = MCPToolResult(content: [.image(base64: String(repeating: "A", count: BridgeLimits.maxImageChars + 1), mimeType: "image/png")])
        #expect(BridgeLimits.clamped(huge).isError == true)
    }
}
