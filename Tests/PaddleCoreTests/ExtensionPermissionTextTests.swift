import Foundation
@testable import PaddleCore
import Testing

struct ExtensionPermissionTextTests {
    private let allSites = "Every website: read and change everything, including sites you're signed in to"

    @Test(arguments: ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"])
    func allSitesPatternsComeFirst(pattern: String) {
        let lines = ExtensionPermissionText.lines(permissions: ["tabs", "storage"], hosts: ["https://a.com/*", pattern])
        #expect(lines.first == allSites)
        #expect(lines.count == 4)
        #expect(lines[1] == "Read and change pages on: a.com")
    }

    @Test func severalAllSitesPatternsCollapseToOneLine() {
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: ["<all_urls>", "*://*/*", "https://*/*"])
        #expect(lines == [allSites])
    }

    @Test func hostListTruncatesAtFive() {
        let hosts = Set(["a.com", "b.com", "c.com", "d.com", "e.com", "f.com", "g.com"].map { "https://*.\($0)/*" })
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: hosts)
        #expect(lines == ["Read and change pages on: a.com, b.com, c.com, d.com, e.com (and 2 more)"])
    }

    @Test func hostsStripSchemeWildcardAndDuplicates() {
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: ["http://*.example.org/*", "https://example.org/*", "http://127.0.0.1/*"])
        #expect(lines == ["Read and change pages on: 127.0.0.1, example.org"])
    }

    @Test func hostsAreSanitized() {
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: ["https://evil\n.com\u{202E}/*"])
        #expect(lines == ["Read and change pages on: evil.com"])
    }

    @Test func knownPermissionsHaveFixedPhrases() {
        let lines = ExtensionPermissionText.lines(permissions: ["tabs", "activeTab", "declarativeNetRequest"], hosts: [])
        #expect(lines == [
            "See and change the current page when you click its button",
            "Block content on pages",
            "See the addresses and titles of your tabs",
        ])
    }

    @Test func nativeMessagingSaysItIsRefused() {
        let lines = ExtensionPermissionText.lines(permissions: ["nativeMessaging"], hosts: [])
        #expect(lines == ["Talk to apps on this Mac (not available in Paddle, always refused)"])
    }

    @Test func allSixteenWebKitNamesHavePhrases() {
        let names = ["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
                     "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging",
                     "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]
        for name in names {
            let line = ExtensionPermissionText.lines(permissions: [name], hosts: []).first
            #expect(line != nil && line != name, "\(name)")
        }
    }

    @Test func unknownNamesAreShownSanitized() {
        let lines = ExtensionPermissionText.lines(permissions: ["futureThing\n", "weird\u{7}name"], hosts: [])
        #expect(lines == ["futureThing", "weirdname"])
    }

    @Test func atMostTwelveLines() {
        let permissions = Set((0..<30).map { "perm\($0)" })
        let hosts: Set<String> = ["<all_urls>", "https://a.com/*"]
        let lines = ExtensionPermissionText.lines(permissions: permissions, hosts: hosts)
        #expect(lines.count == 12)
        #expect(lines.first == allSites)
        #expect(lines.last == "(and 21 more)")
    }

    @Test func exactlyTwelveLinesAreNotCut() {
        let lines = ExtensionPermissionText.lines(permissions: Set((0..<12).map { "perm\($0)" }), hosts: [])
        #expect(lines.count == 12)
        #expect(!lines.contains { $0.hasPrefix("(and") })
    }

    @Test func sanitizeStripsControlCharactersAndNewlines() {
        #expect(ExtensionPermissionText.sanitize("Line one\nLine\ttwo\r\u{0}") == "Line oneLinetwo")
        #expect(ExtensionPermissionText.sanitize("  padded  ") == "padded")
        #expect(ExtensionPermissionText.sanitize("a\u{2028}b\u{202E}c") == "abc")
    }

    @Test func sanitizeTruncatesWithEllipsis() {
        let long = String(repeating: "x", count: 100)
        let out = ExtensionPermissionText.sanitize(long)
        #expect(out.count == 60)
        #expect(out.hasSuffix("…"))
        #expect(ExtensionPermissionText.sanitize(long, max: 10) == "xxxxxxxxx…")
        #expect(ExtensionPermissionText.sanitize(String(repeating: "y", count: 60)) == String(repeating: "y", count: 60))
    }

    @Test func anyPatternWithAStarHostIsAllSites() {
        let hosts: Set<String> = ["https://*/**", "https://a.com/*", "https://b.com/*", "https://c.com/*", "https://d.com/*", "https://e.com/*"]
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: hosts)
        #expect(lines == [allSites, "Read and change pages on: a.com, b.com, c.com, d.com, e.com"])
    }

    @Test func patternsWebKitCallsAllHostsAreAllSites() {
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: ["odd-spelling", "https://a.com/*"], allSites: ["odd-spelling"])
        #expect(lines == [allSites, "Read and change pages on: a.com"])
    }

    @Test func wildcardOverADomainEndingIsSpelledOutAndNotCapped() {
        let hosts: Set<String> = ["*://*.com/*", "https://*.co.uk/*", "https://a.org/*", "https://b.org/*", "https://c.org/*",
                                  "https://d.org/*", "https://e.org/*", "https://f.org/*"]
        let lines = ExtensionPermissionText.lines(permissions: [], hosts: hosts)
        #expect(lines == [
            "Every site ending in .co.uk, .com: read and change pages",
            "Read and change pages on: a.org, b.org, c.org, d.org, e.org (and 1 more)",
        ])
    }

    @Test func askingForNothingSaysSo() {
        #expect(ExtensionPermissionText.lines(permissions: [], hosts: []) == [ExtensionPermissionText.noAccessLine])
    }

    @Test func sanitizeCapsStackedCombiningMarks() {
        let out = ExtensionPermissionText.sanitize("ab" + String(repeating: "\u{301}", count: 500))
        #expect(out.unicodeScalars.count == 4)
        #expect(ExtensionPermissionText.sanitize("Cafe\u{301}") == "Cafe\u{301}")
    }

    @Test func sanitizeCapsScalarsPerString() {
        // Hangul conjoining jamo: one Character, many scalars, no marks.
        let tower = String(repeating: "\u{1100}", count: 400) + "\u{1161}"
        let out = ExtensionPermissionText.sanitize(tower)
        #expect(out.unicodeScalars.count <= 180)
        #expect(out.hasSuffix("…") || out.isEmpty || out.unicodeScalars.count <= 180)
    }
}

