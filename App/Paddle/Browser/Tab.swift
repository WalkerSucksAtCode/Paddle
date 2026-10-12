import AppKit
import Foundation
import PaddleCore
import WebKit

/// One tab. Awake tabs own a `WKWebView` (and so a WebContent process); sleeping tabs keep only
/// their URL, title and WebKit's saved back/forward state, and cost almost nothing.
@Observable
final class Tab: Identifiable {
    let id = UUID()
    var title: String
    var url: URL?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var isSecure = false
    var isPinned: Bool
    var isAwake = false
    /// Using the camera or microphone. Such tabs never sleep.
    var isCapturing = false
    /// Physical footprint of this tab's WebContent process, refreshed every few seconds.
    var memoryBytes: UInt64?
    /// Another tab shares the same WebContent process, so `memoryBytes` is a shared total.
    var sharesProcess = false
    var lastActive = Date()
    /// Bumped whenever the web view is created or dropped, so the view layer re-attaches it.
    var generation = 0

    @ObservationIgnored private(set) var webView: WKWebView?
    /// Holds the web view, and the Web Inspector when it is docked (WebKit puts it beside the web view).
    /// Tab switches swap whole containers, so a docked inspector stays with its tab.
    @ObservationIgnored private(set) lazy var container: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()
    @ObservationIgnored private var savedState: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: TabWebDelegate?
    @ObservationIgnored weak var browser: BrowserModel?
    /// The tab this one was opened from (a popup, or a Cmd-clicked link).
    @ObservationIgnored weak var opener: Tab?
    /// A window the page opened and still holds through window.opener (a sign-in popup). It and its opener stay
    /// awake together, except under memory pressure, since sleeping either side breaks that reference.
    @ObservationIgnored var hasLiveOpener = false
    /// Closing this tab selects its opener again. Set for popups; cleared once the user moves to another tab.
    @ObservationIgnored var returnsToOpener = false
    /// Opened for one URL (a link, a popup, a URL from another app): if that load only downloads a file, the tab
    /// closes. Not set for tabs the user types into.
    @ObservationIgnored var closesIfOnlyDownload = false
    /// The page whose title may still update history: the one last recorded in this tab, not an error page,
    /// a restored page or one still loading.
    @ObservationIgnored var historyURL: URL?
    @ObservationIgnored var historyTitle = ""
    /// The next committed page was typed into the address bar (history ranks typed pages higher).
    @ObservationIgnored var typedNavigationPending = false
    /// The next commit is Paddle's own error or crash page, or a sleeping tab's page coming back; neither is a visit.
    @ObservationIgnored var skipNextCommitInHistory = false
    /// Recent web process crashes, with the host that was showing.
    @ObservationIgnored private var crashes: [(date: Date, host: String?)] = []
    @ObservationIgnored private var selectionWaiters: [CheckedContinuation<Bool, Never>] = []
    /// This tab as WebKit's extension API sees it. One object for the tab's whole life, so an extension's tab id
    /// survives sleep and wake.
    @ObservationIgnored lazy var extensionTab = ExtensionTab(tab: self)
    /// The extension whose page configuration the current web view was made with; nil for ordinary web views
    /// and while asleep. Extension pages and web pages need different web views, so a change swaps the view.
    @ObservationIgnored private(set) var extensionPageID: String?
    /// Showing the "Extension not loaded" page. The tab keeps its extension URL and saved history meanwhile, so it
    /// comes back (and is saved in the session) as that page, not as the error page's about:blank.
    @ObservationIgnored private(set) var showsExtensionUnavailable = false

    init(url: URL?, title: String = "", isPinned: Bool = false, savedState: Any? = nil) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.savedState = savedState
    }

    convenience init(record: TabRecord) {
        self.init(url: URL(string: record.url), title: record.title, isPinned: record.isPinned, savedState: record.interactionState)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return url == nil ? "New Tab" : (url?.absoluteString ?? "")
    }

    var record: TabRecord {
        let state = (showsExtensionUnavailable ? savedState : webView?.interactionState ?? savedState) as? Data
        return TabRecord(url: url?.absoluteString ?? "", title: title, isPinned: isPinned, interactionState: state)
    }

    // MARK: - Wake / sleep

    /// Creates the web view if the tab is asleep, restoring its page and history. An extension page needs that
    /// extension's own configuration; until its extension has loaded (startup, Reload Extensions) the wake is
    /// deferred and nil comes back. If the extension isn't loaded at all, an ordinary web view shows an error page.
    @discardableResult
    func wake() -> WKWebView? {
        if let webView { return webView }
        let host = AppModel.shared.extensions
        let configuration: WKWebViewConfiguration
        let pageID = ExtensionIdentity.identifier(of: url)
        if let url, pageID != nil {
            guard let pageConfiguration = host.pageConfiguration(for: url) else {
                if host.deferWake(self) { return nil }
                return showExtensionUnavailable()
            }
            configuration = pageConfiguration
        } else {
            configuration = AppModel.shared.web.makeConfiguration()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        attach(webView, extensionPageID: pageID)
        if let savedState {
            skipNextCommitInHistory = true
            webView.interactionState = savedState
        } else if let url {
            webView.load(URLRequest(url: url))
        }
        savedState = nil
        return webView
    }

    /// Drops the current web view and loads `url` in a fresh one, chosen for `url` (extension page or web page).
    /// Back/forward history across the swap is lost.
    func replaceWebView(loading url: URL) {
        sleep()
        savedState = nil
        self.url = url
        wake()
    }

    /// An extension page whose extension isn't loaded (declined, off, failed, removed): a plain error page in an
    /// ordinary web view. Its "Try Again" button can't reach the extension page, by design; the tab keeps the
    /// page's URL and history, and the host swaps the page back in once the extension runs again.
    private func showExtensionUnavailable() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: AppModel.shared.web.makeConfiguration())
        attach(webView, extensionPageID: nil)
        showsExtensionUnavailable = true
        let html = TabWebDelegate.errorPage(
            title: "Extension not loaded",
            message: "This page belongs to an extension that isn't running (turned off, declined, removed, or it failed to load).",
            url: url
        )
        skipNextCommitInHistory = true
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    /// Adopts a web view, either one this tab made or one WebKit made for a popup. `extensionPageID`: the extension
    /// whose page configuration the web view was made with, nil for an ordinary web view.
    func attach(_ webView: WKWebView, extensionPageID: String?) {
        self.extensionPageID = extensionPageID
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let delegate = TabWebDelegate(tab: self)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        self.delegate = delegate
        self.webView = webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        observe(webView)
        isAwake = true
        generation += 1
        // No tab-change notice here or in `sleep()`: WebKit asks `webView(for:)` when it needs the view, and a
        // `.loading` notice would report the status "complete" for a page that hasn't loaded. The load that follows
        // reports itself through the `isLoading` observer.
    }

    /// Drops the web view. WebKit exits the WebContent process once no web view uses it.
    func sleep() {
        guard let webView else { return }
        // Before the first page commits there is no history worth keeping; waking then loads the URL again. The
        // "Extension not loaded" page keeps the history it was standing in for.
        if !showsExtensionUnavailable {
            savedState = webView.backForwardList.currentItem == nil ? nil : webView.interactionState
        }
        showsExtensionUnavailable = false
        resumeSelectionWaiters(false)
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate = nil
        isAwake = false
        isLoading = false
        progress = 0
        isCapturing = false
        memoryBytes = nil
        sharesProcess = false
        extensionPageID = nil
        generation += 1
    }

    /// Address bar, session restore and extension `tabs.update`. Crossing between an extension page and a web
    /// page (either way) swaps the web view, since each needs its own configuration.
    func load(_ url: URL) {
        self.url = url
        showsExtensionUnavailable = false
        if let webView {
            if ExtensionIdentity.identifier(of: url) != extensionPageID {
                replaceWebView(loading: url)
            } else {
                webView.load(URLRequest(url: url))
            }
        } else {
            savedState = nil
        }
    }

    /// The web process crashed or was killed. A background tab just goes to sleep. The visible tab reloads,
    /// unless it crashed already in the last minute: then it shows an error page instead of reloading forever.
    func processTerminated() {
        guard browser?.selectedTab === self, let webView else {
            sleep()
            return
        }
        // Only crashes of the site now showing count, so one crash after another site's doesn't stop reloads.
        let now = Date()
        let host = url?.host()
        crashes = crashes.filter { now.timeIntervalSince($0.date) < 60 && $0.host == host } + [(now, host)]
        if crashes.count < 2 {
            // Before the first page commits there is nothing to reload, so load the URL again.
            if webView.url != nil {
                webView.reload()
            } else if let url {
                webView.load(URLRequest(url: url))
            }
        } else {
            let html = TabWebDelegate.errorPage(
                title: "This page keeps crashing",
                message: "Its web process stopped \(crashes.count) times in the last minute, so Paddle stopped reloading it.",
                url: url
            )
            skipNextCommitInHistory = true
            webView.loadHTMLString(html, baseURL: url)
        }
    }

    // MARK: - Dialogs

    var window: NSWindow? { browser?.controller?.window }

    /// Shows a dialog for this tab as a sheet, only while the tab is showing and one at a time per window: AppKit
    /// would otherwise queue it behind another tab's sheet and show it over whatever page is current by then.
    /// Returns `.abort` without showing it if the tab closes or sleeps first, or `isStillNeeded` turns false
    /// (another tab got the same question answered meanwhile).
    func present(_ alert: NSAlert, isStillNeeded: () -> Bool = { true }) async -> NSApplication.ModalResponse {
        while true {
            guard await waitUntilSelected() else { return .abort }
            guard isStillNeeded() else { return .abort }
            guard let window else { return alert.runModal() }
            guard window.attachedSheet != nil else { return await alert.beginSheetModal(for: window) }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didEndSheetNotification, object: window) { break }
        }
    }

    /// True once the tab is selected; false if it closes or sleeps first.
    func waitUntilSelected() async -> Bool {
        if browser?.selectedID == id { return true }
        return await withCheckedContinuation { selectionWaiters.append($0) }
    }

    func resumeSelectionWaiters(_ selected: Bool) {
        let waiters = selectionWaiters
        selectionWaiters = []
        waiters.forEach { $0.resume(returning: selected) }
    }

    /// Playing audio/video or using camera/mic: never put to sleep.
    func isBusy() async -> Bool {
        guard let webView else { return false }
        if isCapturing { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    // MARK: - KVO

    /// WebKit posts these KVO changes on the main thread; the SDK marks the closures Sendable, hence assumeIsolated.
    private func observe(_ webView: WKWebView) {
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ update: @escaping @MainActor (Tab, WKWebView) -> Void) -> NSKeyValueObservation {
            webView.observe(keyPath) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self, webView)
                }
            }
        }
        observations = [
            watch(\.title) { tab, webView in
                tab.title = webView.title ?? ""
                AppModel.shared.extensions.tabChanged(tab, .title)
                // One write per real title change of the recorded page.
                guard let url = tab.historyURL, webView.url == url, !tab.title.isEmpty, tab.title != tab.historyTitle else { return }
                tab.historyTitle = tab.title
                AppModel.shared.updateHistoryTitle(url, tab.title)
            },
            watch(\.url) { tab, webView in
                // The error page's about:blank must not replace the extension URL it stands in for.
                guard let url = webView.url, !tab.showsExtensionUnavailable else { return }
                tab.url = url
                tab.browser?.tabURLChanged(tab)
            },
            watch(\.isLoading) { tab, webView in
                tab.isLoading = webView.isLoading
                AppModel.shared.extensions.tabChanged(tab, .loading)
            },
            watch(\.estimatedProgress) { tab, webView in tab.progress = webView.estimatedProgress },
            watch(\.canGoBack) { tab, webView in tab.canGoBack = webView.canGoBack },
            watch(\.canGoForward) { tab, webView in tab.canGoForward = webView.canGoForward },
            watch(\.hasOnlySecureContent) { tab, webView in tab.isSecure = webView.hasOnlySecureContent },
            watch(\.cameraCaptureState) { tab, webView in tab.updateCapturing(webView) },
            watch(\.microphoneCaptureState) { tab, webView in tab.updateCapturing(webView) },
        ]
    }

    private func updateCapturing(_ webView: WKWebView) {
        isCapturing = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
    }
}
