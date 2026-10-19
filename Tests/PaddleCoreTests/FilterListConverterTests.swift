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
        ||z.test^$replace=/ads/news/
        ||w.test^$csp=default-src 'self' https://w.test
        /ads(?=x)/
        ||ok.test^
        """
        let result = FilterListConverter.convert(text)
        // ok.test, the translated regex; `#@#` is an exception, not a rule.
        #expect(result.ruleCount == 2)
        #expect(result.skippedLines == 6)
        #expect(result.skips.scriptlets == 1)
        #expect(result.skips.extendedSelectors == 1)
        #expect(result.skips.options == ["redirect": 1, "csp": 2, "replace": 1])
        #expect(result.regexTranslated == 1)
        #expect(result.regexRefused == 1)
        // Options holding "/" are options, not part of a URL pattern.
        #expect(!result.json.contains("replace"))
        #expect(!result.json.contains("default-src"))
    }

    /// One line of each reason lands in its own bucket, and the buckets add up to `skippedLines`.
    @Test func skippedLinesSplitByReason() {
        let text = """
        ! comment
        example.com##+js(nowebrtc)
        example.com#?#div:has-text(Sponsored)
        ||x.test^$redirect=noop.js
        ||y.test^$csp=script-src 'none'
        example.com##^script:has-text(y)
        #@#
        ||ok.test^
        """
        let result = FilterListConverter.convert(text)
        #expect(result.ruleCount == 1)
        #expect(result.skips.scriptlets == 1)
        #expect(result.skips.extendedSelectors == 1)
        #expect(result.skips.options == ["redirect": 1, "csp": 1])
        #expect(result.skips.other == 1)
        #expect(result.skips.malformed == 1)
        #expect(result.skippedLines == 6)
        #expect(result.skips.total == result.skippedLines)
        #expect(FilterListConverter.skipBreakdown(text) == result.skips)
    }

    /// Injection markers, non-ASCII text and entity wildcards are `other`; lines with no usable form are `malformed`.
    @Test func otherAndMalformedSkipReasons() {
        let text = """
        example.com#$#.x { color: red; }
        example.com#%#//scriptlet("abort-on-property-read", "x")
        example.com$$script[tag-content="z"]
        ||täst.test^
        example.*##.ad
        ||q.test^$domain=amazon.*
        ||r.test^$~domain=a.test
        ~a.test#@#.x
        ##
        *$important
        """
        let result = FilterListConverter.convert(text)
        #expect(result.skips == FilterListConverter.SkipBreakdown(other: 6, malformed: 4))
        #expect(result.skippedLines == 10)
    }

    /// Options WebKit can't express are tallied by name, whether they hold "/" or not.
    @Test func unsupportedOptionsAreTalliedByName() {
        let text = """
        ||a.test^$removeparam=utm_source
        ||b.test^$removeparam=fbclid
        ||c.test^$header=x-frame-options:deny
        ||d.test^$replace=/ads/news/
        ||e.test^$document
        @@banner$document
        ||f.test^$~
        """
        let result = FilterListConverter.convert(text)
        #expect(result.ruleCount == 0)
        #expect(result.skips.options == ["removeparam": 2, "header": 1, "replace": 1, "document": 1, "document (not a site)": 1, "(empty)": 1])
        #expect(result.skips.total == 7)
    }

    @Test func regexRulesKeepTheirOptions() throws {
        let r = try rules(#"/ads\d{1,2}\.js$/$script,domain=a.test"# + "\n" + #"@@/(good|fine)\.test\/x/"#)
        #expect(r.count == 3)
        #expect(trigger(r[0])["url-filter"] as? String == #"ads[0-9][0-9]?\.js$"#)
        #expect(trigger(r[0])["resource-type"] as? [String] == ["script"])
        #expect(trigger(r[0])["if-domain"] as? [String] == ["*a.test"])
        #expect(r[1...].allSatisfy { action($0)["type"] as? String == "ignore-previous-rules" })
        #expect(r[1...].compactMap { trigger($0)["url-filter"] as? String } == [#"good\.test/x"#, #"fine\.test/x"#])
        // A regex that matches every URL needs something to narrow it, like a plain `*` rule.
        #expect(FilterListConverter.convert("/.*/").regexRefused == 1)
        #expect(FilterListConverter.convert("/.*/$script").regexTranslated == 1)
    }

    /// `#@#` on a generic selector: the selector leaves the shared chunk for a rule of its own that skips the
    /// excepted domains (subdomains included).
    @Test func genericCosmeticExceptionBecomesUnlessDomainRule() throws {
        let text = """
        ##.ad
        ##.banner
        ##.promo
        a.test,b.test#@#.banner
        c.test#@#.banner
        #@#.promo
        """
        let r = try rules(text)
        #expect(r.count == 2)
        #expect(action(r[0])["selector"] as? String == ".ad")
        #expect(trigger(r[0])["unless-domain"] == nil)
        #expect(action(r[1])["selector"] as? String == ".banner")
        #expect(action(r[1])["type"] as? String == "css-display-none")
        #expect(trigger(r[1])["unless-domain"] as? [String] == ["*a.test", "*b.test", "*c.test"])
        #expect(!FilterListConverter.convert(text).json.contains("promo"))  // excepted everywhere
        #expect(FilterListConverter.convert(text).skippedLines == 0)
    }

    /// A per-domain `##` that a `#@#` touches (same domain, parent or subdomain) is dropped for that domain list;
    /// an exception for an unrelated site leaves it alone.
    @Test func domainCosmeticExceptionDropsTheSelectorForThatKey() throws {
        let text = """
        site.test##.x
        site.test##.y
        other.test##.y
        ~skip.test##.z
        sub.site.test#@#.x
        elsewhere.test#@#.y
        else.test#@#.z
        """
        let r = try rules(text)
        let selectors = r.map { (action($0)["selector"] as? String ?? "", trigger($0)) }
        #expect(selectors.count == 3)
        #expect(selectors[0].0 == ".y" && selectors[0].1["if-domain"] as? [String] == ["*site.test"])
        #expect(selectors[1].0 == ".y" && selectors[1].1["if-domain"] as? [String] == ["*other.test"])
        #expect(selectors[2].0 == ".z" && selectors[2].1["unless-domain"] as? [String] == ["*skip.test", "*else.test"])
    }

    /// The user's `@@` and `#@#` lines ride at the end of another list; the cache fingerprint follows them.
    @Test func sharedExceptionsAreAppendedToEveryList() throws {
        let shared = SharedExceptions(userFilters: "! mine\n@@||ads.test^\nsite.test#@#.ad\n||blocked.test^")
        let result = FilterListConverter.convert("||ads.test^\n##.ad\n@@||own.test^", shared: shared)
        let r = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        #expect(r.count == 4)
        #expect(action(r[0])["type"] as? String == "block")
        #expect(trigger(r[1])["unless-domain"] as? [String] == ["*site.test"])
        #expect((trigger(r[2])["url-filter"] as? String)?.contains("own") == true)
        #expect(action(r[3])["type"] as? String == "ignore-previous-rules")
        #expect((trigger(r[3])["url-filter"] as? String)?.contains(#"ads\.test"#) == true)
        #expect(!result.json.contains("blocked"))  // only exceptions are shared

        #expect(SharedExceptions.none.fingerprint.isEmpty)
        #expect(SharedExceptions(userFilters: "||only-blocks.test^\n##.x").fingerprint.isEmpty)
        #expect(shared.fingerprint == SharedExceptions(userFilters: "site.test#@#.ad\n@@||ads.test^").fingerprint)
        #expect(shared.fingerprint != SharedExceptions(userFilters: "@@||ads.test^").fingerprint)
        // user-filters.txt already holds its own exceptions.
        #expect(shared.forUserFilters.isEmpty)
    }

    @Test func blockingOffHostsBecomeSiteExceptions() throws {
        let shared = SharedExceptions(userFilters: "", blockingOffHosts: ["News.Test.", "bad host", "a.test"])
        let r = try rules("||ads.test^").count
        let result = FilterListConverter.convert("||ads.test^", shared: shared)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        #expect(json.count == r + 2)
        #expect(json[1...].map { trigger($0)["if-domain"] as? [String] } == [["*a.test"], ["*news.test"]])
        #expect(json[1...].allSatisfy { action($0)["type"] as? String == "ignore-previous-rules" })
        #expect(shared.forUserFilters.fingerprint == shared.fingerprint)
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
        #expect(FilterListConverter.classifySelector("div:has-text(Ad)") == .skipped(.extended))
        #expect(FilterListConverter.classifySelector("") == .skipped(.malformed))
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

    /// `$object` (plugins) has no WebKit type: it adds nothing to a type list, and a rule with only plugin types is
    /// skipped rather than widened to every type.
    @Test func objectTypeAddsNoWebKitType() throws {
        let mixed = try rules(".com/ads/$image,object,subdocument")
        // Images, plus frames in a rule of their own; nothing for `object`.
        #expect(mixed.map { trigger($0)["resource-type"] as? [String] } == [["image", "svg-document"], ["document"]])
        let only = FilterListConverter.convert("/flash-ad/$object\n/plugin/$object-subrequest")
        #expect(only.ruleCount == 0)
        #expect(only.skips.options["object"] == 2)
        // `~object` excludes nothing WebKit has: every type.
        #expect(trigger(try rules("/x/$~object")[0])["resource-type"] == nil)
    }

    /// A closing `^` matches a separator or the end of the URL, as in uBlock Origin; one in the middle still needs a
    /// separator.
    @Test func closingSeparatorMatchesEndOfURL() {
        let filter = FilterListConverter.urlFilter("||analytics.test/r/collect^")!
        #expect(filterMatches(filter, "https://www.analytics.test/r/collect"))
        #expect(filterMatches(filter, "https://www.analytics.test/r/collect?v=1"))
        #expect(filterMatches(filter, "https://www.analytics.test/r/collect/x"))
        #expect(!filterMatches(filter, "https://www.analytics.test/r/collector"))
        let middle = FilterListConverter.urlFilter("/ads^banner")!
        #expect(!filterMatches(middle, "https://x.test/ads"))
        // An explicit end anchor keeps its meaning.
        #expect(FilterListConverter.urlFilter("/x.js^|") == "/x\\.js[^a-z0-9_.%-]$")
    }

    /// `||host^` ends at the separator, with no `.*)?$` tail: WebKit's URLs always have a path after the host, and
    /// that tail on ~99,000 rules made the compiled lists nearly twice as large and page loads slower.
    @Test func hostRuleEndsAtSeparator() {
        let filter = FilterListConverter.urlFilter("||ads.example.com^")!
        #expect(filter == "^[a-z][a-z0-9+.-]*://([^/]*\\.)?ads\\.example\\.com[^a-z0-9_.%-]")
        #expect(filterMatches(filter, "https://ads.example.com/"))
        #expect(filterMatches(filter, "https://cdn.ads.example.com:8443/x.js"))
        #expect(filterMatches(filter, "http://ads.example.com/?q=1"))
        #expect(!filterMatches(filter, "https://ads.example.com.evil.test/"))
        #expect(!filterMatches(filter, "https://ads.example.community/"))
        #expect(!filterMatches(filter, "https://notads.example.com/"))
        // A path or wildcard after the host still matches the end of the URL.
        #expect(FilterListConverter.urlFilter("||cacheserve.*^")!.hasSuffix(".*)?$"))
    }

    /// The real proof: WebKit itself accepts the generated JSON.
    @MainActor
    @Test func webKitCompilesOutput() async throws {
        let text = """
        ||ads.example.com^
        ||analytics.test/r/collect^
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

    /// Paddle's bundled list (Resources/PaddleFilters) keeps every selector and compiles in WebKit.
    @MainActor
    @Test func bundledPaddleFiltersCompile() async throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/PaddleFilters/paddle-filters.txt")
        let result = FilterListConverter.convert(try String(contentsOf: file, encoding: .utf8))
        #expect(result.json.contains("css-display-none"))
        #expect(result.json.contains("aria-label"))
        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")))
        let list = try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: result.json)
        #expect(list != nil)
    }

    /// `~a.com#@#.foo` has no positive domain; it must not leave an empty `unless-domain` that WebKit rejects.
    @MainActor
    @Test func negatedOnlyCosmeticExceptionCompiles() async throws {
        let result = FilterListConverter.convert("##.foo\n~a.com#@#.foo")
        #expect(!result.json.contains("\"unless-domain\":[]"))
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

    /// Every EasyList regex rule, translated and compiled by WebKit.
    @MainActor
    @Test func easyListRegexSetCompilesQuickly() async throws {
        let start = ContinuousClock.now
        let result = FilterListConverter.convert(easyListRegexRules)
        #expect(result.regexTranslated + result.regexRefused == 22)
        #expect(result.regexTranslated > 0)
        let directory = FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let list = try await store.compileContentRuleList(forIdentifier: "regex", encodedContentRuleList: result.json)
        #expect(list != nil)
        // A smoke bound, not a benchmark: it catches a pattern that sends WebKit's compile into minutes, without
        // failing on a busy machine.
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    /// Compiles `json` in a throwaway store; the error WebKit gave, or nil when it compiled.
    @MainActor
    static func webKitCompileError(_ json: String) async -> (any Error)? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let store = WKContentRuleListStore(url: directory) else { return CocoaError(.fileNoSuchFile) }
        do {
            _ = try await store.compileContentRuleList(forIdentifier: "probe", encodedContentRuleList: json)
            return nil
        } catch {
            return error
        }
    }

    /// `[a-\d]` is valid JavaScript (`a`, `-` or a digit); written out as `[a-0-9]` WebKit refused it, and with it
    /// the whole list. `[z-a]` is refused before it gets that far.
    @MainActor
    @Test func regexClassWithHyphenCompiles() async throws {
        let result = FilterListConverter.convert(#"/[a-\d]x/"#)
        #expect(result.regexTranslated == 1)
        #expect(result.json.contains(#"[a\\-0-9]x"#))
        #expect(await Self.webKitCompileError(result.json) == nil)
        let reversed = FilterListConverter.convert("/[z-a]/\n||ok.test^")
        #expect(reversed.regexRefused == 1)
        #expect(reversed.ruleCount == 1)
        // The other shapes the class rewrite emits: escaped hyphens as range ends, escaped brackets and caret.
        let shapes = FilterListConverter.convert(#"/[--a]x/"# + "\n" + #"/[\w-z]y/"# + "\n" + #"/[a\]\[^]z/"# + "\n" + #"/[+--]w/"#)
        #expect(shapes.regexTranslated == 4)
        #expect(await Self.webKitCompileError(shapes.json) == nil)
    }

    /// The app's fallback, with a regex rule WebKit refuses (the pre-fix `[a-0-9]` rewrite): the list fails to
    /// compile, and compiles once `dropRegex` leaves its regex rules out.
    @MainActor
    @Test func droppingRegexRulesRescuesARefusedList() async throws {
        var parsed = FilterListConverter.parse(#"/ads\d/"# + "\n||ok.test^\n##.ad")
        let index = try #require(parsed.blocks.firstIndex { $0.isRegex })
        parsed.blocks[index].trigger.urlFilter = "[a-0-9]x"
        let refused = FilterListConverter.assemble(parsed, chunks: FilterListConverter.cosmeticChunks(parsed, size: 32))
        #expect(refused.containsRegexRules)
        #expect(await Self.webKitCompileError(refused.json) != nil)
        let rescued = FilterListConverter.assemble(parsed, chunks: FilterListConverter.cosmeticChunks(parsed, size: 32), dropRegex: true)
        #expect(rescued.ruleCount == 2)
        #expect(await Self.webKitCompileError(rescued.json) == nil)
    }

    /// The fallback the app uses when WebKit refuses a list: every rule made from a `/regex/` line goes, the list's
    /// own and the user's shared `@@/regex/` exceptions alike, and nothing else.
    @Test func dropRegexLeavesOutEveryRegexRule() throws {
        let shared = SharedExceptions(userFilters: "@@/user-allow\\d/\n@@||user.test^")
        let text = "/ads\\d+\\.js/\n@@/(good|fine)\\.test/\n||plain.test^\n##.ad"
        let full = FilterListConverter.convert(text, shared: shared)
        #expect(full.containsRegexRules)
        #expect(full.ruleCount == 7)
        let dropped = FilterListConverter.convert(text, shared: shared, dropRegex: true)
        #expect(!dropped.containsRegexRules)
        #expect(dropped.ruleCount == 3)
        #expect(!dropped.json.contains("ads[0-9]"))
        #expect(!dropped.json.contains("good"))
        #expect(!dropped.json.contains("user-allow"))
        #expect(dropped.json.contains("plain") && dropped.json.contains("user"))
        #expect(dropped.regexTranslated == full.regexTranslated)  // the lines were translated; WebKit refused them
        #expect(!full.json.contains("isRegex") && !full.json.contains("isImportant"))
        #expect(!FilterListConverter.convert("||plain.test^").containsRegexRules)
    }

    /// `$subdocument` means frames. WebKit's `document` type also covers the page itself, so the document part
    /// gets `load-context: child-frame`; other types in the same rule go to a rule of their own, since
    /// `load-context` applies to the whole trigger.
    @MainActor
    @Test func subdocumentOnlyBlocksFrames() async throws {
        let only = try rules("||frames.test^$subdocument")
        #expect(only.count == 1)
        #expect(trigger(only[0])["resource-type"] as? [String] == ["document"])
        #expect(trigger(only[0])["load-context"] as? [String] == ["child-frame"])

        let mixed = try rules("||mixed.test^$script,subdocument,third-party")
        try #require(mixed.count == 2)
        #expect(trigger(mixed[0])["resource-type"] as? [String] == ["script"])
        #expect(trigger(mixed[0])["load-context"] == nil)
        #expect(trigger(mixed[1])["resource-type"] as? [String] == ["document"])
        #expect(trigger(mixed[1])["load-context"] as? [String] == ["child-frame"])
        #expect(mixed.allSatisfy { trigger($0)["load-type"] as? [String] == ["third-party"] })

        #expect(trigger(try rules("||f.test^$frame")[0])["load-context"] as? [String] == ["child-frame"])
        let negated = try rules("||neg.test^$~subdocument")
        #expect(negated.count == 1 && trigger(negated[0])["load-context"] == nil)
        // Only negated types (`$~script`): every other type, frames included, but never the page itself.
        let allBut = try rules("-banner-ads-$~script")
        try #require(allBut.count == 2)
        let otherTypes = try #require(trigger(allBut[0])["resource-type"] as? [String])
        #expect(!otherTypes.contains("document") && !otherTypes.contains("script") && otherTypes.contains("image"))
        #expect(trigger(allBut[0])["load-context"] == nil)
        #expect(trigger(allBut[1])["resource-type"] as? [String] == ["document"])
        #expect(trigger(allBut[1])["load-context"] as? [String] == ["child-frame"])
        let regex = FilterListConverter.convert(#"/frame\d\.test/$subdocument,image"#)
        #expect(regex.regexTranslated == 1 && regex.ruleCount == 2)
        let allow = try rules("@@||site.test^$document")
        #expect(allow.count == 1 && trigger(allow[0])["load-context"] == nil)

        let text = "||frames.test^$subdocument\n||mixed.test^$script,subdocument\n@@||frames.test^$subdocument,domain=ok.test\n-banner-ads-$~script"
        #expect(await Self.webKitCompileError(FilterListConverter.convert(text).json) == nil)
    }

    /// `#@#` excepts one selector of a `##` selector list: both sides are split on top-level commas, never inside
    /// parentheses, brackets or quotes.
    @Test func cosmeticExceptionMatchesOneSelectorOfAList() throws {
        let text = """
        ##.ad, .sidebar
        site.test#@#.sidebar
        page.test##.a,.b
        page.test#@#.b
        ##div:is(.x, .y)
        ##a[title="p,q"]
        #@#.gone, .also-gone
        ##.gone
        ##.also-gone
        """
        let r = try rules(text)
        let selectors = r.map { action($0)["selector"] as? String ?? "" }
        #expect(selectors == [".ad, div:is(.x, .y), a[title=\"p,q\"]", ".a", ".sidebar"])
        let sidebar = try #require(r.first { action($0)["selector"] as? String == ".sidebar" })
        #expect(trigger(sidebar)["unless-domain"] as? [String] == ["*site.test"])
        // Counters stay per line.
        let result = FilterListConverter.convert("##.a, .b {color:red}\n##.c, :has(:has(.d))\n##.e,")
        #expect(result.styleInjection == 1)
        #expect(result.invalidSelectors == 2)
        #expect(result.ruleCount == 0)
    }

    /// With `match-case`, `^` must not count an uppercase letter as a separator.
    @Test func matchCaseSeparatorKeepsUppercase() throws {
        let filter = try #require(trigger(try rules("/Ads^$match-case")[0])["url-filter"] as? String)
        #expect(filter == "/Ads([^a-zA-Z0-9_.%-].*)?$")
        let re = try NSRegularExpression(pattern: filter)
        func hit(_ url: String) -> Bool { re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        #expect(hit("https://x.test/Ads/x"))
        #expect(!hit("https://x.test/AdsX"))
        #expect(hit("https://x.test/Ads"))
        #expect(trigger(try rules("/ads^")[0])["url-filter"] as? String == "/ads([^a-z0-9_.%-].*)?$")
    }

    /// `@@example.com^$document` without `||` is the same site allowlist; a bare word is not a host.
    @Test func anchorlessDocumentAllowlist() throws {
        for line in ["@@example.com^$document", "@@Example.com$document"] {
            let result = FilterListConverter.convert(line)
            #expect(result.skippedLines == 0, "\(line)")
            let r = try rules(line)
            try #require(r.count == 1)
            #expect(trigger(r[0])["if-domain"] as? [String] == ["*example.com"])
            #expect(action(r[0])["type"] as? String == "ignore-previous-rules")
        }
        #expect(FilterListConverter.convert("@@banner$document").skippedLines == 1)
        #expect(FilterListConverter.convert("@@/path/x.com$document").skippedLines == 1)
    }

    /// `:style(` inside an attribute value is text, not a style rule.
    @Test func styleInsideQuotesIsASelector() {
        #expect(FilterListConverter.classifySelector(#"a[data-x=":style(y)"]"#) == .selector)
        #expect(FilterListConverter.classifySelector(".x:style(top: 0)") == .styleInjection)
        #expect(FilterListConverter.classifySelector(".x:STYLE(top: 0)") == .styleInjection)
        // Extended-syntax markers count only outside quoted strings too.
        #expect(FilterListConverter.classifySelector(#"[title=":contains("]"#) == .selector)
        #expect(FilterListConverter.classifySelector(".x:contains(ad)") == .skipped(.extended))
        let result = FilterListConverter.convert(#"##a[data-x=":style(y)"]"#)
        #expect(result.styleInjection == 0 && result.ruleCount == 1)
    }

    /// `$important` beats the list's own `@@` lines (Adblock Plus precedence); the user's `@@` lines and sites
    /// with blocking off still beat it.
    @Test func importantBlocksBeatTheListsExceptions() throws {
        let shared = SharedExceptions(userFilters: "@@||mine.test^", blockingOffHosts: ["off.test"])
        let text = "||ads.test^$important,script\n@@||ads.test^\n||plain.test^\n##.ad"
        let result = FilterListConverter.convert(text, shared: shared)
        let r = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        try #require(r.count == 6)
        #expect((trigger(r[0])["url-filter"] as? String)?.contains("plain") == true)
        #expect(action(r[1])["type"] as? String == "css-display-none")
        #expect(action(r[2])["type"] as? String == "ignore-previous-rules")
        #expect((trigger(r[2])["url-filter"] as? String)?.contains("ads") == true)
        #expect(action(r[3])["type"] as? String == "block")
        #expect((trigger(r[3])["url-filter"] as? String)?.contains("ads") == true)
        #expect(trigger(r[3])["resource-type"] as? [String] == ["script"])
        #expect((trigger(r[4])["url-filter"] as? String)?.contains("mine") == true)
        #expect(trigger(r[5])["if-domain"] as? [String] == ["*off.test"])
    }

    /// Over the cap, ordinary blocks and hiding go from the end; the list's exceptions, its important blocks and
    /// the shared exceptions all stay.
    @Test func truncationKeepsExceptionsAndImportantBlocks() throws {
        let shared = SharedExceptions(userFilters: "@@||mine.test^")
        let text = (0..<10).map { "||block\($0).test^" }.joined(separator: "\n")
            + "\n@@||own.test^\n||vip.test^$important"
        let parsed = FilterListConverter.parse(text, shared: shared)
        let result = FilterListConverter.assemble(parsed, chunks: FilterListConverter.cosmeticChunks(parsed, size: 32), shared: shared, maxRules: 6)
        #expect(result.truncated)
        #expect(result.ruleCount == 6)
        let urls = try #require(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]]).map { trigger($0)["url-filter"] as? String ?? "" }
        try #require(urls.count == 6)
        #expect(urls[0].contains("block0") && urls[1].contains("block1") && urls[2].contains("block2"))
        #expect(!urls.contains { $0.contains("block3") })
        #expect(urls[3].contains("own") && urls[4].contains("vip") && urls[5].contains("mine"))
        let untruncated = FilterListConverter.assemble(parsed, chunks: [], shared: shared)
        #expect(!untruncated.truncated && untruncated.ruleCount == 13)
    }

    /// The bundled EasyList and EasyPrivacy snapshots, converted as a first launch converts them and compiled by
    /// WebKit: one rule WebKit refuses would leave a fresh install without blocking.
    @MainActor
    @Test func bundledSnapshotsCompile() async throws {
        let snapshots = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/FilterSnapshots")
        for (file, floor) in [("easylist.txt", 30_000), ("easyprivacy.txt", 20_000)] {
            let text = try String(contentsOf: snapshots.appending(path: file), encoding: .utf8)
            let result = FilterListConverter.convert(text)
            #expect(result.ruleCount > floor, "\(file): \(result.ruleCount) rules")
            #expect(!result.truncated)
            let error = await Self.webKitCompileError(result.json)
            #expect(error == nil, "\(file): \(String(describing: error))")
        }
    }

    /// The cross-list fix, end to end in a windowless web view: "another list" blocks `ads.test`, and the user's
    /// `@@||ads.test^` only un-blocks it once appended to that list. Loads go through a scheme handler, which
    /// sees exactly the requests WebKit did not block.
    @MainActor
    @Test func userExceptionUnblocksAnotherListsBlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "paddle-test-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let userText = "@@||ads.test^"
        let shared = SharedExceptions(userFilters: userText)
        let user = try #require(try await store.compileContentRuleList(
            forIdentifier: "user", encodedContentRuleList: FilterListConverter.convert(userText, shared: shared.forUserFilters).json))
        let other = try #require(try await store.compileContentRuleList(
            forIdentifier: "other", encodedContentRuleList: FilterListConverter.convert("||ads.test^").json))
        let otherShared = try #require(try await store.compileContentRuleList(
            forIdentifier: "other-shared", encodedContentRuleList: FilterListConverter.convert("||ads.test^", shared: shared).json))

        // Without the shared exceptions the user's own list cannot help: the other list still blocks.
        #expect(try await Self.requestedHosts(lists: [other, user]) == ["site.test"])
        #expect(try await Self.requestedHosts(lists: [otherShared, user]) == ["site.test", "ads.test"])
    }

    /// Loads a page from `paddle-test://site.test/` that pulls a script from `paddle-test://ads.test/`, with `lists`
    /// installed, and returns the hosts the scheme handler was asked for, in order.
    @MainActor
    static func requestedHosts(lists: [WKContentRuleList]) async throws -> [String] {
        let handler = RecordingSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "paddle-test")
        for list in lists { configuration.userContentController.add(list) }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "paddle-test://site.test/index.html")!))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await webView.evaluateJavaScript("window.done === true") as? Bool) == true { break }
        }
        #expect((try? await webView.evaluateJavaScript("window.done === true") as? Bool) == true)
        return handler.hosts
    }

    @MainActor
    final class RecordingSchemeHandler: NSObject, WKURLSchemeHandler {
        var hosts: [String] = []

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            hosts.append(url.host() ?? "")
            let isPage = url.host() == "site.test"
            let body = isPage
                ? #"<script src="paddle-test://ads.test/ad.js" onload="window.done = true" onerror="window.done = true"></script>"#
                : "window.adLoaded = true;"
            task.didReceive(URLResponse(url: url, mimeType: isPage ? "text/html" : "text/javascript",
                                        expectedContentLength: body.utf8.count, textEncodingName: "utf-8"))
            task.didReceive(Data(body.utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @MainActor
    static func querySelectorAccepts(_ selectors: [String], in webView: WKWebView) async -> [Bool] {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: selectors), as: UTF8.self)
        let script = "(function (a) { return a.map(s => { try { document.querySelector(s); return true } catch (e) { return false } }) })(\(json))"
        return (try? await webView.evaluateJavaScript(script) as? [Bool]) ?? []
    }
}
