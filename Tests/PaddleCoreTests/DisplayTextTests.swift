import Testing
@testable import PaddleCore

struct DisplayTextTests {
    @Test func newlinesBecomeSpaces() {
        #expect(DisplayText.cleaned("a\nb\r\nc\td") == "a b  c d")
    }

    @Test func dropsControlAndBidi() {
        #expect(DisplayText.cleaned("a\u{0}b\u{202E}c\u{2067}d\u{7}") == "abcd")
    }

    @Test func keepsPrefix() {
        #expect(DisplayText.cleaned(String(repeating: "x", count: 500)).count == 200)
        #expect(DisplayText.cleaned("abcdef", limit: 3) == "abc")
    }
}
