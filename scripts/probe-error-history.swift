// Checks that Paddle's error page keeps back/forward history the way Safari does.
// Same loads as `TabWebDelegate.loadErrorPage` (WebKit's alternate-HTML load for the unreachable URL, or a simulated
// response when that private method is missing; pass `simulated` to force the fallback) and the crash page in
// `Tab.processTerminated` (`loadHTMLString` with the crashed URL as base URL), and the same error-page
// tracking as `TabWebDelegate.trackErrorPageItem` (remembered back/forward items, main-frame responses).
// Runs in windowless WKWebViews (no app, no window, no network: pages come from a custom scheme, the failing URL is a
// closed local port) and checks:
//   1. A, B, then a failing URL: back list [A, B], current item the failing URL, error page showing, tracked as error;
//   2. Back lands on B; 3. Forward shows the error page again with the same history, still tracked as an error page;
//   4. Reload on the error page, then Back and Forward: history still [A, B] + failing, no duplicate item;
//   5. A, B, C, then Back to B while B fails (page cache off): back [A], current B (error), forward [C];
//   6. the error tab's interactionState restored in a fresh web view (sleep/wake, session restore): the retry shows
//      the error page with back [A, B], and one Back reaches B;
//   7. the crash page (`Tab.processTerminated` after repeated crashes) on B: back [A], current B (error), forward [].
// Run: swiftc -O scripts/probe-error-history.swift -o "$TMPDIR/probe-error-history" && "$TMPDIR/probe-error-history"
// Exits 0 when every check passes.
import Foundation
import WebKit

let pageA = URL(string: "probe://a/")!
let pageB = URL(string: "probe://b/")!
let failing = URL(string: "http://127.0.0.1:9/missing")!
let errorTitle = "Can't open this page"

let forceSimulated = CommandLine.arguments.contains("simulated")

/// Serves `<title>host</title>` for any probe:// URL, or fails like an unreachable server for hosts in `down`.
final class Pages: NSObject, WKURLSchemeHandler {
    var down: Set<String> = []
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        if down.contains(url.host() ?? "") {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                          userInfo: [NSURLErrorFailingURLErrorKey: url]))
            return
        }
        let body = Data("<title>\(url.host() ?? "")</title>page \(url.absoluteString)".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var events: [String] = []
    /// Whether the last commit was an error page, by the app's rule.
    var committedErrorPage = false
    private var pendingErrorPage = false
    private var responded = false
    private let errorPageItems = NSHashTable<WKBackForwardListItem>.weakObjects()
    private var waiter: CheckedContinuation<Void, Never>?
    private var generation = 0

    /// Runs `start` and waits for the next finished load, or gives up after 5 s.
    func run(_ start: () -> Void) async {
        generation += 1
        let mine = generation
        await withCheckedContinuation { continuation in
            waiter = continuation
            start()
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.generation == mine { self.events.append("timeout"); self.resume() }
            }
        }
    }
    private func resume() { waiter?.resume(); waiter = nil }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame ?? false { responded = false }
        return .allow
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { responded = true }
        return .allow
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        var isError = pendingErrorPage
        if let item = webView.backForwardList.currentItem {
            if pendingErrorPage {
                errorPageItems.add(item)
            } else if !responded, errorPageItems.contains(item) {
                isError = true
            } else {
                errorPageItems.remove(item)
            }
        }
        committedErrorPage = isError
        pendingErrorPage = false
        responded = false
        events.append("commit")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        events.append("finish")
        resume()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        events.append("failProvisional")
        let url = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? failing
        pendingErrorPage = true
        loadErrorPage(for: url, in: webView)
    }
    /// The crash page, as `Tab.processTerminated` shows it after repeated crashes.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events.append("terminated")
        pendingErrorPage = true
        webView.loadHTMLString("<title>\(errorTitle)</title><p>crash page", baseURL: webView.url)
    }
}

/// Same as `TabWebDelegate.loadErrorPage`.
@MainActor func loadErrorPage(for url: URL, in webView: WKWebView) {
    let html = "<title>\(errorTitle)</title><p>error page"
    let selector = NSSelectorFromString("_loadAlternateHTMLString:baseURL:forUnreachableURL:")
    if !forceSimulated, webView.responds(to: selector) {
        typealias LoadAlternate = @convention(c) (AnyObject, Selector, NSString, NSURL, NSURL) -> Void
        unsafeBitCast(webView.method(for: selector), to: LoadAlternate.self)(
            webView, selector, html as NSString, url as NSURL, url as NSURL)
    } else {
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }
}

struct State: CustomStringConvertible {
    var back: [String], current: String, forward: [String], title: String, errorPage: Bool, events: [String]
    var description: String {
        "back=\(back) current=\(current) forward=\(forward) title=\"\(title)\" trackedAsError=\(errorPage) events=\(events)"
    }
}

@MainActor func state(_ webView: WKWebView, _ navigation: Navigation) async -> State {
    let list = webView.backForwardList
    let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? "?"
    return State(back: list.backList.map(\.url.absoluteString), current: list.currentItem?.url.absoluteString ?? "nil",
                 forward: list.forwardList.map(\.url.absoluteString), title: title,
                 errorPage: navigation.committedErrorPage, events: navigation.events)
}

@MainActor func run() async {
    setvbuf(stdout, nil, _IOLBF, 0)
    print("load: \(forceSimulated ? "loadSimulatedRequest (forced)" : "_loadAlternateHTMLString if available")")
    let pageC = URL(string: "probe://c/")!
    let (a, b, c, f) = (pageA.absoluteString, pageB.absoluteString, pageC.absoluteString, failing.absoluteString)
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ now: State) {
        print("\(ok ? "PASS" : "FAIL")  \(name): \(now)")
        if !ok { failures += 1 }
    }
    /// A fresh windowless web view with its delegate and scheme handler (kept alive by the returned tuple).
    func makeWebView(pageCache: Bool = true) -> (WKWebView, Navigation, Pages) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let pages = Pages()
        configuration.setURLSchemeHandler(pages, forURLScheme: "probe")
        let setPageCache = NSSelectorFromString("_setUsesPageCache:")
        if !pageCache, configuration.preferences.responds(to: setPageCache) {
            configuration.preferences.perform(setPageCache, with: nil)  // nil reads as NO
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = Navigation()
        webView.navigationDelegate = navigation
        return (webView, navigation, pages)
    }
    func step(_ webView: WKWebView, _ navigation: Navigation, _ start: () -> Void) async -> State {
        navigation.events = []
        await navigation.run(start)
        return await state(webView, navigation)
    }

    // 1-4: error after A, B; Back; Forward; Reload, Back, Forward.
    let (webView, navigation, pages) = makeWebView()
    _ = pages
    _ = await step(webView, navigation) { webView.load(URLRequest(url: pageA)) }
    _ = await step(webView, navigation) { webView.load(URLRequest(url: pageB)) }
    var now = await step(webView, navigation) { webView.load(URLRequest(url: failing)) }
    check("error after A, B", now.back == [a, b] && now.current == f && now.title == errorTitle && now.errorPage, now)
    now = await step(webView, navigation) { webView.goBack() }
    check("Back", now.current == b && now.title == "b" && now.forward == [f] && !now.errorPage, now)
    now = await step(webView, navigation) { webView.goForward() }
    check("Forward", now.back == [a, b] && now.current == f && now.forward.isEmpty && now.title == errorTitle && now.errorPage, now)
    now = await step(webView, navigation) { webView.reload() }
    check("Reload", now.back == [a, b] && now.current == f && now.forward.isEmpty && now.errorPage, now)
    now = await step(webView, navigation) { webView.goBack() }
    check("Back after Reload", now.back == [a] && now.current == b && now.forward == [f] && !now.errorPage, now)
    now = await step(webView, navigation) { webView.goForward() }
    check("Forward after Reload", now.back == [a, b] && now.current == f && now.forward.isEmpty && now.errorPage, now)

    // 6: interactionState round-trip of the error tab (Tab.sleep / wake, session restore).
    let saved = webView.interactionState
    let (woken, wokenNavigation, wokenPages) = makeWebView()
    _ = wokenPages
    now = await step(woken, wokenNavigation) { woken.interactionState = saved }
    check("restored error tab", now.back == [a, b] && now.current == f && now.forward.isEmpty && now.errorPage, now)
    now = await step(woken, wokenNavigation) { woken.goBack() }
    check("Back after restore", now.back == [a] && now.current == b && now.title == "b" && now.forward == [f], now)

    // 5: A, B, C, then Back to B while B's server is down.
    let (backFails, backNavigation, backPages) = makeWebView(pageCache: false)
    for page in [pageA, pageB, pageC] { _ = await step(backFails, backNavigation) { backFails.load(URLRequest(url: page)) } }
    backPages.down = ["b"]
    now = await step(backFails, backNavigation) { backFails.goBack() }
    check("Back to a page that fails", now.back == [a] && now.current == b && now.forward == [c]
          && now.title == errorTitle && now.errorPage, now)

    // 7: crash page on B.
    let (crashing, crashNavigation, crashPages) = makeWebView()
    _ = crashPages
    _ = await step(crashing, crashNavigation) { crashing.load(URLRequest(url: pageA)) }
    _ = await step(crashing, crashNavigation) { crashing.load(URLRequest(url: pageB)) }
    // Kills the page's web process the way a crash would (SIGKILL to the pid WebKit reports).
    let pidSelector = NSSelectorFromString("_webProcessIdentifier")
    if crashing.responds(to: pidSelector), let pid = crashing.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 {
        now = await step(crashing, crashNavigation) { kill(pid, SIGKILL) }
        check("crash page", now.back == [a] && now.current == b && now.forward.isEmpty && now.title == errorTitle && now.errorPage, now)
    } else {
        print("skip  crash page: no _webProcessIdentifier")
    }

    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
