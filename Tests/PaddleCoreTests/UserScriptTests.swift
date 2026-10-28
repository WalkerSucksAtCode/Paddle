import Foundation
@testable import PaddleCore
import Testing

struct UserScriptTests {
    @Test func parsesHeader() {
        let source = """
        // ==UserScript==
        // @name        Tidy YouTube
        // @match       *://*.youtube.com/*
        // @exclude     *://*.youtube.com/embed/*
        // @run-at      document-start
        // @noframes
        // ==/UserScript==
        console.log("hi");
        """
        let script = UserScript(fileName: "yt.user.js", source: source)
        #expect(script.name == "Tidy YouTube")
        #expect(script.runAt == .documentStart)
        #expect(script.mainFrameOnly)
        #expect(script.matches("https://www.youtube.com/watch?v=1"))
        #expect(script.matches("https://youtube.com/"))
        #expect(!script.matches("https://www.youtube.com/embed/abc"))
        #expect(!script.matches("https://notyoutube.com/"))
        #expect(!script.matches("https://youtube.com.evil.test/"))
    }

    @Test func headerlessRunsEverywhere() {
        let script = UserScript(fileName: "all.js", source: "document.body.dataset.x = 1")
        #expect(script.name == "all")
        #expect(script.matches("https://anything.example/"))
        #expect(script.runAt == .documentEnd)
    }

    @Test func includeGlobsAndRegex() {
        let glob = UserScript(fileName: "a.js", source: "// ==UserScript==\n// @include http*://example.com/a*\n// ==/UserScript==")
        #expect(glob.matches("https://example.com/abc"))
        #expect(!glob.matches("https://example.com/b"))
        let regex = UserScript(fileName: "b.js", source: "// ==UserScript==\n// @include /^https://x\\.test/\\d+$/\n// ==/UserScript==")
        #expect(regex.matches("https://x.test/42"))
        #expect(!regex.matches("https://x.test/abc"))
    }

    @Test func matchPatternHandlesPortsAndAllURLs() {
        #expect(UserScript.regex(forMatchPattern: "<all_urls>") == "^(https?|file)://")
        let local = UserScript(fileName: "l.js", source: "// ==UserScript==\n// @match http://localhost/*\n// ==/UserScript==")
        #expect(local.matches("http://localhost:3000/app"))
        #expect(UserScript.regex(forMatchPattern: "ftp://x/*") == nil)
    }

    @Test func wrappedSourceGuardsOnURL() {
        let script = UserScript(fileName: "a.js", source: "// ==UserScript==\n// @match https://a.test/*\n// ==/UserScript==\nrun()")
        #expect(script.wrappedSource.contains(#"new RegExp("^https://a\\.test(:[0-9]+)?/.*$")"#))
        #expect(script.wrappedSource.hasSuffix("run()\n})();"))
    }

    @Test func refusedIncludeNeverRunsAndRefusedExcludeMatchesNothing() {
        let include = UserScript(fileName: "r.js", source: "// ==UserScript==\n// @include /^(a+)+$/\n// ==/UserScript==")
        #expect(!include.matches("https://a.test/aaaa"))
        let exclude = UserScript(fileName: "x.js", source: "// ==UserScript==\n// @exclude /(a+)+$/\n// ==/UserScript==")
        #expect(exclude.matches("https://a.test/aaaa"))
    }

    @Test func longURLsDoNotMatch() {
        let script = UserScript(fileName: "a.js", source: "x")
        #expect(script.matches("https://a.test/" + String(repeating: "x", count: 100)))
        #expect(!script.matches("https://a.test/" + String(repeating: "x", count: 2100)))
    }

    @Test func wrappedSourceCarriesTheSameLimits() {
        let script = UserScript(fileName: "a.js", source: "// ==UserScript==\n// @include /(a+)+/\n// @include https://a.test/*\n// ==/UserScript==\nrun()")
        #expect(!script.wrappedSource.contains(#"new RegExp("(a+)+")"#))
        #expect(script.wrappedSource.contains(#"a\\.test"#))
        #expect(script.wrappedSource.contains("__paddleHref.length > 2048"))
        let onlyRefused = UserScript(fileName: "b.js", source: "// ==UserScript==\n// @include /(a+)+/\n// ==/UserScript==\nrun()")
        #expect(onlyRefused.wrappedSource.contains("if (![].some("))
    }
}
