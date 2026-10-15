import Foundation
import Testing

@testable import PaddleCore

struct HTTPSOnlyPolicyTests {
    private func upgrade(
        _ text: String, enabled: Bool = true, siteAllowsHTTP: Bool = false, exceptions: Set<String> = []
    ) -> String? {
        HTTPSOnlyPolicy.upgrade(URL(string: text)!, enabled: enabled, siteAllowsHTTP: siteAllowsHTTP, sessionExceptions: exceptions)?
            .absoluteString
    }

    @Test func upgradesKeepingEverythingElse() {
        #expect(upgrade("http://example.com/a/b?q=1#frag") == "https://example.com/a/b?q=1#frag")
        #expect(upgrade("http://example.com:80/x") == "https://example.com/x")
        #expect(upgrade("http://example.com:8080/x") == "https://example.com:8080/x")
        #expect(upgrade("HTTP://Example.com/") == "https://Example.com/")
    }

    @Test func noUpgradeWhenNotApplicable() {
        #expect(upgrade("http://example.com/", enabled: false) == nil)
        #expect(upgrade("https://example.com/") == nil)
        #expect(upgrade("ftp://example.com/") == nil)
        #expect(upgrade("http://example.com/", siteAllowsHTTP: true) == nil)
        #expect(upgrade("http:///path") == nil)
    }

    @Test func sessionExceptionsMatchWithAndWithoutWww() {
        #expect(upgrade("http://example.com/", exceptions: ["example.com"]) == nil)
        #expect(upgrade("http://www.example.com/", exceptions: ["example.com"]) == nil)
        #expect(upgrade("http://example.com/", exceptions: ["www.example.com"]) == nil)
        #expect(upgrade("http://other.com/", exceptions: ["example.com"]) == "https://other.com/")
    }

    @Test func localHostsAreExempt() {
        for host in ["localhost", "app.localhost", "printer.local", "router.home.arpa", "nas.internal", "intranet",
                     "127.0.0.1", "127.9.9.9", "10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.1.1", "169.254.1.1",
                     "[::1]", "[fc00::1]", "[fd12:3456::1]", "[fe80::1]", "[febf::1]"] {
            #expect(upgrade("http://\(host)/") == nil, "\(host)")
        }
    }

    @Test func publicHostsAreNotLocal() {
        for host in ["example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.1.1", "11.0.0.1", "[2001:db8::1]",
                     "[fec0::1]", "localhost.example.com"] {
            #expect(upgrade("http://\(host)/") != nil, "\(host)")
        }
    }

    @Test func configAndSiteDecode() throws {
        #expect(PaddleConfig().httpsOnly)
        #expect(try PaddleConfig.decode(Data(#"{"httpsOnly": false}"#.utf8)).httpsOnly == false)
        let config = try PaddleConfig.decode(Data(#"{"sites": {"a.com": {"httpsOnly": false}}}"#.utf8))
        #expect(config.siteSettings(forHost: "www.a.com").httpsOnly == false)
        #expect(config.sitePolicy(forHost: "b.com").httpsOnly)
        #expect(!config.sitePolicy(forHost: "a.com").httpsOnly)
    }
}
