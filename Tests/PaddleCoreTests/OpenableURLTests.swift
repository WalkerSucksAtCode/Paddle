import Foundation
@testable import PaddleCore
import Testing

struct OpenableURLTests {
    func ok(_ s: String) -> Bool { OpenableURL.isAllowed(URL(string: s)!) }

    @Test func webAndAboutAreAllowed() {
        #expect(ok("https://example.com/"))
        #expect(ok("HTTP://example.com"))
        #expect(ok("about:blank"))
    }

    @Test func otherSchemesAreRefused() {
        for s in ["javascript:alert(1)", "data:text/html,hi", "ftp://example.com/", "blob:https://a/b", "mailto:a@b.c",
                  "view-source:https://a.b", "chrome-extension://x/y.html", "x-unknown:foo"] {
            #expect(!ok(s), "\(s)")
        }
    }

    @Test func filesOnlyForDeclaredDocumentTypes() {
        #expect(ok("file:///Users/me/page.html"))
        #expect(ok("file:///Users/me/page.HTM"))
        #expect(ok("file:///Users/me/a.xhtml"))
        #expect(ok("file:///Users/me/a.webarchive"))
        #expect(ok("file://localhost/Users/me/a.html"))
        #expect(!ok("file:///Users/me/a.pdf"))
        #expect(!ok("file:///Users/me/a.txt"))
        #expect(!ok("file:///Users/me/"))
        #expect(!ok("file:///etc/passwd"))
        #expect(!ok("file://server/share/a.html"))
    }
}
