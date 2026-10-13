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
        ! two scriptlets and a regex rule WebKit can't express
        example.com##+js(set-constant, x, 1)
        example.com#$#abort-on-property-read x
        /ads(?=[0-9]+)/
        """)
        #expect(s.ruleCount == 0)
        #expect(s.statusLine(name: "user-filters", cached: false, locale: us)
            == "user-filters: 0 rules (2 comment lines; 2 lines unsupported; regex: 0 translated, 1 refused)")
    }

    @Test func oneOfEach() {
        let s = summary("! c\n||ads.example^\nexample.com##+js(x)")
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
        let s = RuleListSummary(ruleCount: 5, skipped: 2, commentLines: 1, truncated: true, styleInjection: 4, invalidSelectors: 3)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RuleListSummary.self, from: data) == s)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == [
            "ruleCount", "skipped", "commentLines", "truncated", "styleInjection", "invalidSelectors", "regexTranslated", "regexRefused",
        ])
    }

    /// A list WebKit refused is remembered with its reason, keeps its counts, and is never installable.
    @Test func compileFailureIsRememberedAndShown() throws {
        var s = RuleListSummary(ruleCount: 3, skipped: 1, commentLines: 0, truncated: false)
        #expect(s.installable)
        s.compileFailure = "invalid or unsupported regular expression"
        #expect(!s.installable)
        #expect(s.statusLine(name: "user-filters", cached: true, locale: Locale(identifier: "en_US"))
            == "user-filters: failed to compile (invalid or unsupported regular expression)")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RuleListSummary.self, from: data) == s)
        #expect(!RuleListSummary(ruleCount: 0, skipped: 2, commentLines: 1, truncated: false).installable)
    }

    /// A sidecar written before the selector counts existed still loads (with zeros) instead of forcing a reconvert.
    @Test func oldSidecarDecodesWithZeroSelectorCounts() throws {
        let old = Data(#"{"ruleCount":61234,"skipped":1830,"commentLines":120,"truncated":false}"#.utf8)
        let s = try JSONDecoder().decode(RuleListSummary.self, from: old)
        #expect(s == RuleListSummary(ruleCount: 61_234, skipped: 1_830, commentLines: 120, truncated: false))
        #expect(s.styleInjection == 0 && s.invalidSelectors == 0)
    }

    @Test func styleAndInvalidCountsShowInTheStatusLine() {
        let s = summary("""
        hindustantimes.com##body {padding-top:0;}
        ##.x:style(top: 0)
        ##article:has(header:has(.sponsored))
        ##.ad
        example.com##+js(nowebrtc)
        """)
        #expect(s == RuleListSummary(ruleCount: 1, skipped: 1, commentLines: 0, truncated: false, styleInjection: 2, invalidSelectors: 1))
        #expect(s.statusLine(name: "mine", cached: true, locale: us) == "mine: 1 rule (1 line unsupported; 2 style rules; 1 invalid selector; cached)")
        let onlyStyle = summary("example.com##body {padding-top:0;}")
        #expect(onlyStyle.statusLine(name: "mine", cached: false, locale: us) == "mine: 0 rules (1 style rule)")
        let big = RuleListSummary(ruleCount: 61_234, skipped: 1_830, commentLines: 120, truncated: false, styleInjection: 40, invalidSelectors: 3)
        #expect(big.statusLine(name: "easylist", cached: true, locale: us)
            == "easylist: 61,234 rules (1,830 lines unsupported; 40 style rules; 3 invalid selectors; cached)")
    }

    @Test func regexCountsShowInTheStatusLine() {
        let s = summary("/ads\\d+\\.js/\n/(?=x)ads/\n/\\bads/\n||ok.test^")
        #expect(s == RuleListSummary(ruleCount: 2, skipped: 0, commentLines: 0, truncated: false, regexTranslated: 1, regexRefused: 2))
        #expect(s.statusLine(name: "mine", cached: false, locale: us) == "mine: 2 rules (regex: 1 translated, 2 refused)")
        // Only refused regex lines: not "empty", since the file has rules Paddle could not use.
        #expect(summary("/(?=x)/").statusLine(name: "mine", cached: false, locale: us) == "mine: 0 rules (regex: 0 translated, 1 refused)")
        let old = Data(#"{"ruleCount":1,"skipped":0,"commentLines":0,"truncated":false,"styleInjection":0,"invalidSelectors":0}"#.utf8)
        #expect(try! JSONDecoder().decode(RuleListSummary.self, from: old).regexRefused == 0)
    }

    /// A list WebKit refused that compiled once its regex rules were left out says so, and the note survives the
    /// sidecar; a sidecar from before the field decodes without it.
    @Test func regexDroppedShowsInTheStatusLine() throws {
        var s = RuleListSummary(ruleCount: 1_200, skipped: 0, commentLines: 0, truncated: false, regexTranslated: 3)
        s.regexDropped = "invalid or unsupported regular expression"
        #expect(s.installable)
        #expect(s.statusLine(name: "easylist", cached: true, locale: us)
            == "easylist: 1,200 rules (regex: 3 translated, 0 refused; regex rules left out: WebKit refused them (invalid or unsupported regular expression); cached)")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RuleListSummary.self, from: data) == s)
        let old = Data(#"{"ruleCount":1,"skipped":0,"commentLines":0,"truncated":false}"#.utf8)
        #expect(try JSONDecoder().decode(RuleListSummary.self, from: old).regexDropped == nil)
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
