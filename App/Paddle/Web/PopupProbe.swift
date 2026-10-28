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
    /// The opener's profile, for a download the probe starts (the opener may be gone by then).
    private let profileID: ProfileID
    /// The opener's page when the window opened; a page blocked after the opener navigated away isn't offered.
    private let openerPage: URL?
    private var finished = false
    /// Already sent to https:// once by HTTPS-only.
    private var upgraded = false

    private init(webView: WKWebView, opener: Tab) {
        self.webView = webView
        self.opener = opener
        self.openerID = opener.id
        self.isPrivate = opener.isPrivate
        self.profileID = opener.profileID
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
        if navigationAction.shouldPerformDownload {
            // No click reaches a hidden probe window, so its download asks first, through the opener's tab.
            let site = navigationAction.request.url?.host() ?? webView.url?.host() ?? "this page"
            guard await allowsDownload(site: site, filename: TabWebDelegate.promptFilename(navigationAction.request.url)) else {
                end("download refused")
                return (.cancel, preferences)
            }
            return (.download, preferences)
        }
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            blocked(nil)
            return (.cancel, preferences)
        }
        // HTTPS-only, as a tab applies it (local addresses and allowed sites stay http): the address loads over
        // https instead. Sent back to http after that, it isn't loaded but offered on the button.
        let app = AppModel.shared
        if let url, scheme == "http", let secure = HTTPSOnlyPolicy.upgrade(
            url, enabled: app.config.httpsOnly,
            siteAllowsHTTP: !app.config.sitePolicy(forHost: url.host() ?? "").httpsOnly,
            sessionExceptions: app.httpExceptions(isPrivate: isPrivate)
        ) {
            if upgraded {
                blocked(url)
            } else {
                upgraded = true
                webView.load(URLRequest(url: secure))
            }
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .cancel }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        if isAttachment || !navigationResponse.canShowMIMEType {
            let site = navigationResponse.response.url?.host() ?? webView.url?.host() ?? "this page"
            guard await allowsDownload(site: site, filename: navigationResponse.response.suggestedFilename ?? "a file") else {
                end("download refused")
                return .cancel
            }
            return .download
        }
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
        // A load this probe cancelled or turned into a download or an https load reports a failure too; the probe
        // carries on (or has already ended) and the timeout still drops it.
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        end("load failed")
    }

    /// Asks before a download this window starts, with the opener tab's download prompt (once per site per session).
    /// With no opener left (its tab closed) there is nowhere to ask, so the download is refused.
    private func allowsDownload(site: String, filename: String) async -> Bool {
        guard let delegate = opener?.webView?.navigationDelegate as? TabWebDelegate else {
            Self.log.info("script-opened download refused: no tab to ask")
            return false
        }
        return await delegate.allowsDownloads(from: site, filename: filename, scripted: true)
    }

    private func started(_ download: WKDownload) {
        AppModel.shared.downloads.track(download, isPrivate: isPrivate, profile: profileID, from: opener)
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
