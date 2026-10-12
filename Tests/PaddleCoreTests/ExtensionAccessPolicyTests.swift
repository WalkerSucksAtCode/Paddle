import Foundation
@testable import PaddleCore
import Testing

struct ExtensionAccessPolicyTests {
    typealias Policy = ExtensionAccessPolicy

    @Test func onlyTablessURLRequestsWithoutAGestureAreAutoDenied() {
        for kind in [Policy.Kind.urls, .permissions, .matchPatterns] {
            for hasTab in [false, true] {
                for gesture in [false, true] {
                    let expected: Policy.Decision = kind == .urls && !hasTab && !gesture ? .autoDeny : .prompt
                    #expect(Policy.classify(kind: kind, hasTab: hasTab, recentGesture: gesture) == expected,
                            "\(kind) hasTab=\(hasTab) gesture=\(gesture)")
                }
            }
        }
    }

    @Test(arguments: [
        ("https://www.Example.COM/login?x=1", "example.com"),
        ("http://ads.example.com:8080/a.js", "ads.example.com"),
        ("https://example.com./", "example.com"),
        ("https://WWW.example.co.uk/", "example.co.uk"),
        ("https://www.com/", "www.com"),
        ("https://www2.example.com/", "www2.example.com"),
        ("http://192.168.1.1/admin", "192.168.1.1"),
        ("http://localhost:3000/", "localhost"),
        ("http://[::1]:8080/", "::1"),
    ])
    func denialKeyIsTheSite(url: String, key: String) {
        #expect(Policy.denialKey(URL(string: url)!) == key)
    }

    @Test func pagesOnOneSiteShareAKey() {
        let urls = ["https://example.com/a", "https://www.example.com/b?q", "http://EXAMPLE.com/"]
        #expect(Set(urls.map { Policy.denialKey(URL(string: $0)!) }) == ["example.com"])
    }

    @Test func hostlessURLIsItsOwnKey() {
        #expect(Policy.denialKey(URL(string: "about:blank")!) == "about:blank")
    }

    @Test func grantPatternsCoverTheWWWForm() {
        #expect(Policy.grantPatterns(forKey: "example.com") == ["*://example.com/*", "*://www.example.com/*"])
        #expect(Policy.grantPatterns(forKey: "localhost") == ["*://localhost/*"])
        #expect(Policy.grantPatterns(forKey: "10.0.0.2") == ["*://10.0.0.2/*"])
        #expect(Policy.grantPatterns(forKey: "::1") == ["*://[::1]/*"])
    }
}
