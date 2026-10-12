import Foundation
@testable import PaddleCore
import Testing

struct RuleListSummaryTests {
    let us = Locale(identifier: "en_US")

    func summary(_ text: String) -> RuleListSummary {
        RuleListSummary(text: text, result: FilterListConverter.convert(text))
    }

    @Test func emptyFile() {
        let s = summary("\n  \n")
        #expect(s == RuleListSummary(ruleCount: 0, skipped: 0, commentLines: 0, truncated: false))
        #expect(s.statusLine(name: "user-filters", cached: false) == "user-filters: empty")
    }

    @Test func commentsOnly() {
        // The stock user-filters.txt: four comment lines and a blank one.
        let s = summary("""
        ! Your own blocking rules, Adblock Plus syntax. Paddle > Reload Config to apply.
        ! ||annoying-widget.example^         block a host
        ! example.com##.newsletter-popup     hide an element on one site
        ! @@||mybank.example^$document       turn blocking off for a site

        """)
        #expect(s.statusLine(name: "user-filters", cached: false, locale: us) == "user-filters: 0 rules (4 comment lines)")
    }

    @Test func allUnsupported() {
        let s = summary("""
        [Adblock Plus 2.0]
        ! two scriptlets and a regex rule
        example.com##+js(set-constant, x, 1)
        example.com#$#abort-on-property-read x
        /ads[0-9]+\\.js/
        """)
        #expect(s.ruleCount == 0)
        #expect(s.statusLine(name: "user-filters", cached: false, locale: us)
            == "user-filters: 0 rules (2 comment lines; 3 lines unsupported)")
    }

    @Test func oneOfEach() {
        let s = summary("! c\n||ads.example^\n/regex/")
        #expect(s.statusLine(name: "mine", cached: false, locale: us) == "mine: 1 rule (1 line unsupported)")
    }

    @Test func normalListMatchesWhenCached() {
        let s = RuleListSummary(ruleCount: 61_234, skipped: 1_830, commentLines: 120, truncated: false)
        #expect(s.statusLine(name: "easylist", cached: false, locale: us) == "easylist: 61,234 rules (1,830 lines unsupported)")
        #expect(s.statusLine(name: "easylist", cached: true, locale: us) == "easylist: 61,234 rules (1,830 lines unsupported; cached)")
        let clean = RuleListSummary(ruleCount: 12, skipped: 0, commentLines: 3, truncated: false)
        #expect(clean.statusLine(name: "mine", cached: false, locale: us) == "mine: 12 rules")
        let full = RuleListSummary(ruleCount: 150_000, skipped: 0, commentLines: 0, truncated: true)
        #expect(full.statusLine(name: "big", cached: true, locale: us) == "big: 150,000 rules (truncated; cached)")
    }

    @Test func sidecarRoundTrips() throws {
        let s = RuleListSummary(ruleCount: 5, skipped: 2, commentLines: 1, truncated: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RuleListSummary.self, from: data) == s)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["ruleCount", "skipped", "commentLines", "truncated"])
    }

    @Test func compileFailureReasons() {
        // NSHelpAnchor texts WebKit returned in the B3 probe (WKErrorDomain 6).
        #expect(RuleListSummary.compileFailureReason(
            helpAnchor: "Rule list compilation failed: Invalid or unsupported regular expression.", fallback: "x")
            == "invalid or unsupported regular expression")
        #expect(RuleListSummary.compileFailureReason(helpAnchor: "Rule list compilation failed: Empty extension.", fallback: "x")
            == "WebKit accepted none of its rules")
        #expect(RuleListSummary.compileFailureReason(
            helpAnchor: "Rule list compilation failed: Failed to parse the JSON String.", fallback: "x")
            == "converted rules are not valid JSON")
        #expect(RuleListSummary.compileFailureReason(helpAnchor: nil, fallback: "WKErrorDomain error 6") == "WKErrorDomain error 6")
        #expect(RuleListSummary.compileFailureReason(helpAnchor: "Rule list compilation failed:", fallback: "fb") == "fb")
    }
}
