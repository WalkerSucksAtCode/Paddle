import Foundation
@testable import PaddleCore
import Testing
import WebKit

struct FilterListConverterTests {
    func rules(_ text: String) throws -> [[String: Any]] {
        let json = FilterListConverter.convert(text).json
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
    func action(_ rule: [String: Any]) -> [String: Any] { rule["action"] as? [String: Any] ?? [:] }

    func filterMatches(_ filter: String, _ url: String) -> Bool {
        let re = try! NSRegularExpression(pattern: filter, options: [.caseInsensitive])
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func hostAnchorMatchesHostAndSubdomainsOnly() throws {
        let r = try rules("||ads.example.com^")
        #expect(r.count == 1)
        let filter = try #require(trigger(r[0])["url-filter"] as? String)
        #expect(action(r[0])["type"] as? String == "block")
        #expect(filterMatches(filter, "https://ads.example.com/x.js"))
        #expect(filterMatches(filter, "https://cdn.ads.example.com/x.js"))
        #expect(filterMatches(filter, "http://ads.example.com:8080/"))
        #expect(!filterMatches(filter, "https://ads.example.community/"))
        #expect(!filterMatches(filter, "https://notads.example.com/"))
        #expect(!filterMatches(filter, "https://site.test/?u=ads.example.com"))
    }

    @Test func optionsMapToTriggerFields() throws {
        let r = try rules("||tracker.test^$script,third-party,domain=a.test|b.test")
        let t = trigger(r[0])
        #expect(t["resource-type"] as? [String] == ["script"])
        #expect(t["load-type"] as? [String] == ["third-party"])
        #expect(t["if-domain"] as? [String] == ["*a.test", "*b.test"])
    }

    @Test func negatedTypesBecomeComplement() throws {
        let types = try #require(trigger(try rules("/banner/*$~image")[0])["resource-type"] as? [String])
        #expect(!types.contains("image"))
        #expect(types.contains("script"))
    }

    @Test func exceptionsComeLast() throws {
        let r = try rules("@@||good.test^\n||bad.test^\nexample.com##.ad\n##.banner")
        #expect(r.count == 4)
        #expect(action(r[3])["type"] as? String == "ignore-previous-rules")
        #expect(action(r[0])["type"] as? String == "block")
    }

    @Test func documentExceptionAllowlistsSite() throws {
        let r = try rules("@@||mybank.test^$document")
        #expect(trigger(r[0])["if-domain"] as? [String] == ["*mybank.test"])
        #expect(trigger(r[0])["url-filter"] as? String == ".*")
        #expect(action(r[0])["type"] as? String == "ignore-previous-rules")
    }

    @Test func cosmeticRulesAreChunkedAndScoped() throws {
        let generic = (0..<40).map { "##.ad\($0)" }.joined(separator: "\n")
        let r = try rules(generic + "\nsite.test,~sub.site.test##.promo\n~other.test##.x")
        // 40 generic selectors in chunks of 32 = 2 rules, plus 2 domain rules.
        #expect(r.count == 4)
        #expect(action(r[0])["selector"] as? String == (0..<32).map { ".ad\($0)" }.joined(separator: ", "))
        #expect(trigger(r[2])["if-domain"] as? [String] == ["*site.test"])
        #expect(trigger(r[3])["unless-domain"] as? [String] == ["*other.test"])
    }

    @Test func unsupportedSyntaxIsSkippedNotGuessed() {
        let text = """
        ! comment
        [Adblock Plus 2.0]
        /ads\\d+\\.js/
        example.com#@#.ad
        example.com##+js(nowebrtc)
        example.com#?#div:has-text(Sponsored)
        ||x.test^$redirect=noop.js
        ||y.test^$csp=script-src 'none'
        ||ok.test^
        """
        let result = FilterListConverter.convert(text)
        #expect(result.ruleCount == 1)
        #expect(result.skippedLines == 6)
    }

    @Test func wildcardAndSeparator() {
        let filter = FilterListConverter.urlFilter("/ads/*/banner^")!
        #expect(filterMatches(filter, "https://x.test/ads/123/banner?x"))
        #expect(!filterMatches(filter, "https://x.test/ads/123/bannerx"))
        #expect(FilterListConverter.urlFilter("|https://a.test/x.js|") == "^https://a\\.test/x\\.js$")
    }

    /// The real proof: WebKit itself accepts the generated JSON.
    @MainActor
    @Test func webKitCompilesOutput() async throws {
        let text = """
        ||ads.example.com^
        ||tracker.test^$script,third-party,domain=a.test|~b.test
        /banner/*$~image
        @@||good.test^
        @@||mybank.test^$document
        ##.ad-slot
        ##div[id^="google_ads"]
        site.test##.promo
        |https://exact.test/x.js|
        """
        let result = FilterListConverter.convert(text)
        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")))
        let list = try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: result.json)
        #expect(list != nil)
    }
}
