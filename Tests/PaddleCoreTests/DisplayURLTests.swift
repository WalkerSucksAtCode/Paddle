import Foundation
@testable import PaddleCore
import Testing

struct DisplayURLTests {
    func shown(_ s: String) -> String { DisplayURL.string(URL(string: s)!) }

    @Test func dropsUserinfo() {
        #expect(shown("https://google.com@evil.com/") == "https://evil.com/")
        #expect(shown("https://user:pass@example.com:8080/a?b=1#c") == "https://example.com:8080/a?b=1#c")
        #expect(shown("ftp://me@example.com/x") == "ftp://example.com/x")
    }

    @Test func leavesOthersAlone() {
        #expect(shown("https://example.com/a") == "https://example.com/a")
        #expect(shown("https://example.com/a?mail=me@x.com") == "https://example.com/a?mail=me@x.com")
        #expect(shown("mailto:me@example.com") == "mailto:me@example.com")
    }
}
