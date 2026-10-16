import Foundation
import PaddleCore
import Testing

struct PreconnectPolicyTests {
    @Test func originDropsPathQueryAndCase() {
        #expect(PreconnectPolicy.origin(of: URL(string: "https://WWW.Example.com/a/b?q=1#x"))?.absoluteString == "https://www.example.com")
        #expect(PreconnectPolicy.origin(of: URL(string: "http://example.com:8080/x"))?.absoluteString == "http://example.com:8080")
        #expect(PreconnectPolicy.origin(of: URL(string: "http://localhost:3000/"))?.absoluteString == "http://localhost:3000")
        #expect(PreconnectPolicy.origin(of: URL(string: "http://127.0.0.1/"))?.absoluteString == "http://127.0.0.1")
    }

    @Test func onlyWebSitesQualify() {
        for text in ["mailto:a@example.com", "file:///tmp/x.html", "javascript:", "paddle://settings", "https://exampl/", "https://example./", "about:blank"] {
            #expect(PreconnectPolicy.origin(of: URL(string: text)) == nil, "\(text)")
        }
        #expect(PreconnectPolicy.origin(of: nil) == nil)
    }

    @Test func sameOriginWarmsOncePerInterval() {
        var policy = PreconnectPolicy(interval: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(policy.originToWarm(URL(string: "https://a.test/1"), now: start) != nil)
        #expect(policy.originToWarm(URL(string: "https://a.test/2"), now: start.addingTimeInterval(5)) == nil)
        #expect(policy.originToWarm(URL(string: "https://b.test/"), now: start.addingTimeInterval(5)) != nil)
        #expect(policy.originToWarm(URL(string: "https://a.test/3"), now: start.addingTimeInterval(31)) != nil)
    }
}
