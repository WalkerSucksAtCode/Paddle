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
    /// The page is making sound (WebKit's private `_isPlayingAudio`; stays false where that is missing).
    var isPlayingAudio = false
    /// Muted by the user. Kept while the tab sleeps and applied again to the next web view.
    private(set) var isMuted = false
    /// Belongs to a private window: its web views use the private data store, and nothing it does is written to
    /// history, favicons or the session. Fixed for the tab's life (tabs never move between windows).
    let isPrivate: Bool
    /// A View Source tab: shows this HTML instead of loading `url` (about:blank). Not saved in the session.
    @ObservationIgnored private(set) var sourceHTML: String?
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
    @ObservationIgnored private var audioObserver: AudioPlaybackObserver?
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
    /// Which of Paddle's own pages (`loadHTMLString`, or `TabWebDelegate.loadErrorPage` for load errors) the next main-frame commit is; nil means the site's page.
    /// Set just before each such load and consumed by `pageCommitted()`.
    @ObservationIgnored var pendingOwnPage: OwnPage?
    enum OwnPage { case source, error }
    /// Showing one of Paddle's error pages (load failure, crash loop, extension unavailable), not the site's page:
    /// Print, Save Page As and View Source are off then.
    var isShowingErrorPage: Bool { committedErrorPage || showsExtensionUnavailable }
    @ObservationIgnored private var committedErrorPage = false
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

    init(url: URL?, title: String = "", isPinned: Bool = false, savedState: Any? = nil, isPrivate: Bool = false) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.savedState = savedState
        self.isPrivate = isPrivate
    }

    convenience init(record: TabRecord, isPrivate: Bool = false) {
        self.init(
            url: URL(string: record.url), title: record.title, isPinned: record.isPinned, savedState: record.interactionState,
            isPrivate: isPrivate
        )
    }

    /// A View Source tab showing `html` (built by `ViewSource.page`), titled until its page sets the title.
    convenience init(sourceHTML html: String, title: String, isPrivate: Bool) {
        self.init(url: URL(string: "about:blank"), title: title, isPrivate: isPrivate)
        sourceHTML = html
    }

    /// Whether this tab's web views may carry the extension controller: its window's setting, fixed when the
    /// window opened (private windows only with `extensionsInPrivate`).
    var extensionsAllowed: Bool { browser?.extensionsAllowed ?? !isPrivate }

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
            // A private window without extensions shows no extension page (it would run outside the private store).
            guard extensionsAllowed else { return showExtensionUnavailable(inPrivateWindow: true) }
            guard let pageConfiguration = host.pageConfiguration(for: url) else {
                if host.deferWake(self) { return nil }
                return showExtensionUnavailable()
            }
            configuration = pageConfiguration
        } else {
            configuration = makeWebConfiguration()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        attach(webView, extensionPageID: pageID)
        if let sourceHTML {
            skipNextCommitInHistory = true
            pendingOwnPage = .source
            webView.loadHTMLString(sourceHTML, baseURL: nil)
        } else if let savedState {
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
        sourceHTML = nil
        self.url = url
        wake()
    }

    /// An extension page whose extension isn't loaded (declined, off, failed, removed): a plain error page in an
    /// ordinary web view. Its "Try Again" button can't reach the extension page, by design; the tab keeps the
    /// page's URL and history, and the host swaps the page back in once the extension runs again.
    private func showExtensionUnavailable(inPrivateWindow: Bool = false) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebConfiguration())
        attach(webView, extensionPageID: nil)
        showsExtensionUnavailable = true
        let html = inPrivateWindow
            ? TabWebDelegate.errorPage(
                title: "Extensions are off in private windows",
                message: "Open this page in a normal window, or set \"extensionsInPrivate\": true in config.json and open a new private window.",
                url: url
            )
            : TabWebDelegate.errorPage(
                title: "Extension not loaded",
                message: "This page belongs to an extension that isn't running (turned off, declined, removed, or it failed to load).",
                url: url
            )
        skipNextCommitInHistory = true
        pendingOwnPage = .error
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    /// Adopts a web view, either one this tab made or one WebKit made for a popup. `extensionPageID`: the extension
    /// whose page configuration the web view was made with, nil for an ordinary web view.
    func attach(_ webView: WKWebView, extensionPageID: String?) {
        self.extensionPageID = extensionPageID
        // Remote inspection (Safari's Develop menu) follows `developerTools`, extension pages included.
        webView.isInspectable = AppModel.shared.config.developerTools
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
        audioObserver = AudioPlaybackObserver(webView) { [weak self] playing in self?.isPlayingAudio = playing }
        if isMuted { applyMute(to: webView) }
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
        committedErrorPage = false
        pendingOwnPage = nil
        resumeSelectionWaiters(false)
        observations.forEach { $0.invalidate() }
        observations = []
        audioObserver?.invalidate()
        audioObserver = nil
        isPlayingAudio = false
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
        sourceHTML = nil
        committedErrorPage = false
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

    /// A main-frame page committed (`TabWebDelegate.didCommit`). Anything but Paddle's own source or error page
    /// is a real page: a View Source tab that navigated away (a dropped link or file) stops being one, so it
    /// sleeps, wakes and is saved as that page.
    func pageCommitted() {
        let own = pendingOwnPage
        pendingOwnPage = nil
        committedErrorPage = own == .error
        if own == nil { sourceHTML = nil }
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
            pendingOwnPage = .error
            // Not `loadErrorPage`: after a crash there is no failed load to stand in for, and both of its loads append
            // a second item for the crashed page. Loading with `url` as base URL reuses the crashed page's item.
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

    /// Making sound or using camera/mic: never put to sleep (`MediaActivity`). Where WebKit's sound flag can't be
    /// observed, any media playing counts, which takes a round trip to the page.
    func isBusy() async -> Bool {
        guard let webView else { return false }
        let observable = audioObserver != nil
        if MediaActivity.isBusy(isCapturing: isCapturing, isPlayingAudio: isPlayingAudio, playbackIsPlaying: false, audioIsObservable: observable) { return true }
        guard !observable else { return false }
        let playing = await webView.requestMediaPlaybackState() == .playing
        return MediaActivity.isBusy(isCapturing: isCapturing, isPlayingAudio: isPlayingAudio, playbackIsPlaying: playing, audioIsObservable: false)
    }

    // MARK: - Mute

    private static let setPageMutedSelector = NSSelectorFromString("_setPageMuted:")
    private static let mediaMutedStateSelector = NSSelectorFromString("_mediaMutedState")

    /// WebKit's private `_setPageMuted:` exists. Without it Paddle has no way to mute, so Mute Tab is disabled.
    static let supportsMuting = WKWebView.instancesRespond(to: setPageMutedSelector)

    /// Tabs > Mute Tab and the tab strip's speaker. A sleeping tab is muted when it wakes.
    func setMuted(_ muted: Bool) {
        guard Self.supportsMuting, muted != isMuted else { return }
        isMuted = muted
        if let webView { applyMute(to: webView) }
    }

    /// Private WebKit API (`_setPageMuted:` with `_WKMediaMutedState`), guarded by `supportsMuting`. Only the audio
    /// bit changes, read from `_mediaMutedState` when that exists.
    private func applyMute(to webView: WKWebView) {
        guard webView.responds(to: Self.setPageMutedSelector) else { return }
        var current: UInt64 = 0
        if webView.responds(to: Self.mediaMutedStateSelector) {
            typealias Get = @convention(c) (AnyObject, Selector) -> UInt64
            let get = unsafeBitCast(webView.method(for: Self.mediaMutedStateSelector), to: Get.self)
            current = get(webView, Self.mediaMutedStateSelector)
        }
        typealias Set = @convention(c) (AnyObject, Selector, UInt64) -> Void
        let set = unsafeBitCast(webView.method(for: Self.setPageMutedSelector), to: Set.self)
        set(webView, Self.setPageMutedSelector, MediaMutedState.settingAudio(isMuted, in: current))
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

    /// The configuration for this tab's ordinary pages: the private data store in a private window,
    /// and the extension controller only where extensions are allowed.
    private func makeWebConfiguration() -> WKWebViewConfiguration {
        AppModel.shared.web.makeConfiguration(isPrivate: isPrivate, extensions: extensionsAllowed)
    }
}

/// KVO on WebKit's private `_isPlayingAudio`, which has no Swift key path. `init` returns nil when the property is
/// missing, so the tab simply shows no speaker. Call `invalidate()` before dropping the web view.
final class AudioPlaybackObserver: NSObject {
    private static let key = "_isPlayingAudio"
    private weak var webView: WKWebView?
    private let onChange: (Bool) -> Void

    init?(_ webView: WKWebView, onChange: @escaping (Bool) -> Void) {
        guard webView.responds(to: NSSelectorFromString(Self.key)) else { return nil }
        self.webView = webView
        self.onChange = onChange
        super.init()
        webView.addObserver(self, forKeyPath: Self.key, options: [.initial, .new], context: nil)
    }

    func invalidate() {
        webView?.removeObserver(self, forKeyPath: Self.key)
        webView = nil
    }

    /// WebKit changes this property on the main thread.
    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        let playing = (change?[.newKey] as? Bool) ?? false
        MainActor.assumeIsolated { onChange(playing) }
    }
}
