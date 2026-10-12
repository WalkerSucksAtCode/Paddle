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

    /// `{style}` and `:style(` lines inject CSS; they are counted apart and must never become `display: none`
    /// (one accepted as a selector would hide `body`).
    @Test func styleRulesAreCountedAndNeverHidden() {
        let text = """
        hindustantimes.com##body {padding-top:0;}
        ##[role="banner"] {top:0 !important}
        example.com##.sticky:style(position: static !important)
        example.com##[data-testid="box"] {remove:true;}
        ##.ok
        """
        let result = FilterListConverter.convert(text)
        #expect(result.styleInjection == 4)
        #expect(result.skippedLines == 0)
        #expect(result.invalidSelectors == 0)
        #expect(result.ruleCount == 1)
        #expect(!result.json.contains("body"))
        #expect(!result.json.contains("banner"))
    }

    @Test func nestedHasAndUnbalancedSelectorsAreInvalid() {
        let text = """
        ##article:has(header:has(.ct-sponsored))
        ##div > [style]:has([style]:has([href*="&utm"]))
        ##div[class="a
        ##a:has(.b
        ##span[title="x"
        ##li:is(.a, .b):has(> .c)
        ##a[title="(x"]
        ##.bg-white\\/50.p-8
        ##div:not(:has(.x)) + p:has(.y)
        """
        let result = FilterListConverter.convert(text)
        #expect(result.invalidSelectors == 5)
        #expect(result.skippedLines == 0)
        #expect(result.ruleCount == 1)
        #expect(result.json.contains(#"li:is(.a, .b):has(> .c), a[title=\"(x\"], .bg-white\\/50.p-8, div:not(:has(.x)) + p:has(.y)"#))
        #expect(FilterListConverter.classifySelector(":HAS(a:has(b))") == .invalid)
        #expect(FilterListConverter.classifySelector("div:has-text(Ad)") == .unsupported)
        #expect(FilterListConverter.classifySelector("") == .unsupported)
    }

    /// The validator sees every chunk first, then only the members of failing chunks; just the bad selector
    /// goes, its chunk-mates stay.
    @Test func validatorDropsExactlyTheBadSelector() async {
        let text = "##.keep1\n##div:bogus(x)\n##.keep2\nsite.test##.promo\nsite.test##p:nope\nother.test##.fine"
        let calls = Calls()
        let result = await FilterListConverter.convert(text, cosmeticChunkSize: 32) { strings in
            await calls.record(strings)
            return strings.map { !$0.contains("bogus") && !$0.contains("nope") }
        }
        #expect(result.invalidSelectors == 2)
        #expect(result.ruleCount == 3)
        #expect(result.json.contains(#""selector":".keep1, .keep2""#))
        #expect(result.json.contains(#""selector":".promo""#))
        #expect(result.json.contains(#""selector":".fine""#))
        let recorded = await calls.batches
        #expect(recorded.count == 2)
        #expect(recorded[0] == [".keep1, div:bogus(x), .keep2", ".promo, p:nope", ".fine"])
        #expect(recorded[1] == [".keep1", "div:bogus(x)", ".keep2", ".promo", "p:nope"])

        // A chunk whose every selector fails disappears rather than becoming an empty rule.
        let gone = await FilterListConverter.convert("site.test##p:nope") { $0.map { _ in false } }
        #expect(gone.ruleCount == 0)
        #expect(gone.invalidSelectors == 1)
        #expect(gone.json == "[]")
    }

    /// A validator that cannot answer (wrong length) changes nothing: the result is the unvalidated one.
    @Test func validatorFailureAcceptsEverything() async throws {
        let text = "##.a\n##.b\nsite.test##.c"
        let plain = FilterListConverter.convert(text)
        let broken = await FilterListConverter.convert(text) { _ in [] }
        // Compared as objects: JSONEncoder does not promise key order.
        let plainRules = try JSONSerialization.jsonObject(with: Data(plain.json.utf8)) as? NSArray
        let brokenRules = try JSONSerialization.jsonObject(with: Data(broken.json.utf8)) as? NSArray
        #expect(brokenRules == plainRules)
        #expect(broken.ruleCount == 2)
        #expect(broken.invalidSelectors == 0)
    }

    actor Calls {
        var batches: [[String]] = []
        func record(_ strings: [String]) { batches.append(strings) }
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

    /// A chunk with one selector WebKit's parser refuses, validated by that parser (`document.querySelector` in a
    /// windowless web view, as the app does): the bad one goes, the neighbours stay in the JSON, and WebKit
    /// compiles the result. Unvalidated, WebKit would drop the whole chunk and the neighbours with it.
    @MainActor
    @Test func webKitValidatedChunkKeepsItsNeighbours() async throws {
        let text = """
        ||ads.example.com^
        ##.keep-before
        ##div:bogus-pseudo(x)
        ##.keep-after
        site.test##.promo
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let result = await FilterListConverter.convert(text) { await Self.querySelectorAccepts($0, in: webView) }
        #expect(result.invalidSelectors == 1)
        #expect(result.json.contains(#""selector":".keep-before, .keep-after""#))
        #expect(result.json.contains(#""selector":".promo""#))
        #expect(!result.json.contains("bogus"))
        #expect(result.ruleCount == 3)

        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")))
        let list = try await store.compileContentRuleList(forIdentifier: "validated", encodedContentRuleList: result.json)
        #expect(list != nil)
    }

    @MainActor
    static func querySelectorAccepts(_ selectors: [String], in webView: WKWebView) async -> [Bool] {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: selectors), as: UTF8.self)
        let script = "(function (a) { return a.map(s => { try { document.querySelector(s); return true } catch (e) { return false } }) })(\(json))"
        return (try? await webView.evaluateJavaScript(script) as? [Bool]) ?? []
    }
}
