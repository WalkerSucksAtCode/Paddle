import AppKit
import os
import PaddleCore
import WebKit

/// A window a page's script opened without a click (Google Drive opens its finished zip this way, seconds after the
/// click). WebKit used to drop these silently. Now the window loads unseen first: a file goes to Downloads as if the
/// page had linked to it, and a page is cancelled before it renders and offered from the toolbar's Pop-up blocked
/// button, as Safari and Chrome do. Only http(s) addresses get this far; anything else is blocked outright.
final class PopupProbe: NSObject, WKNavigationDelegate {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "popups")
    /// Probes still loading. A probe removes itself when its load ends either way, or after `timeout`.
    private static var running: Set<PopupProbe> = []
    private static let timeout: Duration = .seconds(30)
    /// Probes one tab may have loading at once; more script windows are refused, so a page can't open hundreds.
    private static let perTab = 2
    /// Blocked addresses a tab lists at most.
    private static let listed = 10

    private let webView: WKWebView
    private weak var opener: Tab?
    private let openerID: UUID
    /// Captured at the start: the opener tab may close before the response arrives.
    private let isPrivate: Bool
    /// The opener's page when the window opened; a page blocked after the opener navigated away isn't offered.
    private let openerPage: URL?
    private var finished = false

    private init(webView: WKWebView, opener: Tab) {
        self.webView = webView
        self.opener = opener
        self.openerID = opener.id
        self.isPrivate = opener.isPrivate
        self.openerPage = opener.webView?.url
    }

    /// The web view WebKit hands back to `window.open`, or nil when the address can't be probed.
    static func start(configuration: WKWebViewConfiguration, url: URL, opener: Tab) -> WKWebView? {
        guard running.filter({ $0.openerID == opener.id }).count < perTab else {
            log.info("script-opened window refused: too many at once")
            return nil
        }
        WebEnvironment.configureProcessIdentity(configuration, displayName: "Paddle")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let probe = PopupProbe(webView: webView, opener: opener)
        webView.navigationDelegate = probe
        running.insert(probe)
        log.info("probing script-opened window to \(url.host() ?? "-", privacy: .private)")
        Task { @MainActor [weak probe] in
            try? await Task.sleep(for: timeout)
            probe?.end("timed out")
        }
        return webView
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            blocked(nil)
            return (.cancel, preferences)
        }
        // HTTPS-only lives in the tab's delegate; here a plain http:// address isn't loaded but offered, and opening
        // it from the button goes through the tab's upgrade.
        let config = AppModel.shared.config
        if scheme == "http", config.httpsOnly, config.sitePolicy(forHost: url?.host() ?? "").httpsOnly {
            blocked(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .cancel }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        if isAttachment || !navigationResponse.canShowMIMEType { return .download }
        // A page: it never renders here. The opener's toolbar offers it.
        blocked(navigationResponse.response.url)
        return .cancel
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        started(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        started(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        end("load failed")
    }

    private func started(_ download: WKDownload) {
        AppModel.shared.downloads.track(download, isPrivate: isPrivate, from: opener)
        end("became a download")
    }

    /// Offers `url` on the opener's Pop-up blocked button: http(s) only, while the opener still shows the page that
    /// opened it, at most `listed` of them.
    private func blocked(_ url: URL?) {
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let opener,
           opener.webView?.url == openerPage, !opener.blockedPopups.contains(url), opener.blockedPopups.count < Self.listed {
            opener.blockedPopups.append(url)
        }
        end("page blocked")
    }

    /// Drops the probe. A download it started carries on without it, as one from a closed tab does.
    private func end(_ reason: String) {
        guard !finished else { return }
        finished = true
        Self.log.info("script-opened window: \(reason, privacy: .public)")
        DispatchQueue.main.async {
            self.webView.navigationDelegate = nil
            Self.running.remove(self)
        }
    }
}
