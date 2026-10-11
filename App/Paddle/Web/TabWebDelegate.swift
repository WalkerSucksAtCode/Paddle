import AppKit
import Foundation
import WebKit

/// WebKit callbacks for one tab: link routing, popups, downloads, dialogs, uploads, permissions, errors.
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?

    init(tab: Tab) {
        self.tab = tab
    }

    private static let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript"]

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
        if isMainFrame { mainFrameNavigationType = navigationAction.navigationType }

        // mailto:, zoommtg:, slack: ... hand off to the right app. A real click opens it; a script or redirect
        // (a "Launch meeting" page) asks first, so pages can't launch apps unprompted.
        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            let clicked = byUser && navigationAction.navigationType == .linkActivated
            let requester = Self.requester(navigationAction) ?? webView.url?.host()
            Task { await openExternally(url, ask: !clicked, requester: requester) }
            return (.cancel, preferences)
        }

        // Cmd-click or middle-click: background tab (Cmd-Shift-click: foreground). Only for real clicks; a page
        // faking one just navigates, so it can't open tabs past the popup blocker.
        if navigationAction.navigationType == .linkActivated, byUser, let tab, let browser = tab.browser {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == 4 {
                browser.newTab(url: url, select: flags.contains(.shift), after: tab)
                return (.cancel, preferences)
            }
        }

        if isMainFrame, let host = url.host() {
            return (applySiteUserAgent(for: host, navigationAction, preferences, in: webView) ? .allow : .cancel, preferences)
        }
        return (.allow, preferences)
    }

    private static let setCustomUserAgent = NSSelectorFromString("_setCustomUserAgent:")

    /// Per-site user agent from config.json. Returns false when the load was cancelled to restart it.
    private func applySiteUserAgent(
        for host: String, _ navigationAction: WKNavigationAction, _ preferences: WKWebpagePreferences, in webView: WKWebView
    ) -> Bool {
        let wanted = AppModel.shared.config.userAgent(forHost: host)
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
        let key = "download \(site)"
        if AppModel.shared.grantedPermissions.contains(key) { return true }
        if AppModel.shared.refusedPermissions.contains(key) { return false }
        let alert = NSAlert()
        alert.messageText = "Allow downloads from \(site)?"
        alert.informativeText = "A frame from \(site) on this page wants to download “\(filename)”."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let app = AppModel.shared
        let response = await present(alert) { !app.grantedPermissions.contains(key) && !app.refusedPermissions.contains(key) }
        if response == .abort { return app.grantedPermissions.contains(key) }
        let allow = response == .alertFirstButtonReturn
        if allow {
            app.grantedPermissions.insert(key)
        } else {
            app.refusedPermissions.insert(key)
        }
        return allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        AppModel.shared.downloads.track(download)
        tabShowsNothingAfterDownload(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        AppModel.shared.downloads.track(download)
        tabShowsNothingAfterDownload(webView)
    }

    /// The tab's only load became a download, so it has no page. A tab opened just for that load (a target=_blank
    /// file link, a file URL from another app) closes, as in Chrome, and stays out of Reopen Closed Tab, which
    /// would download the file again. A tab the user typed the URL into goes back to the start page.
    private func tabShowsNothingAfterDownload(_ webView: WKWebView) {
        tab?.typedNavigationPending = false
        guard let tab, webView.backForwardList.currentItem == nil, let browser = tab.browser else { return }
        DispatchQueue.main.async {
            if tab.closesIfOnlyDownload, browser.tabs.count > 1 {
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

    // MARK: - History

    /// How the pending main-frame navigation started; reloads, back/forward and session restores aren't new visits.
    private var mainFrameNavigationType: WKNavigationType?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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

    private func recordInHistory(_ url: URL, _ webView: WKWebView, typed: Bool) {
        guard let tab else { return }
        let title = webView.title ?? ""
        AppModel.shared.recordVisit(url, title: title, typed: typed)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await AppModel.shared.favicons.refresh(for: webView) }
    }

    // MARK: - Failures

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        tab?.typedNavigationPending = false
        showErrorPage(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // Failures after the page started rendering leave the partial page; WebKit shows nothing extra.
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.processTerminated()
    }

    private func showErrorPage(_ webView: WKWebView, _ error: any Error) {
        let nsError = error as NSError
        // Cancelled loads, and loads that turned into downloads, are not errors.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return }

        let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab?.url
        let html = Self.errorPage(title: "Can't open this page", message: nsError.localizedDescription, url: failing)
        tab?.skipNextCommitInHistory = true
        webView.loadHTMLString(html, baseURL: failing)
    }

    /// A plain page with a Try Again button that reloads `url`. Loaded with `url` as its base URL,
    /// so the address bar keeps showing the page that failed.
    static func errorPage(title: String, message: String, url: URL?) -> String {
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
          button { font: inherit; padding: .35rem 1rem; }
        </style>
        <h1>\(escape(title))</h1>
        <p>\(escape(message))</p>
        <p>\(escape(urlText))</p>
        <button data-url="\(escape(urlText))" onclick="location.href = this.dataset.url">Try Again</button>
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
        let popup = WKWebView(frame: .zero, configuration: configuration)
        // window.open() with no URL has no request URL; about:blank keeps the tab showing its web view
        // (which the opener may write into) instead of the start page.
        let newTab = Tab(url: navigationAction.request.url ?? URL(string: "about:blank"))
        newTab.opener = tab
        newTab.returnsToOpener = true
        newTab.closesIfOnlyDownload = true
        // Private WebKit API: whether the page keeps a window.opener reference (plain target=_blank links are
        // noopener). Without it, treat script-opened windows as having one.
        if navigationAction.responds(to: NSSelectorFromString(Self.hasOpenerKey)) {
            newTab.hasLiveOpener = (navigationAction.value(forKey: Self.hasOpenerKey) as? Bool) ?? false
        } else {
            newTab.hasLiveOpener = navigationAction.navigationType == .other
        }
        newTab.attach(popup)
        browser.insert(newTab, after: tab, select: true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let browser = tab.browser else { return }
        // A popup that never showed a page (it only started a download) stays out of Reopen Closed Tab.
        // A page closing its own window (a finished sign-in) always hands focus back to the opener.
        browser.close(tab, remember: webView.backForwardList.currentItem != nil, returnToOpener: true)
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
        let devices: [String]
        switch type {
        case .camera: devices = ["camera"]
        case .microphone: devices = ["microphone"]
        default: devices = ["camera", "microphone"]
        }
        // Granted per device, so allowing camera and microphone also covers a later microphone-only request.
        let site = "\(origin.protocol)://\(origin.host):\(origin.port)"
        let keys = devices.map { "\(site) \($0)" }
        if keys.allSatisfy(AppModel.shared.grantedPermissions.contains) { return .grant }

        let alert = NSAlert()
        alert.messageText = "Allow \(origin.host) to use your \(devices.joined(separator: " and "))?"
        alert.informativeText = "If you allow, Paddle won’t ask again for this site until it quits."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let app = AppModel.shared
        let response = await present(alert) { !keys.allSatisfy(app.grantedPermissions.contains) }
        if response == .abort { return keys.allSatisfy(app.grantedPermissions.contains) ? .grant : .deny }
        let allowed = response == .alertFirstButtonReturn
        if allowed { app.grantedPermissions.formUnion(keys) }
        return allowed ? .grant : .deny
    }
}
