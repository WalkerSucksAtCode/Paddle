import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing
import WebKit

/// The one-script dispatcher for rules match patterns can't express: it runs each rule only where the frame's
/// hostname matches its domains and `site.*` entities.
@MainActor
struct ScriptletDispatcherTests {
    private func rule(
        _ name: ScriptletName, _ arguments: [String], domains: [String] = [], entities: [String] = [],
        excludeDomains: [String] = [], excludeEntities: [String] = []
    ) -> ScriptletRule {
        ScriptletRule(name: name, arguments: arguments, includeDomains: domains, excludeDomains: excludeDomains,
                      includeEntities: entities, excludeEntities: excludeEntities)
    }

    private var rules: [ScriptletRule] {
        [
            rule(.setConstant, ["onDomain", "true"], domains: ["example.com"]),
            rule(.setConstant, ["onEntity", "true"], entities: ["shop"], excludeEntities: ["blocked"]),
            rule(.setConstant, ["everywhere", "true"], excludeDomains: ["quiet.example.com"]),
            rule(.setConstant, ["elsewhere", "true"], domains: ["other.org"]),
            rule(.noWebRTC, [], domains: ["example.com"]),
        ]
    }

    /// The window's flags after loading a page as if from `host` with the dispatcher installed. The page is an HTML
    /// string with an https base URL: offline, and with a real hostname (a custom scheme's `location.hostname` is
    /// empty in WebKit, which the dispatcher treats as no site).
    private func flags(on host: String) async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ScriptletLibrary.dispatcherSource(for: rules), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://\(host)/index.html"))
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            // The initial about:blank is "complete" at once; wait for the page itself.
            let ready = "location.protocol === 'https:' && document.readyState === 'complete'"
            if (try? await webView.evaluateJavaScript(ready) as? Bool) == true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let js = "[window.onDomain, window.onEntity, window.everywhere, window.elsewhere].map(v => v === true ? 1 : 0).join('')"
        return try? await webView.evaluateJavaScript(js) as? String
    }

    @Test func parses() throws {
        let context = try #require(JSContext())
        context.setObject(ScriptletLibrary.dispatcherSource(for: rules), forKeyedSubscript: "src" as NSString)
        let result = context.evaluateScript("(function () { try { new Function(src); return 'ok'; } catch (e) { return String(e); } })()")?.toString()
        #expect(result == "ok")
        #expect(ScriptletLibrary.dispatcherSource(for: []).isEmpty)
    }

    @Test func eachBodyAndHelperAppearsOnce() {
        let source = ScriptletLibrary.dispatcherSource(for: rules)
        #expect(source.components(separatedBy: "const P = {").count == 2)
        #expect(source.components(separatedBy: "\"set-constant\":").count == 2)
    }

    @Test func runsOnlyWhereTheHostMatches() async {
        // onDomain, onEntity, everywhere, elsewhere
        let expected = [
            "www.example.com": "1010", "quiet.example.com": "1000", "shop.com": "0110", "www.shop.co.uk": "0110",
            "shop.example.net.evil.io": "0010", "blocked.shop.com": "0110", "other.org": "0011",
        ]
        for (host, flags) in expected.sorted(by: { $0.key < $1.key }) {
            let actual = await self.flags(on: host)
            #expect(actual == flags, "\(host): \(actual ?? "nil")")
        }
    }
}
