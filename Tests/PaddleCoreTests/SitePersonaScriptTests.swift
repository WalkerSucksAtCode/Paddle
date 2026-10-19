import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing
import WebKit

/// The page-world persona script (`SitePersonaScript`). It parses, its host table is JSON data, and a page on a persona
/// host (subdomains included) reports that browser's identity, while every other page reports what it reports without
/// the script. Pages load inline HTML from an https base URL, so nothing touches the network.
@MainActor
struct SitePersonaScriptTests {
    static let personas: [String: Persona] = ["example.com": .chrome, "firefox.test": .firefox, "quiet.example.com": .none]

    static var source: String { SitePersonaScript.source(for: personas) }

    @Test func parses() throws {
        let context = try #require(JSContext())
        context.setObject(Self.source, forKeyedSubscript: "src" as NSString)
        #expect(context.evaluateScript("(function () { try { new Function(src); return 'ok'; } catch (e) { return String(e); } })()")?.toString() == "ok")
        #expect(SitePersonaScript.source(for: [:]).isEmpty)
        #expect(SitePersonaScript.source(for: ["a.example": .none, "b.example": .native]).isEmpty)
    }

    @Test func hostTableIsJSONData() throws {
        // Quotes, a backslash and a script close tag in a key stay inside a JSON string. Two spellings of one host
        // resolve as `sitePersona(forHost:)` resolves them: the greater raw key wins.
        let hostile: [String: Persona] = [
            "a\"b\\c</script>.example": .chrome, "x.example": .firefox, "Example.com": .firefox, "example.COM": .chrome, "y.example": .native,
        ]
        let table = SitePersonaScript.hostTable(hostile)
        #expect(table == [["a\"b\\c</script>.example", "chrome"], ["example.com", "chrome"], ["x.example", "firefox"], ["y.example", ""]])
        let json = SitePersonaScript.tableJSON(hostile)
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String]] == table)
        let source = SitePersonaScript.source(for: hostile)
        #expect(source.contains(json))
        let context = try #require(JSContext())
        context.setObject(source, forKeyedSubscript: "src" as NSString)
        #expect(context.evaluateScript("(function () { try { new Function(src); return 'ok'; } catch (e) { return String(e); } })()")?.toString() == "ok")
    }

    /// Reads what the page's JavaScript reports after loading as if from `host`, with `source` as the only user script
    /// (nil: none), as JSON text.
    private func reportText(on host: String, source: String?) async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let source {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
            ))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://\(host)/index.html"))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            // The initial about:blank is "complete" at once; wait for the page itself.
            let ready = "location.protocol === 'https:' && document.readyState === 'complete'"
            if (try? await webView.evaluateJavaScript(ready) as? Bool) == true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = try? await webView.evaluateJavaScript(Self.probe)
        while ContinuousClock.now < deadline {
            if let text = try? await webView.evaluateJavaScript("window.__probeResult || null") as? String { return text }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(host): the page did not report")
        return ""
    }

    /// `reportText`'s JSON as a dictionary.
    private func parse(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    /// Reads the identity the page sees, into `window.__probeResult` once its async reads finish.
    private static let probe = #"""
    void (async () => {
      window.__probeResult = null;
      const names = (list) => Array.from(list, (b) => b.brand + '/' + b.version);
      const out = {vendor: navigator.vendor, uaData: typeof navigator.userAgentData, chrome: typeof window.chrome};
      if (navigator.userAgentData) {
        const uad = navigator.userAgentData;
        out.brands = names(uad.brands);
        out.mobile = uad.mobile;
        out.platform = uad.platform;
        out.toJSONKeys = Object.keys(uad.toJSON()).join(',');
        const high = await uad.getHighEntropyValues(['fullVersionList', 'platformVersion', 'nope']);
        out.fullVersionList = names(high.fullVersionList);
        out.highKeys = Object.keys(high).sort().join(',');
      }
      if (window.chrome) {
        out.app = typeof window.chrome.app;
        out.runtimeKeys = Object.keys(window.chrome.runtime).length;
        out.loadTimes = typeof window.chrome.loadTimes;
        out.csi = typeof window.chrome.csi;
      }
      out.plugins = Array.from(navigator.plugins, (p) => p.name);
      out.mimeTypes = Array.from(navigator.mimeTypes, (m) => m.type);
      out.oscpu = navigator.oscpu === undefined ? null : navigator.oscpu;
      out.buildID = navigator.buildID === undefined ? null : navigator.buildID;
      out.vendorGetter = Function.prototype.toString.call(Object.getOwnPropertyDescriptor(Navigator.prototype, 'vendor').get);
      out.toStringOfToString = Function.prototype.toString.call(Function.prototype.toString);
      window.__probeResult = JSON.stringify(out);
    })().catch((e) => { window.__probeResult = JSON.stringify({error: String(e)}); });
    """#

    @Test func chromePersonaShowsOnItsHostAndItsSubdomains() async throws {
        let report = try parse(await reportText(on: "www.example.com", source: Self.source))
        let brands = Persona.chrome.brands().map { "\($0.brand)/\($0.version)" }
        let full = Persona.chrome.brands(full: true).map { "\($0.brand)/\($0.version)" }
        #expect(report["vendor"] as? String == "Google Inc.")
        #expect(report["uaData"] as? String == "object")
        #expect(report["brands"] as? [String] == brands)
        #expect(report["fullVersionList"] as? [String] == full)
        #expect(report["mobile"] as? Bool == false)
        #expect(report["platform"] as? String == "macOS")
        #expect(report["toJSONKeys"] as? String == "brands,mobile,platform")
        #expect(report["highKeys"] as? String == "brands,fullVersionList,mobile,platform,platformVersion")
        #expect(report["chrome"] as? String == "object")
        #expect(report["app"] as? String == "object")
        #expect(report["runtimeKeys"] as? Int == 0)
        #expect(report["loadTimes"] as? String == "function")
        #expect(report["csi"] as? String == "function")
        #expect(report["plugins"] as? [String] == [
            "PDF Viewer", "Chrome PDF Viewer", "Chromium PDF Viewer", "Microsoft Edge PDF Viewer", "WebKit built-in PDF",
        ])
        #expect(report["mimeTypes"] as? [String] == ["application/pdf", "text/pdf"])
        #expect(report["vendorGetter"] as? String == "function get vendor() { [native code] }")
        #expect(report["toStringOfToString"] as? String == "function toString() { [native code] }")
    }

    @Test func firefoxPersonaShowsOnItsHost() async throws {
        let report = try parse(await reportText(on: "firefox.test", source: Self.source))
        #expect(report["vendor"] as? String == "")
        #expect(report["uaData"] as? String == "undefined")
        #expect(report["chrome"] as? String == "undefined")
        #expect(report["oscpu"] as? String == "Intel Mac OS X 10.15")
        #expect(report["buildID"] as? String == "20181001000000")
        #expect(report["vendorGetter"] as? String == "function get vendor() { [native code] }")
    }

    @Test func otherHostsAndANoneSubdomainReportWhatWebKitReports() async throws {
        // A host no entry covers, and a subdomain whose own entry is `none` (it opts out of `example.com`).
        for host in ["other.test", "quiet.example.com"] {
            let withScript = await reportText(on: host, source: Self.source)
            let withoutScript = await reportText(on: host, source: nil)
            #expect(withScript == withoutScript, "\(host)")
            let report = try parse(withScript)
            #expect(report["chrome"] as? String == "undefined", "\(host)")
            #expect(report["oscpu"] is NSNull, "\(host)")
        }
    }
}
