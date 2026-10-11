import Foundation
@testable import PaddleCore
import Testing

struct AddressResolverTests {
    let resolver = AddressResolver(searchTemplate: "https://search.test/?q=%s")

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("example.com/path?x=1", "https://example.com/path?x=1"),
        ("https://example.com/a", "https://example.com/a"),
        ("http://example.com", "http://example.com"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost", "http://localhost"),
        ("127.0.0.1:8080/x", "http://127.0.0.1:8080/x"),
        ("app.test", "http://app.test"),
        ("sub.domain.co.uk", "https://sub.domain.co.uk"),
        ("about:blank", "about:blank"),
        ("file:///Users/x/a.html", "file:///Users/x/a.html"),
    ])
    func resolvesAddresses(input: String, expected: String) {
        #expect(resolver.resolve(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("swift concurrency", "https://search.test/?q=swift%20concurrency"),
        ("what is 2+2?", "https://search.test/?q=what%20is%202%2B2%3F"),
        ("hello", "https://search.test/?q=hello"),
        ("version 1.2", "https://search.test/?q=version%201.2"),
        ("javascript:alert(1)", "https://search.test/?q=javascript:alert(1)"),
        ("a&b=c", "https://search.test/?q=a%26b%3Dc"),
    ])
    func searchesEverythingElse(input: String, expected: String) {
        #expect(resolver.resolve(input)?.absoluteString == expected)
    }

    @Test func emptyInputIsNil() {
        #expect(resolver.resolve("   ") == nil)
    }
}
