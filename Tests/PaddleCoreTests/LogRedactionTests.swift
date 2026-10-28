import Foundation
@testable import PaddleCore
import Testing

struct LogRedactionTests {
    @Test func redactsSchemeSlashForms() {
        #expect(LogRedaction.redactURLs("bad url https://example.com/a?b=1 here") == "bad url <url> here")
        #expect(LogRedaction.redactURLs("https://example.com") == "<url>")
        #expect(LogRedaction.redactURLs("chrome-extension://abc/page.html") == "<url>")
    }

    @Test func redactsSchemesWithoutSlashes() {
        #expect(LogRedaction.redactURLs("x data:text/html,<b>hi y") == "x <url> y")
        #expect(LogRedaction.redactURLs("to mailto:me@example.com now") == "to <url> now")
        #expect(LogRedaction.redactURLs("javascript:alert(1)") == "<url>")
        #expect(LogRedaction.redactURLs("file:///Users/me/secret.html") == "<url>")
        #expect(LogRedaction.redactURLs("blob:https://example.com/uuid") == "<url>")
        #expect(LogRedaction.redactURLs("JAVASCRIPT:void(0)") == "<url>")
    }

    @Test func keepsOrdinaryText() {
        let text = "NSInvalidArgumentException: key: value at 12:30:45 in -[Foo bar:]"
        #expect(LogRedaction.redactURLs(text) == text)
    }
}
