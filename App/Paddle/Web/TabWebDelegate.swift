import AppKit
import Foundation
import os
import PaddleCore
import WebKit

/// WebKit callbacks for one tab: link routing, popups, downloads, dialogs, uploads, permissions, errors.
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    init(tab: Tab) {
        self.tab = tab
    }

    private static let webSchemes = Set(["http", "https", "file", "about", "data", "blob", "javascript"]).union(ExtensionIdentity.schemes)

    private static func isWebPage(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Navigation policy

    private static let isUserInitiatedKey = "_isUserInitiated"
    private static let hasOpenerKey = "_hasOpener"

    /// A real click or key press started this navigation. Without this a script calling a.click(), or
    /// dispatching a click with metaKey set, looks exactly like the user. Private WebKit API; when it is
    /// missing, nothing counts as user-initiated, so Paddle asks rather than acts.
    private static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        guard action.responds(to: NSSelectorFromString(isUserInitiatedKey)) else { return false }
        return (action.value(forKey: isUserInitiatedKey) as? Bool) ?? false
    }

    /// Host of the frame that asked for a navigation, read through KVC because WebKit can leave it nil.
    private static func requester(_ action: WKNavigationAction) -> String? {
        (action.value(forKey: "sourceFrame") as? WKFrameInfo)?.securityOrigin.host
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let byUser = Self.isUserInitiated(navigationAction)
        if isMainFrame {
            mainFrameNavigationType = navigationAction.navigationType
            mainFrameIsPost = navigationAction.request.httpMethod?.uppercased() == "POST"
            mainFrameResponded = false
        }

        // mailto:, zoommtg:, slack: ... hand off to the right app. A real click opens it; a script or redirect
        // (a "Launch meeting" page) asks first, so pages can't launch apps unprompted.
        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            let clicked = byUser && navigationAction.navigationType == .linkActivated
            let requester = Self.requester(navigationAction) ?? webView.url?.host()
            Task { await openExternally(url, ask: !clicked, requester: requester) }
            return (.cancel, preferences)
        }

        // Extension pages and web pages need different web views (section "Sleeping tabs and extension pages").
        // A page never navigates a tab into an extension's configuration: that would skip WebKit's
        // web-accessible-resources check, so pages can't reach an extension's private pages. Only Paddle's own
        // `Tab.load` (address bar, extension `tabs.update`) goes that way. Subframes are left to WebKit's rules.
        let targetExtension = ExtensionIdentity.identifier(of: url)
        if isMainFrame, let tab, targetExtension != nil, targetExtension != tab.extensionPageID {
            // URLs are `.private`: the unified log keeps notices on disk, and this can be a private window's page.
            Self.log.notice("blocked navigation to \(url.absoluteString, privacy: .private) from \(webView.url?.absoluteString ?? "-", privacy: .private)")
            return (.cancel, preferences)
        }

        // Cmd-click or middle-click: background tab (Cmd-Shift-click: foreground). Only for real clicks; a page
        // faking one just navigates, so it can't open tabs past the popup blocker.
        if navigationAction.navigationType == .linkActivated, byUser, let tab, let browser = tab.browser {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == 4 {
                browser.newTab(url: url, select: flags.contains(.shift), after: Self.anchor(for: tab, in: browser))
                return (.cancel, preferences)
            }
            // Option-click (left button, which WebKit numbers 1): the link opens in the window's preview, any frame,
            // target=_blank too. Inside the preview it navigates the preview instead (no preview in a preview); a
            // target=_blank link there would otherwise become a tab.
            if flags.contains(.option), navigationAction.buttonNumber == 1, AppModel.shared.config.linkPreview, Self.isWebPage(url) {
                if !tab.isPreview {
                    browser.openPreview(url, from: tab)
                    return (.cancel, preferences)
                }
                if navigationAction.targetFrame == nil {
                    webView.load(navigationAction.request)
                    return (.cancel, preferences)
                }
            }
        }

        // HTTPS-only: an http:// main-frame load (not a Cmd-click, which opens a tab that is checked itself) goes to https:// instead; a loop back to http:// is blocked.
        if isMainFrame, let tab {
            if handleHTTPSOnly(url, in: tab, navigationAction, webView) { return (.cancel, preferences) }
            tab.httpsOnlyBlocked = nil
        }

        // An extension page leaving for a web page: WebKit would cancel it silently in this web view, so swap in an
        // ordinary one. On the next runloop turn, since the swap drops this web view and its delegate. Other schemes
        // (about:blank, blob:, file:) stay in this web view under WebKit's rules for the extension's origin.
        // By then the tab or its window may have closed; waking it would load the page in a tab nobody owns.
        if isMainFrame, let tab, tab.extensionPageID != nil, Self.isWebPage(url) {
            DispatchQueue.main.async {
                guard let browser = tab.browser, browser.allTabs.contains(where: { $0 === tab }),
                      let controller = browser.controller, AppModel.shared.windows.contains(where: { $0 === controller })
                else { return }
                tab.replaceWebView(loading: url)
            }
            return (.cancel, preferences)
        }

        if isMainFrame, let host = url.host() {
            if Self.isWebPage(url) { Self.apply(AppModel.shared.config.sitePolicy(forHost: host), to: preferences) }
            return (applySiteUserAgent(for: host, navigationAction, preferences, in: webView) ? .allow : .cancel, preferences)
        }
        return (.allow, preferences)
    }

    /// True when the http:// main-frame navigation `url` was handled by HTTPS-only mode: the https:// load started in
    /// this tab, or the tab marked blocked because the same host sent it back to http:// within 10 s.
    private func handleHTTPSOnly(_ url: URL, in tab: Tab, _ action: WKNavigationAction, _ webView: WKWebView) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false) else { return false }
        let app = AppModel.shared
        guard let secure = HTTPSOnlyPolicy.upgrade(
            url, enabled: app.config.httpsOnly,
            siteAllowsHTTP: !app.config.sitePolicy(forHost: host).httpsOnly,
            sessionExceptions: app.httpExceptions
        ) else { return false }
        let normalized = PaddleConfig.normalizedHost(host)
        // Sent back to http:// for the same host within 10 s, by a redirect, script or meta refresh (not by the user
        // typing it): a loop, so stop and show the notice.
        if let last = tab.lastHTTPSUpgrade, last.host == normalized, Date().timeIntervalSince(last.at) < 10,
           action.navigationType == .other, !tab.typedNavigationPending {
            tab.httpsUpgrade = nil
            tab.lastHTTPSUpgrade = nil
            tab.httpsOnlyBlocked = url
        } else {
            tab.httpsUpgrade = (url, Date())
            tab.lastHTTPSUpgrade = (normalized, Date())
            tab.httpsOnlyBlocked = nil
            var request = action.request
            request.url = secure
            DispatchQueue.main.async { [weak webView] in webView?.load(request) }
        }
        return true
    }

    /// Errors that mean the https:// side of an upgraded address isn't usable (no TLS, bad certificate, refused,
    /// timed out, dropped). A host that doesn't resolve is an ordinary failure.
    private static func isSecureConnectionProblem(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
        ].contains(error.code)
    }

    private static let setAutoplayPolicy = NSSelectorFromString("_setAutoplayPolicy:")

    /// WebKit's private per-navigation autoplay policy (`WKWebpagePreferences._autoplayPolicy`) exists. Without it
    /// every site gets the configuration's default (media may autoplay muted) and per-site autoplay does nothing.
    static let supportsSiteAutoplay = WKWebpagePreferences.instancesRespond(to: setAutoplayPolicy)

    /// The host's `sites` settings for this main-frame navigation only: JavaScript, and autoplay where WebKit has
    /// the private policy. Zoom is set when the page commits (`Tab.applySiteZoom`); content blocking is compiled
    /// into the block lists (`WebEnvironment.performBlockerLoad`).
    private static func apply(_ policy: SitePolicy, to preferences: WKWebpagePreferences) {
        preferences.allowsContentJavaScript = policy.javaScript
        guard supportsSiteAutoplay else { return }
        // `_WKWebsiteAutoplayPolicy`: 0 is the configuration's default (sound waits for a click or key, the "muted"
        // setting), 1 allows sound, 3 denies all autoplay. WebKit uses a non-default value instead of the
        // configuration's `mediaTypesRequiringUserActionForPlayback`.
        let value: Int
        switch policy.autoplay {
        case .muted: value = 0
        case .allow: value = 1
        case .block: value = 3
        }
        typealias SetPolicy = @convention(c) (AnyObject, Selector, Int) -> Void
        let set = unsafeBitCast(preferences.method(for: setAutoplayPolicy), to: SetPolicy.self)
        set(preferences, setAutoplayPolicy, value)
    }

    private static let setCustomUserAgent = NSSelectorFromString("_setCustomUserAgent:")

    /// The host's user agent from config.json: `siteUserAgents`, else its `sitePersonas` persona. Returns false when the
    /// load was cancelled to restart it.
    private func applySiteUserAgent(
        for host: String, _ navigationAction: WKNavigationAction, _ preferences: WKWebpagePreferences, in webView: WKWebView
    ) -> Bool {
        // Responsive Design Mode's device agent wins over siteUserAgents and personas while it is on.
        let wanted = tab?.responsive?.userAgent.string ?? AppModel.shared.config.pageUserAgent(forHost: host)
        // Private WebKit API: a user agent for this navigation only, so history, form posts and restored
        // state are untouched.
        if preferences.responds(to: Self.setCustomUserAgent) {
            if let wanted { preferences.perform(Self.setCustomUserAgent, with: wanted) }
            return true
        }
        // Fallback: set the web view's agent and restart the load. Only for plain GET loads; going back or
        // re-posting a form keeps the current agent rather than lose history or the form body.
        // WebKit reports an unset custom user agent as "", not nil.
        guard (webView.customUserAgent ?? "") != (wanted ?? ""),
              [.linkActivated, .other].contains(navigationAction.navigationType),
              (navigationAction.request.httpMethod ?? "GET") == "GET" else { return true }
        webView.customUserAgent = wanted
        webView.load(navigationAction.request)
        return false
    }

    private var isAskingToOpenApp = false
    /// Sites whose "open app" request was cancelled in this tab; they aren't asked about again.
    private var refusedAppRequesters: Set<String> = []

    /// Opens a non-web URL in the app that handles it. When a page rather than a click started it, Paddle asks,
    /// names the site, and ignores requests from tabs that aren't showing.
    private func openExternally(_ url: URL, ask: Bool, requester: String?) async {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            // Pages probe for installed apps with scripted navigations; only say "no app" for a click.
            guard !ask else { return }
            let alert = NSAlert()
            alert.messageText = "No app can open this link"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "OK")
            _ = await present(alert)
            return
        }
        if ask {
            let site = requester ?? "This page"
            guard let tab, tab.browser?.selectedID == tab.id, !isAskingToOpenApp, !refusedAppRequesters.contains(site) else { return }
            isAskingToOpenApp = true
            defer { isAskingToOpenApp = false }
            let name = FileManager.default.displayName(atPath: app.path)
            let alert = NSAlert()
            alert.messageText = "Open “\(name)”?"
            alert.informativeText = "\(site) wants to open a \(url.scheme ?? "") link in \(name)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard await present(alert) == .alertFirstButtonReturn else {
                refusedAppRequesters.insert(site)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { mainFrameResponded = true }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        guard isAttachment || !navigationResponse.canShowMIMEType else { return .allow }
        // Any frame can download: sites export files through hidden iframes. A frame from another site (an ad)
        // needs permission first, once per site per session, like Safari's "Allow downloads" prompt.
        if !navigationResponse.isForMainFrame, let site = navigationResponse.response.url?.host(), site != webView.url?.host(),
           !(await allowsDownloads(from: site, filename: navigationResponse.response.suggestedFilename ?? "a file")) {
            return .cancel
        }
        return .download
    }

    private func allowsDownloads(from site: String, filename: String) async -> Bool {
        let app = AppModel.shared
        let isPrivate = tab?.isPrivate ?? true
        let profile = tab?.profileID ?? ProfileStore.defaultID
        if let answer = app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: .downloads) { return answer }
        let alert = NSAlert()
        alert.messageText = "Allow downloads from \(site)?"
        alert.informativeText = "A frame from \(site) on this page wants to download “\(filename)”."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let response = await present(alert) { app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: .downloads) == nil }
        if response == .abort { return app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: .downloads) ?? false }
        let allow = response == .alertFirstButtonReturn
        app[permissionsFor: isPrivate, profile: profile].record(allow, site: site, kinds: [.downloads])
        return allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        AppModel.shared.downloads.track(download, isPrivate: tab?.isPrivate ?? false)
        tabShowsNothingAfterDownload(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        AppModel.shared.downloads.track(download, isPrivate: tab?.isPrivate ?? false)
        tabShowsNothingAfterDownload(webView)
    }

    /// The tab's only load became a download, so it has no page. A tab opened just for that load (a target=_blank
    /// file link, a file URL from another app) closes, as in Chrome, and stays out of Reopen Closed Tab, which
    /// would download the file again. A tab the user typed the URL into goes back to the start page.
    private func tabShowsNothingAfterDownload(_ webView: WKWebView) {
        tab?.typedNavigationPending = false
        guard let tab, webView.backForwardList.currentItem == nil, let browser = tab.browser else { return }
        DispatchQueue.main.async {
            // A preview opened for a file link has nothing to show either.
            if tab.isPreview {
                if browser.preview === tab { browser.closePreview() }
            } else if tab.closesIfOnlyDownload, browser.allTabs.count > 1 {
                browser.close(tab, remember: false)
            } else {
                tab.url = nil
                browser.tabURLChanged(tab)
            }
        }
    }

    // MARK: - HTTP authentication

    private static let passwordMethods: Set<String> = [
        NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
    ]

    /// HTTP Basic/Digest/NTLM logins get a sheet. Server trust and client certificates stay with WebKit.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard Self.passwordMethods.contains(space.authenticationMethod) else { return (.performDefaultHandling, nil) }

        let alert = NSAlert()
        alert.messageText = "Log in to \(space.host)"
        var notes: [String] = []
        if challenge.previousFailureCount > 0 { notes.append("The user name or password was incorrect.") }
        if let realm = space.realm, !realm.isEmpty { notes.append("The site says: “\(realm)”") }
        if !space.receivesCredentialSecurely { notes.append("Your password will be sent unencrypted.") }
        alert.informativeText = notes.joined(separator: "\n")

        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "User name"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Password"
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        for field in [user, password] { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        alert.accessoryView = fields
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password

        guard await present(alert) == .alertFirstButtonReturn else {
            // What WebKit does with no delegate: the page loads without credentials and shows the server's 401 page.
            return (.rejectProtectionSpace, nil)
        }
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    // MARK: - Link hover

    /// Private WebKit callback for the pointer moving over page content; feeds the status bubble. If WebKit
    /// stops calling it, there is simply no bubble.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func _webView(_ webView: WKWebView, mouseDidMoveOverElement hitTestResult: NSObject?, withFlags flags: UInt, userInfo: NSObject?) {
        var link: URL?
        if let hitTestResult, hitTestResult.responds(to: NSSelectorFromString("absoluteLinkURL")) {
            link = hitTestResult.value(forKey: "absoluteLinkURL") as? URL
        }
        if link?.scheme?.lowercased() == "javascript" {
            link = URL(string: "javascript:")
        }
        if tab?.hoveredLink != link { tab?.hoveredLink = link }
    }

    // MARK: - History

    /// How the pending main-frame navigation started; reloads, back/forward and session restores aren't new visits.
    private var mainFrameNavigationType: WKNavigationType?
    /// The pending main-frame navigation sends a form post (`Tab.committedPost`).
    private var mainFrameIsPost = false

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.hoveredLink = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.hoveredLink = nil
        tab?.httpsUpgrade = nil
        trackErrorPageItem(webView)
        tab?.committedPost = mainFrameIsPost
        tab?.pageCommitted()
        guard let tab, let url = webView.url else { return }
        defer {
            tab.typedNavigationPending = false
            mainFrameNavigationType = nil
        }
        tab.historyURL = nil
        if tab.skipNextCommitInHistory {
            tab.skipNextCommitInHistory = false
            return
        }
        if let type = mainFrameNavigationType, [.backForward, .reload, .formResubmitted].contains(type) { return }
        recordInHistory(url, webView, typed: tab.typedNavigationPending)
    }

    /// Private windows record nothing; `historyURL` stays nil, so title changes write nothing either.
    private func recordInHistory(_ url: URL, _ webView: WKWebView, typed: Bool) {
        guard let tab, !tab.isPrivate else { return }
        let title = webView.title ?? ""
        AppModel.shared.recordVisit(url, title: title, typed: typed, profile: tab.profileID)
        tab.historyURL = url
        tab.historyTitle = title
    }

    /// Private WebKit delegate callback for history.pushState and friends: single-page sites (YouTube, GitHub)
    /// change pages without a commit. Only pushes are new pages; anchors, replaces and pops are not.
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        let sessionStatePush = 1
        guard type == sessionStatePush, let url = webView.url else { return }
        recordInHistory(url, webView, typed: false)
    }

    /// Private windows fetch no icons (nothing reaches favicons/ or the in-memory cache); they show icons already
    /// on disk from normal browsing.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.checkReaderAvailability()
        guard tab?.isPrivate == false else { return }
        Task { await AppModel.shared.favicons.refresh(for: webView) }
    }

    // MARK: - Failures

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        tab?.typedNavigationPending = false
        let nsError = error as NSError
        if let tab, let upgrade = tab.httpsUpgrade,
           Date().timeIntervalSince(upgrade.at) < 30, Self.isSecureConnectionProblem(nsError),
           let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url,
           failing.scheme?.lowercased() == "https",
           PaddleConfig.normalizedHost(failing.host(percentEncoded: false) ?? "")
               == PaddleConfig.normalizedHost(upgrade.original.host(percentEncoded: false) ?? "") {
            tab.httpsUpgrade = nil
            tab.httpsOnlyBlocked = upgrade.original
            return
        }
        showErrorPage(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // Failures after the page started rendering leave the partial page; WebKit shows nothing extra.
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.processTerminated()
    }

    /// The same with WebKit's reason (private `WKNavigationDelegatePrivate`, in macOS 27's WebKit). WebKit calls this
    /// instead of the public method when the delegate has it; the public one stays for a WebKit without it.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        tab?.processTerminated(reason: Tab.TerminationReason(rawValue: reason))
    }

    /// Back/forward items that showed one of Paddle's error pages. Going back or forward to one, WebKit can show
    /// the stored error page again without loading anything (no new `pendingOwnPage`); it is still an error page.
    private let errorPageItems = NSHashTable<WKBackForwardListItem>.weakObjects()
    /// The pending main-frame navigation got a response from the site, so what commits is the site's page.
    private var mainFrameResponded = false

    /// Called on each main-frame commit, before `Tab.pageCommitted` reads `pendingOwnPage`.
    private func trackErrorPageItem(_ webView: WKWebView) {
        defer { mainFrameResponded = false }
        guard let tab, let item = webView.backForwardList.currentItem else { return }
        if tab.pendingOwnPage == .error {
            errorPageItems.add(item)
        } else if tab.pendingOwnPage == nil, !mainFrameResponded, errorPageItems.contains(item) {
            tab.pendingOwnPage = .error
        } else {
            errorPageItems.remove(item)
        }
    }

    private func showErrorPage(_ webView: WKWebView, _ error: any Error) {
        let nsError = error as NSError
        // Cancelled loads, and loads that turned into downloads, are not errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return }

        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab?.url
        let html = Self.errorPage(title: "Can't open this page", message: nsError.localizedDescription, url: failing)
        tab?.skipNextCommitInHistory = true
        tab?.pendingOwnPage = .error
        Self.loadErrorPage(html, for: failing, in: webView)
    }

    /// Shows `html` for the failed load of `url`, with its own back/forward item, as Safari does: Back
    /// goes to the previous page; Forward, Reload or Try Again retry `url`. (`loadHTMLString` with `url`
    /// as base added no item, so Back skipped the previous page.) Prefers WebKit's alternate-HTML load,
    /// which reuses the failing item. The fallback (a simulated request) appends a new item — a failed
    /// Back loses the forward list, a woken/restored error tab gets the entry twice — and Forward
    /// re-shows the cached error page without retrying. Runs in `url`'s origin, so that site's user
    /// and content scripts may run.
    static func loadErrorPage(_ html: String, for url: URL?, in webView: WKWebView) {
        guard let url else {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let selector = NSSelectorFromString("_loadAlternateHTMLString:baseURL:forUnreachableURL:")
        if webView.responds(to: selector) {
            typealias LoadAlternate = @convention(c) (AnyObject, Selector, NSString, NSURL, NSURL) -> Void
            unsafeBitCast(webView.method(for: selector), to: LoadAlternate.self)(
                webView, selector, html as NSString, url as NSURL, url as NSURL)
        } else {
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        }
    }

    /// A plain page with a Try Again button that reloads `url`. Loaded as the page for `url` (see `loadErrorPage`),
    /// so the address bar keeps showing the page that failed.
    static func errorPage(title: String, message: String, url: URL?, button: String = "Try Again") -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        let urlText = url?.absoluteString ?? ""
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>
          body { font: 14px -apple-system, sans-serif; max-width: 34rem; margin: 18vh auto; padding: 0 1.5rem; color: CanvasText; }
          h1 { font-size: 1.4rem; margin: 0 0 .6rem; }
          p { color: GrayText; line-height: 1.5; overflow-wrap: anywhere; }
          .action-btn { font: inherit; padding: .35rem 1rem; display: inline-block; color: CanvasText; background: ButtonFace; border: 1px solid GrayText; border-radius: 4px; text-decoration: none; cursor: default; }
          .action-btn:active { filter: brightness(0.9); }
        </style>
        <h1>\(escape(title))</h1>
        <p>\(escape(message))</p>
        <p>\(escape(urlText))</p>
        <a class="action-btn" role="button" href="\(escape(urlText))">\(escape(button))</a>
        """
    }

    // MARK: - Windows

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Popups (including sign-in windows) become tabs. Returning WebKit's own configuration keeps
        // window.opener working, which OAuth flows need.
        guard let tab, let browser = tab.browser else { return nil }
        // window.open("mailto:...") opens the mail app instead of an empty tab, asking unless a real click did it.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            let ask = !Self.isUserInitiated(navigationAction)
            let requester = Self.requester(navigationAction) ?? webView.url?.host()
            Task { await openExternally(url, ask: ask, requester: requester) }
            return nil
        }
        // The same split as in navigation policy. An extension page opening a web page gets an ordinary tab. Its own
        // pages, window.open() with no URL, about:blank, blob: and data: open as a popup in its configuration, so
        // the opener gets a window handle and the popup's own load isn't refused. Anything else (file:, another
        // extension) is blocked. A web page can't open an extension page at all.
        let requestURL = navigationAction.request.url
        let targetExtension = ExtensionIdentity.identifier(of: requestURL)
        if let pageID = tab.extensionPageID {
            if Self.isWebPage(requestURL) {
                browser.newTab(url: requestURL, after: Self.anchor(for: tab, in: browser))
                return nil
            }
            let scheme = requestURL?.scheme?.lowercased() ?? ""
            guard requestURL == nil || ["about", "blob", "data"].contains(scheme) || targetExtension == pageID else {
                Self.log.notice("blocked window.open of \(requestURL?.absoluteString ?? "-", privacy: .private) from \(webView.url?.absoluteString ?? "-", privacy: .private)")
                return nil
            }
        } else if targetExtension != nil {
            Self.log.notice("blocked window.open of \(requestURL?.absoluteString ?? "-", privacy: .private) from \(webView.url?.absoluteString ?? "-", privacy: .private)")
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        // window.open() with no URL has no request URL; about:blank keeps the tab showing its web view
        // (which the opener may write into) instead of the start page.
        let newTab = Tab(url: navigationAction.request.url ?? URL(string: "about:blank"), isPrivate: tab.isPrivate)
        // From a preview, the tab underneath stands in as opener: selecting the popup closes the preview.
        let anchor = Self.anchor(for: tab, in: browser)
        newTab.opener = anchor
        newTab.returnsToOpener = true
        newTab.closesIfOnlyDownload = true
        // Private WebKit API: whether the page keeps a window.opener reference (plain target=_blank links are
        // noopener). Without it, treat script-opened windows as having one.
        if tab.isPreview {
            // Its opener page goes away with the preview, so nothing holds the two awake together.
            newTab.hasLiveOpener = false
        } else if navigationAction.responds(to: NSSelectorFromString(Self.hasOpenerKey)) {
            newTab.hasLiveOpener = (navigationAction.value(forKey: Self.hasOpenerKey) as? Bool) ?? false
        } else {
            newTab.hasLiveOpener = navigationAction.navigationType == .other
        }
        // A popup from an extension page shares its configuration (WebKit's `configuration` is that page's).
        newTab.attach(popup, extensionPageID: tab.extensionPageID)
        browser.insert(newTab, after: anchor, select: true)
        return popup
    }

    /// Where a tab opened from `tab` goes: after it, or for the link preview after the tab underneath (the selected
    /// tab if that one is gone).
    private static func anchor(for tab: Tab, in browser: BrowserModel) -> Tab? {
        tab.isPreview ? browser.previewSource ?? browser.selectedTab : tab
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let browser = tab.browser else { return }
        // window.close() in the preview closes the preview.
        if tab.isPreview {
            if browser.preview === tab { browser.closePreview() }
            return
        }
        // A popup that never showed a page (it only started a download) stays out of Reopen Closed Tab.
        // A page closing its own window (a finished sign-in) always hands focus back to the opener.
        browser.close(tab, remember: webView.backForwardList.currentItem != nil, returnToOpener: true)
    }

    // MARK: - Context menu

    private static let openLinkInNewWindowItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    private static let reloadItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierReload")

    /// Private WebKit callback with the page's context menu before it shows. If WebKit stops calling
    /// this, the menu is WebKit's own. Paddle adds:
    /// - on an http(s) link, "Preview Link" after "Open Link in New Window", for the link WebKit
    ///   hit-tested (not the last hovered — that differs for a keyboard-opened menu);
    /// - on the page (the menu with Reload), "Add Page to New Tab Page" (or Remove) after Reload, for
    ///   this tab, which in a split may be the unfocused side.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func _webView(_ webView: WKWebView, getContextMenuFromProposedMenu menu: NSMenu, forElement element: NSObject, userInfo: NSObject?, completionHandler: @escaping (NSMenu?) -> Void) {
        defer { completionHandler(menu) }
        guard let tab, !tab.isPreview else { return }
        let hit = element.responds(to: NSSelectorFromString("hitTestResult")) ? element.value(forKey: "hitTestResult") as? NSObject : nil
        let link = hit.flatMap { $0.responds(to: NSSelectorFromString("absoluteLinkURL")) ? $0.value(forKey: "absoluteLinkURL") as? URL : nil }
        if let link, Self.isWebPage(link), AppModel.shared.config.linkPreview,
           let index = menu.items.firstIndex(where: { $0.identifier == Self.openLinkInNewWindowItem }) {
            let item = NSMenuItem(title: "Preview Link", action: #selector(previewLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link
            menu.insertItem(item, at: index + 1)
        }
        if !tab.isPrivate, let url = tab.url, HistoryStore.isRecordable(url),
           let index = menu.items.firstIndex(where: { $0.identifier == Self.reloadItem }) {
            let store = AppModel.shared.newTab
            let pinned = store.contains(url: HistoryStore.storedURL(url))
            let item = NSMenuItem(title: pinned ? "Remove from New Tab Page" : "Add Page to New Tab Page", action: #selector(toggleNewTabSite(_:)), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index + 1)
        }
    }

    @objc private func toggleNewTabSite(_ sender: NSMenuItem) {
        guard let tab else { return }
        BrowserWindowController.toggleNewTabSite(for: tab)
    }

    @objc private func previewLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? URL, let tab, let browser = tab.browser else { return }
        browser.openPreview(link, from: tab)
    }

    // MARK: - JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = makeAlert(frame, message)
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = makeAlert(frame, message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = makeAlert(frame, prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func makeAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, isStillNeeded: () -> Bool = { true }) async -> NSApplication.ModalResponse {
        guard let tab else { return .abort }
        return await tab.present(alert, isStillNeeded: isStillNeeded)
    }

    // MARK: - Uploads and permissions

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let tab, await tab.waitUntilSelected() else { return nil }
        let response: NSApplication.ModalResponse
        if let window = tab.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let devices: [SessionPermissions.Kind]
        switch type {
        case .camera: devices = [.camera]
        case .microphone: devices = [.microphone]
        default: devices = [.camera, .microphone]
        }
        // Granted per device, so allowing camera and microphone also covers a later microphone-only request. Only
        // grants are kept: a refused site asks again next time.
        let site = Self.site(of: origin)
        let app = AppModel.shared
        let isPrivate = tab?.isPrivate ?? true
        let profile = tab?.profileID ?? ProfileStore.defaultID
        if app[permissionsFor: isPrivate, profile: profile].allows(site: site, kinds: devices) { return .grant }

        let alert = NSAlert()
        alert.messageText = "Allow \(origin.host) to use your \(devices.map(\.rawValue).joined(separator: " and "))?"
        alert.informativeText = "If you allow, Paddle won’t ask again for this site until it quits."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let response = await present(alert) { !app[permissionsFor: isPrivate, profile: profile].allows(site: site, kinds: devices) }
        if response == .abort { return app[permissionsFor: isPrivate, profile: profile].allows(site: site, kinds: devices) ? .grant : .deny }
        let allowed = response == .alertFirstButtonReturn
        if allowed { app[permissionsFor: isPrivate, profile: profile].record(true, site: site, kinds: devices) }
        return allowed ? .grant : .deny
    }

    /// `https://example.com:443`: the key session answers for capture and location use.
    private static func site(of origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    /// Geolocation: `sites.<host>.location` allow or deny answers without asking. Otherwise Paddle asks once per
    /// site per session; "Remember" also writes the answer to `sites.<host>.location` (not offered in private
    /// windows, which write nothing to config.json). macOS then asks once whether Paddle may use Location Services.
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        let app = AppModel.shared
        let host = origin.host
        switch app.config.sitePolicy(forHost: host).location {
        case .allow: return .grant
        case .deny: return .deny
        case .ask: break
        }
        let allowed = await askSitePermission(
            .location,
            field: .location,
            origin: origin,
            question: "Allow \(host.isEmpty ? "this page" : host) to use your location?"
        )
        return allowed ? .grant : .deny
    }

    /// Notifications, from WebKit's private UI delegate method for `Notification.requestPermission()`:
    /// `sites.<host>.notifications` allow or deny answers without asking, otherwise the location prompt's (once per
    /// site per session, "Remember" writes `sites.<host>.notifications`). Private windows always get no. A yes asks
    /// macOS once whether Paddle may post notifications (`WebsiteNotifications`). WebKit calls this on the main thread.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webView(
        _ webView: WKWebView,
        requestNotificationPermissionForSecurityOrigin origin: WKSecurityOrigin,
        decisionHandler: @escaping (Bool) -> Void
    ) {
        Task { decisionHandler(await notificationDecision(for: origin)) }
    }

    private func notificationDecision(for origin: WKSecurityOrigin) async -> Bool {
        let isPrivate = tab?.isPrivate ?? true
        guard !isPrivate else { return false }
        let host = origin.host
        let allowed: Bool
        switch AppModel.shared.config.sitePolicy(forHost: host).notifications {
        case .allow: allowed = true
        case .deny: allowed = false
        case .ask:
            allowed = await askSitePermission(
                .notifications,
                field: .notifications,
                origin: origin,
                question: "\(host.isEmpty ? "This page" : host) wants to show notifications"
            )
        }
        if allowed { WebsiteNotifications.shared.requestSystemAuthorization() }
        return allowed
    }

    /// The Allow / Don't Allow prompt behind location and notifications. An answer already given for this origin and
    /// kind this run comes back without asking; else the prompt shows (a sheet, one at a time per window). "Remember
    /// for <host>", offered outside private windows, also writes `field` for the host as "allow" or "deny".
    private func askSitePermission(
        _ kind: SessionPermissions.Kind,
        field: SiteSettings.Field,
        origin: WKSecurityOrigin,
        question: String
    ) async -> Bool {
        let app = AppModel.shared
        let host = origin.host
        let site = Self.site(of: origin)
        let isPrivate = tab?.isPrivate ?? true
        let profile = tab?.profileID ?? ProfileStore.defaultID
        if let answer = app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: kind) { return answer }

        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Paddle won’t ask again for this site until it quits."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if !isPrivate, !host.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for \(host)"
            alert.suppressionButton?.state = .off
        }
        let response = await present(alert) { app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: kind) == nil }
        if response == .abort { return app[permissionsFor: isPrivate, profile: profile].answer(site: site, kind: kind) == true }
        let allowed = response == .alertFirstButtonReturn
        app[permissionsFor: isPrivate, profile: profile].record(allowed, site: site, kinds: [kind])
        if alert.showsSuppressionButton, alert.suppressionButton?.state == .on {
            let key = app.config.siteKey(forHost: host)
            Task { await app.writeSiteSetting(field, .string(allowed ? "allow" : "deny"), forKey: key) }
        }
        return allowed
    }
}

extension TabWebDelegate: NSMenuItemValidation {
    /// The page menu's New Tab Page item has the same limit as Bookmarks > Add Page to New Tab Page: a full New Tab
    /// page greys out Add (Remove stays).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleNewTabSite(_:)) else { return true }
        guard let url = tab?.url else { return false }
        let store = AppModel.shared.newTab
        return store.contains(url: HistoryStore.storedURL(url)) || store.sites.count < NewTabSites.maxSites
    }
}
