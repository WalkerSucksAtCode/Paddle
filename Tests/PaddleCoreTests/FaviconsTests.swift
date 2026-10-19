import Foundation
@testable import PaddleCore
import Testing
import WebKit

struct FaviconsTests {
    let page = URL(string: "https://example.com/dir/page.html")!

    func icon(_ href: String, rel: String = "icon", sizes: String = "", type: String = "") -> IconCandidate {
        IconCandidate(href: href, rel: rel, sizes: sizes, type: type)
    }

    func best(_ candidates: [IconCandidate]) -> String? {
        FaviconPicker.bestIcon(candidates, pageURL: page)?.absoluteString
    }

    @Test func largeIconsPreferTouchIconsThenBigLinksThenTheRootTouchIcon() {
        let urls = FaviconPicker.largeIcons([
            icon("https://x.test/32.png", sizes: "32x32"),
            icon("https://x.test/192.png", sizes: "192x192"),
            icon("/touch-120.png", rel: "apple-touch-icon", sizes: "120x120"),
            icon("/touch.png", rel: "apple-touch-icon"),
            icon("/logo.svg", sizes: "512x512", type: "image/svg+xml"),
        ], pageURL: page).map(\.absoluteString)
        #expect(urls == [
            "https://example.com/touch.png",
            "https://example.com/touch-120.png",
            "https://x.test/192.png",
            "https://example.com/apple-touch-icon.png",
        ])
    }

    @Test func largeIconsFallBackToTheRootTouchIcon() {
        #expect(FaviconPicker.largeIcons([icon("/favicon.ico")], pageURL: page).map(\.absoluteString) == ["https://example.com/apple-touch-icon.png"])
        #expect(FaviconPicker.largeIcons([], pageURL: URL(string: "about:blank")!).isEmpty)
    }

    @Test func prefersSmallestSizeAtLeast32() {
        #expect(best([icon("https://x.test/192.png", sizes: "192x192"), icon("https://x.test/32.png", sizes: "16x16 32x32")]) == "https://x.test/32.png")
    }

    @Test func takesLargeWhenOnlySmallAndHuge() {
        #expect(best([icon("https://x.test/16.png", sizes: "16x16"), icon("https://x.test/192.png", sizes: "192x192")]) == "https://x.test/192.png")
    }

    @Test func svgIsSkipped() {
        #expect(best([icon("https://x.test/b.svg"), icon("https://x.test/a.png")]) == "https://x.test/a.png")
        #expect(best([icon("https://x.test/b", type: "image/svg+xml"), icon("https://x.test/a.png")]) == "https://x.test/a.png")
        #expect(best([icon("https://x.test/b.svg")]) == "https://example.com/favicon.ico")
    }

    @Test func sizelessIconBeatsAppleTouch() {
        #expect(best([icon("https://x.test/t.png", rel: "apple-touch-icon"), icon("https://x.test/i.png", rel: "shortcut icon")]) == "https://x.test/i.png")
    }

    @Test func largestAppleTouchIcon() {
        // All below 32 px so only the apple-touch rule decides.
        let result = best([
            icon("https://x.test/t1.png", rel: "apple-touch-icon", sizes: "16x16"),
            icon("https://x.test/t2.png", rel: "apple-touch-icon", sizes: "20x20"),
            icon("https://x.test/t3.png", rel: "apple-touch-icon", sizes: "18x18"),
        ])
        #expect(result == "https://x.test/t2.png")
    }

    @Test func relativeHrefsResolve() {
        #expect(best([icon("/favicon-32.png")]) == "https://example.com/favicon-32.png")
        #expect(best([icon("icon.png")]) == "https://example.com/dir/icon.png")
        #expect(best([icon("//cdn.test/i.png")]) == "https://cdn.test/i.png")
    }

    @Test func dataURLHandling() {
        #expect(best([icon("data:image/png;base64,AAAA")]) == "data:image/png;base64,AAAA")
        let huge = "data:image/png;base64," + String(repeating: "A", count: 100_001)
        #expect(best([icon(huge)]) == "https://example.com/favicon.ico")
        #expect(best([icon("data:text/html,hello")]) == "https://example.com/favicon.ico")
        #expect(best([icon("javascript:alert(1)")]) == "https://example.com/favicon.ico")
    }

    @Test func fallsBackToFaviconIcoWithPort() {
        let url = URL(string: "http://localhost:8080/some/path?q=1")!
        #expect(FaviconPicker.bestIcon([], pageURL: url)?.absoluteString == "http://localhost:8080/favicon.ico")
    }

    @Test func nilWithoutHostOrNonHTTP() {
        #expect(FaviconPicker.bestIcon([], pageURL: URL(string: "file:///tmp/a.html")!) == nil)
        #expect(FaviconPicker.bestIcon([], pageURL: URL(string: "about:blank")!) == nil)
        #expect(FaviconPicker.bestIcon([], pageURL: URL(string: "ftp://example.com/x")!) == nil)
    }

    @Test func nonSquareUsesSmallerSideAndMalformedIgnored() {
        #expect(FaviconPicker.parseSizes("64X32 abc 16x 48x48 any") == [32, 48])
        #expect(best([icon("https://x.test/w.png", sizes: "128x16"), icon("https://x.test/ok.png", sizes: "40x40")]) == "https://x.test/ok.png")
    }

    @Test func cacheKeyStripsWwwAndLowercases() {
        #expect(FaviconPicker.cacheKey(for: URL(string: "https://WWW.Example.COM/a")!) == "example.com")
        #expect(FaviconPicker.cacheKey(for: URL(string: "https://sub.example.com/")!) == "sub.example.com")
        #expect(FaviconPicker.cacheKey(for: URL(string: "about:blank")!) == nil)
    }

    @Test func cacheKeySeparatesExplicitPorts() {
        let a = FaviconPicker.cacheKey(for: URL(string: "http://localhost:3000/x")!)
        let b = FaviconPicker.cacheKey(for: URL(string: "http://localhost:8080/")!)
        #expect(a == "localhost:3000")
        #expect(b == "localhost:8080")
        #expect(FaviconPicker.cacheKey(for: URL(string: "https://www.Example.com:8443/")!) == "example.com:8443")
        #expect(FaviconPicker.cacheKey(for: URL(string: "http://localhost/")!) == "localhost")
    }

    @Test func sizedAppleTouchIconDoesNotBeatPlainIcon() {
        // Tier 1 (declared size >= 32) only counts icon / shortcut icon links.
        #expect(best([
            icon("https://x.test/favicon.ico", rel: "icon", sizes: "any"),
            icon("https://x.test/touch.png", rel: "apple-touch-icon", sizes: "180x180"),
        ]) == "https://x.test/favicon.ico")
        #expect(best([
            icon("https://x.test/touch.png", rel: "apple-touch-icon", sizes: "180x180"),
            icon("https://x.test/48.png", rel: "shortcut icon", sizes: "48x48"),
        ]) == "https://x.test/48.png")
        #expect(best([icon("https://x.test/touch.png", rel: "apple-touch-icon", sizes: "180x180")]) == "https://x.test/touch.png")
    }

    @Test func candidateResolvingToThePageItselfIsDropped() {
        // An href of "#x" or the page's own address (fragment aside) is the page, not an icon.
        #expect(best([icon("#x", sizes: "64x64")]) == "https://example.com/favicon.ico")
        #expect(best([icon("page.html#frag", sizes: "64x64"), icon("https://x.test/i.png")]) == "https://x.test/i.png")
        #expect(FaviconPicker.bestIcon([icon("https://example.com/dir/page.html")], pageURL: URL(string: "https://example.com/dir/page.html#top")!)?.absoluteString == "https://example.com/favicon.ico")
    }

    @Test func collectScriptFiltersOnTheHrefAttribute() {
        #expect(FaviconPicker.collectScript.contains("(link.getAttribute('href') || '').trim()"))
        #expect(!FaviconPicker.collectScript.contains("&& link.href;"))
    }

    @Test func fileNameIsStable() {
        let name = FaviconPicker.fileName(forKey: "example.com")
        #expect(name == FaviconPicker.fileName(forKey: "example.com"))
        #expect(name != FaviconPicker.fileName(forKey: "example.org"))
        #expect(name.count == 20)
        #expect(name.hasSuffix(".png"))
    }

    @Test func staleBoundary() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        #expect(!FaviconPicker.isStale(fetchedAt: fetched, now: fetched.addingTimeInterval(7 * 86_400)))
        #expect(FaviconPicker.isStale(fetchedAt: fetched, now: fetched.addingTimeInterval(7 * 86_400 + 1)))
    }

    /// Runs the real script in a windowless web view on an offline page (an https base URL, as the scriptlet tests do).
    @MainActor @Test func collectScriptReadsTheLinksOfALoadedPage() async throws {
        let html = """
            <html><head>
            <link rel="stylesheet" href="/style.css">
            <link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
            <link rel="Shortcut Icon" href="fav.ico">
            <link rel="apple-touch-icon" href="https://cdn.example.net/touch.png" sizes="180x180">
            <link rel="mask-icon" href="/mask.svg">
            <link rel="icon" href="">
            <link rel="icon">
            </head><body>page</body></html>
            """
        let webView = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/dir/page.html"))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            // The initial about:blank is "complete" at once; wait for the page itself.
            let ready = "location.protocol === 'https:' && document.readyState === 'complete'"
            if (try? await webView.evaluateJavaScript(ready) as? Bool) == true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let json = try #require(try await webView.evaluateJavaScript(FaviconPicker.collectScript) as? String)
        let found = try JSONDecoder().decode([IconCandidate].self, from: Data(json.utf8))
        #expect(found == [
            IconCandidate(href: "https://example.com/favicon-32.png", rel: "icon", sizes: "32x32", type: "image/png"),
            IconCandidate(href: "https://example.com/dir/fav.ico", rel: "Shortcut Icon"),
            IconCandidate(href: "https://cdn.example.net/touch.png", rel: "apple-touch-icon", sizes: "180x180"),
        ])
        #expect(FaviconPicker.bestIcon(found, pageURL: URL(string: "https://example.com/dir/page.html")!)?.absoluteString
            == "https://example.com/favicon-32.png")
    }
}
