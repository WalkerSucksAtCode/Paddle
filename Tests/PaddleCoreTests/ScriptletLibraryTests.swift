import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing
import WebKit

/// Each scriptlet runs as a document-start page-world user script in a windowless web view; pages come from a
/// `paddle-test:` scheme handler, so nothing touches the network.
@MainActor
struct ScriptletLibraryTests {
    // MARK: - Harness

    @MainActor
    final class PageHandler: NSObject, WKURLSchemeHandler {
        let files: [String: String]
        var requested: [String] = []

        init(files: [String: String]) { self.files = files }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            let path = url.path()
            requested.append(path)
            let mime = path.hasSuffix(".json") ? "application/json" : path.hasSuffix(".js") ? "text/javascript" : "text/html"
            let body = files[path]
            let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "\(mime); charset=utf-8"])!
            task.didReceive(response)
            task.didReceive(Data((body ?? "").utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @MainActor
    struct Harness {
        let webView: WKWebView
        let handler: PageHandler

        func string(_ js: String) async -> String? {
            try? await webView.evaluateJavaScript("String(\(js))") as? String
        }

        /// Polls `js` until it is truthy, for up to `seconds`.
        func waitFor(_ js: String, seconds: Double = 3) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while ContinuousClock.now < deadline {
                if (try? await webView.evaluateJavaScript("!!(\(js))") as? Bool) == true { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }

    /// Loads `page` as `/index.html` with the scriptlets installed (after any `raw` scripts), and `files` served
    /// alongside it.
    static func load(_ scriptlets: [(ScriptletName, [String])], raw: [String] = [], page: String,
                     files: [String: String] = [:]) -> Harness {
        var all = files
        all["/index.html"] = page
        let handler = PageHandler(files: all)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "paddle-test")
        let controller = configuration.userContentController
        for source in raw {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        for (name, arguments) in scriptlets {
            let source = ScriptletLibrary.source(for: name, arguments: arguments)
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "paddle-test://site.test/index.html")!))
        return Harness(webView: webView, handler: handler)
    }

    static let errorRecorder = "window.errs = []; window.addEventListener('error', e => window.errs.push(String(e.message)));"

    // MARK: - Library shape

    @Test func everyScriptParses() throws {
        let context = try #require(JSContext())
        for name in ScriptletName.allCases {
            context.setObject(ScriptletLibrary.source(for: name, arguments: ["a", "b"]), forKeyedSubscript: "src" as NSString)
            let result = context.evaluateScript("(function () { try { new Function(src); return 'ok'; } catch (e) { return String(e); } })()")?.toString()
            #expect(result == "ok", "\(name.rawValue): \(result ?? "nil")")
        }
    }

    @Test func argumentsAreOneJSONArray() {
        let source = ScriptletLibrary.source(for: .noEvalIf, arguments: ["a\"b"])
        #expect(source.contains(#"scriptlet.apply(null, ["a\"b"]);"#))
    }

    // MARK: - Scriptlets

    @Test func setConstant() async {
        let h = Self.load([
            (.setConstant, ["ads.enabled", "false"]),
            (.setConstant, ["cfg.count", "5"]),
            (.setConstant, ["flag", "trueFunc"]),
            (.setConstant, ["big", "40000"]),
            (.setConstant, ["list", "emptyArr"]),
        ], page: #"""
        <script>
        window.ads = { enabled: true }; window.ads.enabled = true;
        window.cfg = {}; cfg.count = 9;
        window.flag = 1; window.big = 1; window.list = [1, 2];
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("ads.enabled") == "false")
        #expect(await h.string("cfg.count") == "5")
        #expect(await h.string("flag()") == "true")
        #expect(await h.string("big") == "1")
        #expect(await h.string("Array.isArray(list) && list.length") == "0")
    }

    @Test func abortOnPropertyRead() async {
        let h = Self.load([(.abortOnPropertyRead, ["adsLoader"]), (.abortOnPropertyRead, ["lib.init"])], page: #"""
        <script>
        const kind = e => e instanceof ReferenceError ? 'aborted' : 'other';
        window.adsLoader = 1;
        try { window.x = adsLoader; window.r1 = 'read'; } catch (e) { window.r1 = kind(e); }
        window.lib = { init: 1, other: 2 };
        try { window.x = lib.init; window.r2 = 'read'; } catch (e) { window.r2 = kind(e); }
        window.r3 = lib.other;
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == "aborted")
        #expect(await h.string("r2") == "aborted")
        #expect(await h.string("r3") == "2")
    }

    @Test func abortOnPropertyWrite() async {
        let h = Self.load([(.abortOnPropertyWrite, ["adBlockDetected"])], page: #"""
        <script>
        try { window.adBlockDetected = true; window.r = 'wrote'; } catch (e) { window.r = e instanceof ReferenceError ? 'aborted' : 'other'; }
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r") == "aborted")
    }

    @Test func abortCurrentScript() async {
        let h = Self.load([(.abortCurrentScript, ["atob", "adNeedle"]), (.abortCurrentScript, ["btoa", "ad-script.js"])], page: #"""
        <script>/* adNeedle */ try { atob('YQ=='); window.r1 = 'ran'; } catch (e) { window.r1 = e instanceof ReferenceError ? 'aborted' : 'other'; }</script>
        <script>window.r2 = atob('YQ==');</script>
        <script src="/ad-script.js"></script>
        <script>window.r4 = btoa('a'); window.done = true;</script>
        """#, files: ["/ad-script.js": "try { btoa('a'); window.r3 = 'ran'; } catch (e) { window.r3 = 'aborted'; }"])
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == "aborted")
        #expect(await h.string("r2") == "a")
        #expect(await h.string("r3") == "aborted")
        #expect(await h.string("r4") == "YQ==")
    }

    @Test func abortOnStackTrace() async {
        let h = Self.load([(.abortOnStackTrace, ["adConfig", "adLoader"])], page: #"""
        <script>
        window.adConfig = 7;
        function adLoader() { return window.adConfig; }
        function good() { return window.adConfig; }
        try { adLoader(); window.r1 = 'ran'; } catch (e) { window.r1 = e instanceof ReferenceError ? 'aborted' : 'other'; }
        try { window.r2 = good(); } catch (e) { window.r2 = 'aborted'; }
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == "aborted")
        #expect(await h.string("r2") == "7")
    }

    @Test func noSetTimeoutIf() async {
        let h = Self.load([(.noSetTimeoutIf, ["adTimer"]), (.noSetTimeoutIf, ["", "30"])], page: #"""
        <script>
        setTimeout(function adTimer() { window.adRan = true; }, 5);
        setTimeout(function () { window.d30 = true; }, 30);
        setTimeout(function () { window.goodRan = true; }, 60);
        </script>
        """#)
        #expect(await h.waitFor("window.goodRan"))
        #expect(await h.string("window.adRan") == "undefined")
        #expect(await h.string("window.d30") == "undefined")
    }

    @Test func noSetIntervalIfNegated() async {
        let h = Self.load([(.noSetIntervalIf, ["!keepMe"])], page: #"""
        <script>
        const a = setInterval(function keepMe() { window.kept = true; clearInterval(a); }, 5);
        const b = setInterval(function other() { window.otherRan = true; clearInterval(b); }, 5);
        setTimeout(function keepMe() { window.done = true; }, 80);
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("window.kept") == "true")
        #expect(await h.string("window.otherRan") == "undefined")
    }

    @Test func addEventListenerDefuser() async {
        let h = Self.load([(.addEventListenerDefuser, ["click", "adClick"])], page: #"""
        <script>
        document.addEventListener('click', function adClick() { window.ad = true; });
        document.addEventListener('click', function good() { window.good = true; });
        document.addEventListener('dblclick', function adClick() { window.dbl = true; });
        document.dispatchEvent(new Event('click'));
        document.dispatchEvent(new Event('dblclick'));
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("window.ad") == "undefined")
        #expect(await h.string("window.good") == "true")
        #expect(await h.string("window.dbl") == "true")
    }

    @Test func jsonPrune() async {
        let h = Self.load([(.jsonPrune, ["ads data.ad list.[].ad"]), (.jsonPrune, ["promo", "meta.sponsored"])], page: #"""
        <script>
        window.r1 = JSON.stringify(JSON.parse('{"ads":[1],"data":{"x":1,"ad":2},"list":[{"ad":1,"k":1},{"ad":2,"k":2}]}'));
        window.r2 = JSON.stringify(JSON.parse('{"promo":1}'));
        window.r3 = JSON.stringify(JSON.parse('{"promo":1,"meta":{"sponsored":true}}'));
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == #"{"data":{"x":1},"list":[{"k":1},{"k":2}]}"#)
        #expect(await h.string("r2") == #"{"promo":1}"#)
        #expect(await h.string("r3") == #"{"meta":{"sponsored":true}}"#)
    }

    static let apiFiles = [
        "/api.json": #"{"ads":[1],"items":[1,2]}"#,
        "/other.json": #"{"ads":[1],"items":[1,2]}"#,
    ]

    @Test func jsonPruneFetchResponse() async {
        let h = Self.load([(.jsonPruneFetchResponse, ["ads", "", "propsToMatch", "api.json"])], page: #"""
        <script>
        Promise.all([fetch('/api.json').then(r => r.json()), fetch('/other.json').then(r => r.json())])
          .then(([a, b]) => { window.r = JSON.stringify(a) + '|' + JSON.stringify(b); }, e => { window.r = 'error ' + e; });
        </script>
        """#, files: Self.apiFiles)
        #expect(await h.waitFor("window.r"))
        #expect(await h.string("r") == #"{"items":[1,2]}|{"ads":[1],"items":[1,2]}"#)
    }

    @Test func jsonPruneXHRResponse() async {
        let h = Self.load([(.jsonPruneXHRResponse, ["ads", "", "propsToMatch", "api.json"])], page: #"""
        <script>
        const get = (url, type) => new Promise(done => {
          const x = new XMLHttpRequest(); x.open('GET', url); x.responseType = type;
          x.onload = () => done(type === 'json' ? JSON.stringify(x.response) : x.responseText); x.onerror = () => done('error'); x.send();
        });
        Promise.all([get('/api.json', ''), get('/api.json', 'json'), get('/other.json', '')]).then(a => { window.r = a.join('|'); });
        </script>
        """#, files: Self.apiFiles)
        #expect(await h.waitFor("window.r"))
        #expect(await h.string("r") == #"{"items":[1,2]}|{"items":[1,2]}|{"ads":[1],"items":[1,2]}"#)
    }

    @Test func noFetchIf() async {
        let h = Self.load([(.noFetchIf, ["url:blocked method:GET", "emptyObj"])], page: #"""
        <script>
        Promise.all([fetch('/blocked.json').then(r => r.status + ' ' + r.url.endsWith('/blocked.json')).then(s => s), fetch('/blocked.json').then(r => r.text()),
                     fetch('/api.json').then(r => r.text())])
          .then(a => { window.r = a.join('|'); }, e => { window.r = 'error ' + e; });
        </script>
        """#, files: Self.apiFiles)
        #expect(await h.waitFor("window.r"))
        #expect(await h.string("r") == #"200 true|{}|{"ads":[1],"items":[1,2]}"#)
        #expect(!h.handler.requested.contains("/blocked.json"))
        #expect(h.handler.requested.contains("/api.json"))
    }

    @Test func noXHRIf() async {
        let h = Self.load([(.noXHRIf, ["blocked"])], page: #"""
        <script>
        const x = new XMLHttpRequest(); x.open('GET', '/blocked.json');
        x.onload = () => { window.r = x.status + ':' + x.responseText + ':' + x.readyState; };
        x.onerror = () => { window.r = 'error'; };
        x.send();
        </script>
        """#)
        #expect(await h.waitFor("window.r"))
        #expect(await h.string("r") == "200::4")
        #expect(!h.handler.requested.contains("/blocked.json"))
    }

    @Test func noEvalIf() async {
        let h = Self.load([(.noEvalIf, ["adCode"])], page: #"""
        <script>
        window.r1 = eval('1 + 1');
        window.r2 = String(eval('"adCode"; 5'));
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == "2")
        #expect(await h.string("r2") == "undefined")
    }

    @Test func noWindowOpenIf() async {
        let h = Self.load([(.noWindowOpenIf, ["pop"])], page: #"""
        <script>
        const w = window.open('https://ads.example/pop');
        window.r1 = (w && typeof w.close === 'function') ? 'stub' : String(w);
        window.r2 = String(window.open('about:blank#nope'));
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r1") == "stub")
        #expect(await h.string("r2") == "null")
    }

    @Test func removeAttrKeepsWatchingWithStay() async {
        let h = Self.load([(.removeAttr, ["data-ad|onclick", "", "stay"])], page: #"""
        <div id="a" data-ad="1" onclick="x()" title="keep">a</div>
        <script>
        window.addEventListener('load', () => setTimeout(() => {
          const d = document.createElement('div'); d.id = 'b'; d.setAttribute('data-ad', '2'); document.body.appendChild(d);
        }, 50));
        </script>
        """#)
        #expect(await h.waitFor("document.getElementById('b') && !document.getElementById('b').hasAttribute('data-ad')"))
        #expect(await h.string("document.getElementById('a').hasAttribute('onclick')") == "false")
        #expect(await h.string("document.getElementById('a').hasAttribute('data-ad')") == "false")
        #expect(await h.string("document.getElementById('a').title") == "keep")
    }

    @Test func removeClassWithSelector() async {
        let h = Self.load([(.removeClass, ["ad|sponsored", "div.box"])], page: #"""
        <div id="a" class="box ad sponsored keep"></div>
        <span id="s" class="ad"></span>
        """#)
        #expect(await h.waitFor("document.getElementById('a') && document.getElementById('a').className === 'box keep'"))
        #expect(await h.string("document.getElementById('s').className") == "ad")
    }

    @Test func removeNodeText() async {
        let h = Self.load([(.removeNodeText, ["script", "ad-marker"]), (.removeNodeText, ["#text", "ad-text"])], page: #"""
        <script>window.adScript = true; /* ad-marker */</script>
        <script>window.goodScript = true;</script>
        <p id="p">hello ad-text world</p><p id="q">fine</p>
        """#)
        #expect(await h.waitFor("window.goodScript && document.getElementById('q')"))
        #expect(await h.string("window.adScript") == "undefined")
        #expect(await h.string("document.getElementById('p').textContent") == "")
        #expect(await h.string("document.getElementById('q').textContent") == "fine")
    }

    // The boosters are checked against a control timer in the same page with the same delay, so the order of
    // firing is the check, not wall-clock times that a loaded machine stretches.

    @Test func nanoSetIntervalBooster() async {
        let h = Self.load([(.nanoSetIntervalBooster, ["adTick", "1000", "0.02"])], page: #"""
        <script>
        window.order = []; let n = 0;
        const id = setInterval(function adTick() { if (++n === 3) { clearInterval(id); window.order.push('boosted'); } }, 1000);
        setTimeout(function control() { window.order.push('control'); }, 1000);
        </script>
        """#)
        #expect(await h.waitFor("window.order.length === 2", seconds: 10))
        #expect(await h.string("window.order.join()") == "boosted,control", "three boosted ticks before one plain 1 s timer")
    }

    @Test func nanoSetTimeoutBooster() async {
        let h = Self.load([(.nanoSetTimeoutBooster, ["adT"])], page: #"""
        <script>
        window.order = [];
        setTimeout(function plain() { window.order.push('control'); }, 1000);
        setTimeout(function adT() { window.order.push('boosted'); }, 1000);
        </script>
        """#)
        #expect(await h.waitFor("window.order.length === 2", seconds: 10))
        #expect(await h.string("window.order.join()") == "boosted,control", "the matching timer fires first though it was set second")
    }

    @Test func noWebRTC() async {
        let h = Self.load([(.noWebRTC, [])], page: #"""
        <script>
        window.r = typeof RTCPeerConnection === 'undefined' ? 'absent'
          : Function.prototype.toString.call(RTCPeerConnection).includes('[native code]') ? 'native'
          : new RTCPeerConnection().connectionState;
        window.done = true;
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("r") == "closed")
    }

    // MARK: - Untrusted arguments

    /// A needle full of quotes, backslashes, newlines, `</script>` and template syntax arrives intact (it blocks
    /// exactly the matching eval) and none of it runs as code.
    @Test func hostileArgumentStaysAString() async throws {
        let payload = "\"]);window.pwned=1;//\\'\n</script><script>window.pwned=2</script>\u{2028}${window.pwned=3}`'); window.pwned=4; ('"
        let h = Self.load([(.noEvalIf, [payload])], raw: [Self.errorRecorder], page: #"""
        <script>window.check = s => { try { return eval(s); } catch (e) { return 'threw'; } }; window.done = true;</script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("window.pwned") == "undefined")
        #expect(await h.string("window.errs.length") == "0")
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: [payload]), as: UTF8.self)
        #expect(await h.string("window.check(\(literal)[0])") == "undefined")
        #expect(await h.string("window.check('1 + 1')") == "2")
        #expect(await h.string("window.pwned") == "undefined")
    }

    /// Unknown value tokens, out-of-range numbers, bad regexes and bad selectors make a scriptlet do nothing, quietly.
    @Test func badArgumentsAreQuiet() async {
        let h = Self.load([
            (.setConstant, ["probe.a", "notAToken"]),
            (.noSetTimeoutIf, ["/[/"]),
            (.removeAttr, ["id", "div[["]),
            (.noFetchIf, ["x", "war:noop.js"]),
            (.noSetIntervalIf, ["", "soon"]),
        ], raw: [Self.errorRecorder], page: #"""
        <div id="d"></div>
        <script>
        window.probe = { a: 1 };
        setTimeout(function () { window.done = true; }, 5);
        </script>
        """#)
        #expect(await h.waitFor("window.done"))
        #expect(await h.string("probe.a") == "1")
        #expect(await h.string("document.getElementById('d') !== null") == "true")
        #expect(await h.string("window.errs.length") == "0")
    }
}
