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
}
