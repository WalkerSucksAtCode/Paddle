import Foundation
@testable import PaddleCore
import Testing

struct WebKitRuleEvaluatorTests {
    typealias Request = WebKitRuleEvaluator.Request

    /// One rule object as the converter writes it. `trigger` adds trigger keys next to `url-filter`.
    func rule(_ urlFilter: String, action: String = "block", trigger extra: [String: Any] = [:]) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": urlFilter]
        for (key, value) in extra { trigger[key] = value }
        return ["trigger": trigger, "action": ["type": action]]
    }

    /// The decision from the indexed path, which must agree with brute force on the same request.
    func decide(_ evaluator: WebKitRuleEvaluator, _ request: Request) -> WebKitRuleEvaluator.Decision {
        let indexed = evaluator.evaluate(request)
        #expect(indexed == evaluator.evaluateBruteForce(request), "index disagrees with brute force for \(request.url)")
        return indexed
    }

    @Test func blockMatchesAnywhereInTheURL() {
        let e = WebKitRuleEvaluator(rules: [rule("ads\\.example\\.com")])
        #expect(decide(e, Request(url: "https://ads.example.com/x.js")).blocked)
        #expect(decide(e, Request(url: "https://site.test/?u=ads.example.com")).blocked)
        #expect(!decide(e, Request(url: "https://adsXexample.com/")).blocked)
    }

    @Test func ignorePreviousClearsAnEarlierBlock() {
        let e = WebKitRuleEvaluator(rules: [rule("banner"), rule("/banner/ok", action: "ignore-previous-rules")])
        #expect(decide(e, Request(url: "https://cdn.test/banner/a.gif")).blocked)
        #expect(!decide(e, Request(url: "https://cdn.test/banner/ok.gif")).blocked)
    }

    @Test func blockAfterIgnoreStillBlocks() {
        let e = WebKitRuleEvaluator(rules: [rule("/ads/", action: "ignore-previous-rules"), rule("/ads/")])
        let decision = decide(e, Request(url: "https://x.test/ads/a.js"))
        #expect(decision.blocked)
        #expect(decision.decidingRule == 1)
        #expect(decision.decidingURLFilter == "/ads/")
    }

    @Test func caseInsensitiveUnlessCaseSensitive() {
        let loose = WebKitRuleEvaluator(rules: [rule("/Ads/")])
        #expect(decide(loose, Request(url: "https://x.test/ads/a.js")).blocked)
        let strict = WebKitRuleEvaluator(rules: [rule("/Ads/", trigger: ["url-filter-is-case-sensitive": true])])
        #expect(!decide(strict, Request(url: "https://x.test/ads/a.js")).blocked)
        #expect(decide(strict, Request(url: "https://x.test/Ads/a.js")).blocked)
    }

    @Test func resourceTypeLimitsTheRule() {
        let e = WebKitRuleEvaluator(rules: [rule("/track", trigger: ["resource-type": ["image", "script"]])])
        #expect(decide(e, Request(url: "https://t.test/track.gif", resourceType: "image")).blocked)
        #expect(decide(e, Request(url: "https://t.test/track.js", resourceType: "script")).blocked)
        #expect(!decide(e, Request(url: "https://t.test/track.json", resourceType: "raw")).blocked)
    }

    @Test func webKitTypeNamesForUBOTypes() {
        #expect(WebKitRuleEvaluator.webKitType(uboType: "xmlhttprequest") == "raw")
        #expect(WebKitRuleEvaluator.webKitType(uboType: "sub_frame") == "document")
        #expect(WebKitRuleEvaluator.webKitType(uboType: "stylesheet") == "style-sheet")
        #expect(WebKitRuleEvaluator.webKitType(uboType: "image") == "image")
        #expect(WebKitRuleEvaluator.webKitType(uboType: "webtransport") == nil)
    }

    @Test func thirdPartyUsesTheRegistrableDomain() {
        let e = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["load-type": ["third-party"]])])
        let source = "https://news.example.co.uk/story"
        // A "last two labels" rule would call every .co.uk host first-party.
        #expect(decide(e, Request(url: "https://ads.other.co.uk/ad/1.js", sourceURL: source)).blocked)
        #expect(!decide(e, Request(url: "https://img.example.co.uk/ad/1.js", sourceURL: source)).blocked)
        #expect(decide(e, Request(url: "https://ads.test/ad/1.js", sourceURL: "https://news.test/")).blocked)
        #expect(!decide(e, Request(url: "https://news.test/ad/1.js", sourceURL: "https://www.news.test/")).blocked)
    }

    @Test func firstPartyUsesTheRegistrableDomain() {
        let e = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["load-type": ["first-party"]])])
        #expect(decide(e, Request(url: "https://a.site.test/ad/1.js", sourceURL: "https://www.site.test/")).blocked)
        #expect(!decide(e, Request(url: "https://cdn.other.test/ad/1.js", sourceURL: "https://www.site.test/")).blocked)
    }

    @Test func registrableDomainShapes() {
        #expect(WebKitRuleEvaluator.registrableDomain("a.example.co.uk") == "example.co.uk")
        #expect(WebKitRuleEvaluator.registrableDomain("example.co.uk") == "example.co.uk")
        #expect(WebKitRuleEvaluator.registrableDomain("co.uk") == "co.uk")
        #expect(WebKitRuleEvaluator.registrableDomain("www.bbc.com") == "bbc.com")
        #expect(WebKitRuleEvaluator.registrableDomain("10.0.0.1") == "10.0.0.1")
        #expect(WebKitRuleEvaluator.registrableDomain("localhost") == "localhost")
    }

    @Test func ifDomainExactWithoutStarAndWildcardWithStar() {
        let exact = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["if-domain": ["example.com"]])])
        #expect(decide(exact, Request(url: "https://cdn.test/ad/1", sourceURL: "https://example.com/")).blocked)
        #expect(!decide(exact, Request(url: "https://cdn.test/ad/1", sourceURL: "https://www.example.com/")).blocked)

        let wildcard = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["if-domain": ["*example.com"]])])
        #expect(decide(wildcard, Request(url: "https://cdn.test/ad/1", sourceURL: "https://example.com/")).blocked)
        #expect(decide(wildcard, Request(url: "https://cdn.test/ad/1", sourceURL: "https://a.example.com/")).blocked)
        #expect(!decide(wildcard, Request(url: "https://cdn.test/ad/1", sourceURL: "https://notexample.com/")).blocked)
    }

    @Test func unlessDomainExcludesTheHostAndItsSubdomains() {
        let e = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["unless-domain": ["*example.com"]])])
        #expect(!decide(e, Request(url: "https://cdn.test/ad/1", sourceURL: "https://a.example.com/")).blocked)
        #expect(!decide(e, Request(url: "https://cdn.test/ad/1", sourceURL: "https://example.com/")).blocked)
        #expect(decide(e, Request(url: "https://cdn.test/ad/1", sourceURL: "https://notexample.com/")).blocked)
        #expect(decide(e, Request(url: "https://cdn.test/ad/1", sourceURL: "https://other.test/")).blocked)
    }

    @Test func loadContextSplitsFramesFromTheTopFrame() {
        let frames = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["load-context": ["child-frame"]])])
        #expect(decide(frames, Request(url: "https://ads.test/ad/f.html", resourceType: "document", isChildFrame: true)).blocked)
        #expect(!decide(frames, Request(url: "https://ads.test/ad/x.js")).blocked)

        let top = WebKitRuleEvaluator(rules: [rule("/ad/", trigger: ["load-context": ["top-frame"]])])
        #expect(!decide(top, Request(url: "https://ads.test/ad/f.html", resourceType: "document", isChildFrame: true)).blocked)
        #expect(decide(top, Request(url: "https://ads.test/ad/x.js")).blocked)
    }

    @Test func cosmeticRulesAreSkipped() {
        let e = WebKitRuleEvaluator(rules: [rule("ads", action: "css-display-none")])
        #expect(!decide(e, Request(url: "https://ads.test/")).blocked)
        // A cosmetic rule does not clear an earlier block either.
        let f = WebKitRuleEvaluator(rules: [rule("ads"), rule("ads", action: "css-display-none")])
        #expect(decide(f, Request(url: "https://ads.test/")).blocked)
        #expect(f.stats.cosmetic == 1)
    }

    @Test func invalidRegexNeverMatches() {
        let blocking = WebKitRuleEvaluator(rules: [rule("(ads")])
        #expect(!decide(blocking, Request(url: "https://ads.test/(ads")).blocked)
        #expect(blocking.stats.invalidRegex == 1)

        // An ignore rule whose regex does not compile clears nothing.
        let ignoring = WebKitRuleEvaluator(rules: [rule("/ads/"), rule("(", action: "ignore-previous-rules")])
        #expect(decide(ignoring, Request(url: "https://x.test/ads/a.js")).blocked)
        #expect(ignoring.stats.invalidRegex == 1)
    }

    @Test func convertedAdblockLinesDecideLikeTheirFilters() throws {
        let text = """
        ||ads.example.com^
        @@||ads.example.com/ok^
        /banner/*$image,third-party
        ||track.example^$domain=news.example
        """
        let e = try WebKitRuleEvaluator(json: FilterListConverter.convert(text).json)

        #expect(decide(e, Request(url: "https://ads.example.com/x.js")).blocked)
        #expect(decide(e, Request(url: "https://sub.ads.example.com/x.js")).blocked)
        // `^` is a separator: `/ok/` is excepted, `/ok.js` is not.
        #expect(!decide(e, Request(url: "https://ads.example.com/ok/x.js")).blocked)
        #expect(decide(e, Request(url: "https://ads.example.com/ok.js")).blocked)
        #expect(decide(e, Request(url: "https://cdn.test/banner/a.png", sourceURL: "https://site.test/", resourceType: "image")).blocked)
        #expect(!decide(e, Request(url: "https://site.test/banner/a.png", sourceURL: "https://site.test/", resourceType: "image")).blocked)
        #expect(!decide(e, Request(url: "https://cdn.test/banner/a.js", sourceURL: "https://site.test/", resourceType: "script")).blocked)
        #expect(decide(e, Request(url: "https://track.example/p", sourceURL: "https://news.example/")).blocked)
        #expect(!decide(e, Request(url: "https://track.example/p", sourceURL: "https://other.test/")).blocked)
    }

    /// Patterns the index cannot key (groups, alternation, quantifiers, short tokens, unbounded tokens) and ones it can
    /// (whole, prefix, suffix). The indexed path must agree with brute force on every request.
    @Test func indexAgreesWithBruteForceOnAwkwardPatterns() {
        let e = WebKitRuleEvaluator(rules: [
            rule("(ads|track)\\.example"),
            rule("ad\\.server"),
            rule("^https://x\\.test/banner"),
            rule("sponsor"),
            rule("doubleclick\\.net"),
            rule("/Ads/", trigger: ["url-filter-is-case-sensitive": true]),
            rule("\\.gif$"),
            rule("a{2}ds"),
            rule("/ad_"),
            rule(".*", trigger: ["if-domain": ["*site.test"]]),
            rule("cdn[0-9]+\\.example"),
            rule("tracker", action: "ignore-previous-rules"),
            rule("\\/banner\\/[a-z]+\\/tracker"),
        ])
        let urls = [
            "https://ads.example/x.js",
            "https://track.example/",
            "https://x.test/banner/1.gif",
            "https://www.x.test/banner",
            "https://ad.server.net/p",
            "https://sponsored.test/sponsor?x=1",
            "https://ad.doubleclick.net/ads/Ads/1.js",
            "https://x.test/aads/1",
            "https://x.test/ad_slot.html",
            "https://cdn42.example/a/b/c",
            "https://x.test/banner/abc/tracker.png",
            "https://site.test/tracker?q=sponsor",
            "https://k\u{212A}ads.test/",
        ]
        for url in urls {
            for sourceURL in ["https://site.test/", "https://other.test/"] {
                #expect(e.indexedMatchesBruteForce(Request(url: url, sourceURL: sourceURL)), "\(url) from \(sourceURL)")
            }
        }
        #expect(e.stats.fallback > 0)
        #expect(e.stats.indexed > 0)
    }

    /// One list's `@@` exception cancels another list's block once the other list carries it (`SharedExceptions.adding`),
    /// but not a `$important` block, which no exception cancels.
    @Test func otherListExceptionsCancelBlocks() throws {
        let privacy = "||servebom.test^$third-party\n||beacon.test^$important"
        let easylist = "@@||servebom.test/tmn*.js$script\n@@||beacon.test^"
        let alone = try WebKitRuleEvaluator(json: FilterListConverter.convert(privacy).json)
        let shared = SharedExceptions.none.adding([SharedExceptions.listExceptions(in: easylist)])
        let joined = try WebKitRuleEvaluator(json: FilterListConverter.convert(privacy, shared: shared).json)
        let script = Request(url: "https://ads.servebom.test/tmnhead.js", sourceURL: "https://news.test/", resourceType: "script")
        let image = Request(url: "https://ads.servebom.test/pixel.gif", sourceURL: "https://news.test/", resourceType: "image")
        let beacon = Request(url: "https://beacon.test/b", sourceURL: "https://news.test/", resourceType: "script")
        #expect(alone.evaluate(script).blocked)
        #expect(!joined.evaluate(script).blocked)
        #expect(joined.evaluate(image).blocked)
        #expect(joined.evaluate(beacon).blocked)
        #expect(SharedExceptions.none.adding([SharedExceptions.listExceptions(in: easylist)]).fingerprint != "")
        // A list that blocks nothing gets none of them: they would cancel nothing.
        #expect(FilterListConverter.convert("@@||own.test^", shared: shared).ruleCount == 1)
    }

    /// The cache key's view of another list: only its `@@` lines, so blocks and comments changing don't count.
    @Test func exceptionLinesIgnoreEverythingElse() {
        let v1 = "! Version: 1\n||ads.test^\n@@||ok.test^\n  @@||also.test^$script  \n##.banner"
        let v2 = "! Version: 2\n||ads.test^\n||more.test^\n@@||ok.test^\n@@||also.test^$script\n##.other"
        #expect(SharedExceptions.exceptionLines(in: v1) == SharedExceptions.exceptionLines(in: v2))
        #expect(SharedExceptions.exceptionLines(in: v1) == "@@||ok.test^\n@@||also.test^$script")
        #expect(SharedExceptions.exceptionLines(in: v1 + "\n@@||new.test^") != SharedExceptions.exceptionLines(in: v1))
    }
}
