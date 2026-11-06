import AppKit
import Foundation
import os
import PaddleCore
import WebKit

/// One tab. Awake tabs own a `WKWebView` (and so a WebContent process); sleeping tabs keep only
/// their URL, title and WebKit's saved back/forward state, and cost almost nothing.
@Observable
final class Tab: Identifiable {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "tab")

    let id = UUID()
    var title: String
    /// The title the user gave the tab (Rename Tab…); shown instead of the page's title while set.
    var customTitle: String?
    /// The `TabGroup` this tab is in, in its window's `BrowserModel.groups`.
    var groupID: UUID?
    var url: URL?
    /// The link under the pointer, shown in the status bubble. Nil when none.
    var hoveredLink: URL?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var isSecure = false
    /// Set when HTTPS-only mode refused to load this http:// address: the tab shows Paddle's notice for it instead of
    /// the page. Cleared by the next navigation.
    var httpsOnlyBlocked: URL?
    /// Pages this tab's page opened in a window without a click, refused by `PopupProbe`. The toolbar's Pop-up blocked
    /// button opens them. Cleared when the next page commits.
    var blockedPopups: [URL] = []
    /// The http:// address of the pending upgraded load, for failure detection; cleared when a page commits.
    @ObservationIgnored var httpsUpgrade: (original: URL, at: Date)?
    /// The host last upgraded in this tab and when, for loop detection. Not cleared by a commit: an https:// page
    /// that sends the tab back to http:// from a script or meta refresh commits first.
    @ObservationIgnored var lastHTTPSUpgrade: (host: String, at: Date)?
    var isPinned: Bool
    var isAwake = false
    /// Frozen: WebKit has suspended the page (`freeze()`), so it keeps its memory but runs nothing, and `unfreeze()`
    /// shows it again with no reload. Still awake; a sleep drops the frozen page as it does any other.
    private(set) var isFrozen = false
    /// A suspend was asked for and not undone: its answer may still be on the way, and `unfreeze()` must resume the
    /// page even before the answer lands.
    @ObservationIgnored private var suspendRequested = false
    /// WebKit holds the page suspended: frozen, or a freeze asked for (WebKit suspends at the `_suspendPage:` call, not
    /// at its answer, and resumes at the `_resumePage:` call; measured 2026-10-17). Meanwhile WebKit raises
    /// NSInternalInconsistencyException ("The WKWebView is suspended"), which Swift can't catch, from loads, reload,
    /// stopLoading, scripts, snapshots, the `pageZoom` setter, media calls and `_doAfterNextPresentationUpdate:`. Every
    /// call that can reach a background tab checks this, or calls `unfreeze()` first.
    var isSuspendedInWebKit: Bool { isFrozen || suspendRequested }

    /// Runs `body` unless the page is suspended.
    func whenLive(_ body: () -> Void) {
        if !isSuspendedInWebKit { body() }
    }

    /// The tab whose web view this is, if any.
    static func owning(_ webView: WKWebView) -> Tab? {
        AppModel.shared.allTabs.first { $0.webView === webView }
    }
    /// Using the camera or microphone. Such tabs never sleep.
    var isCapturing = false
    /// The page is making sound (WebKit's private `_isPlayingAudio`; stays false where that is missing).
    var isPlayingAudio = false
    /// A video on this page is in the system Picture-in-Picture window (`PictureInPictureScript`).
    var isInPictureInPicture = false
    /// Muted by the user. Kept while the tab sleeps and applied again to the next web view.
    private(set) var isMuted = false
    /// Belongs to a private window: its web views use the private data store, and nothing it does is written to
    /// history, favicons or the session. Fixed for the tab's life (tabs only move between windows of the same kind).
    let isPrivate: Bool
    /// A View Source tab: shows this HTML instead of loading `url` (about:blank). Not saved in the session.
    @ObservationIgnored private(set) var sourceHTML: String?
    /// Physical footprint of this tab's WebContent process, refreshed every few seconds.
    var memoryBytes: UInt64?
    /// Another tab shares the same WebContent process, so `memoryBytes` is a shared total.
    var sharesProcess = false
    var lastActive = Date()
    /// Names this tab's state file in sessions/ (`SessionStore`): the id it was saved under, kept across launches
    /// so an unchanged state isn't written again; nil until restored, then `id` stands in.
    @ObservationIgnored private var sessionID: String?
    /// Bumped whenever the web view is created or dropped, so the view layer re-attaches it.
    var generation = 0
    /// Responsive Design Mode: the page drawn at a device's size. Nil when off. Not saved in the session.
    var responsive: ResponsiveState?
    /// The window's link preview (`BrowserModel.preview`), not a tab yet: in no tab list, so the strip, session, sleep
    /// policy, memory sampling and the bridge's tab lists never see it; extensions do, as the window's last tab
    /// (`BrowserModel.extensionTabs`). Cleared when it becomes a tab (`BrowserModel.openPreviewAsTab`).
    var isPreview = false

    @ObservationIgnored private(set) var webView: WKWebView?
    /// Holds the web view, and the Web Inspector when it is docked (WebKit puts it beside the web view).
    /// Tab switches swap whole containers, so a docked inspector stays with its tab.
    @ObservationIgnored private(set) lazy var container: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()
    /// Opaque stand-in over a web view that has not painted yet. A restored page is a blank white document for
    /// a beat; in the dark appearance that white is the whole window.
    @ObservationIgnored private var wakeCover: NSView?
    /// The native "Fill contact info" chip over the web view (`ContactChipView`), outside the page.
    @ObservationIgnored var contactChip: ContactChipView?
    @ObservationIgnored private var wakeCoverGeneration = 0
    @ObservationIgnored private var wakeCoverStarted: Date?
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
    /// Showing one of Paddle's error pages (load failure, crash, extension unavailable), not the site's page:
    /// Print, Save Page As and View Source are off then.
    var isShowingErrorPage: Bool { committedErrorPage || showsExtensionUnavailable || isProcessTerminated }
    /// Distraction-free article content when Reader Mode is active on this tab.
    var readerArticle: ReaderArticle?
    var isReaderAvailable = false
    var isPDF = false
    var showTranslatePopover = false
    var showQRCodePopover = false
    @ObservationIgnored private var committedErrorPage = false
    @ObservationIgnored private var isProcessTerminated = false
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
    /// The web view exists but its first page waits for the block lists (`WebEnvironment.blockersReady`); the page
    /// to load is still in `savedState` / `url`.
    @ObservationIgnored private var awaitingBlockers = false
    /// The current page committed before every block list was installed (startup, after the gate's timeout).
    /// It reloads once when they are (`reloadIfLoadedUnblocked`).
    @ObservationIgnored private(set) var loadedUnblocked = false
    /// The current main-frame page came from a form post. Set by `TabWebDelegate` just before `pageCommitted()`.
    @ObservationIgnored var committedPost = false
    /// Main-frame commits so far, so an answer that took a round trip can tell whether the page changed meanwhile.
    @ObservationIgnored private var commitCount = 0
    /// Navigation type for the commit `pageCommitted()` is handling; set by `TabWebDelegate` just before that call.
    @ObservationIgnored var committingNavigationType: WKNavigationType?
    /// Cancels a deferred site-settings apply when the tab navigates again before it runs.
    @ObservationIgnored private var deferredSiteSettingsTask: Task<Void, Never>?

    init(url: URL?, title: String = "", isPinned: Bool = false, savedState: Any? = nil, isPrivate: Bool = false) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.savedState = savedState
        self.isPrivate = isPrivate
    }

    /// URLs saved in the session may load when the tab wakes; everything else becomes a New Tab (nil `url`).
    private static func sessionRestorableURL(_ url: URL) -> URL? {
        if OpenableURL.isAllowed(url) { return url }
        if url.scheme?.lowercased() == "paddle", url.host()?.lowercased() == "settings" { return url }
        if ExtensionIdentity.identifier(of: url) != nil { return url }
        // OpenableURL blocks external file: PDF opens; a tab the user opened in Paddle may still persist one.
        if url.isFileURL, !url.hasDirectoryPath, url.pathExtension.lowercased() == "pdf" {
            if let host = url.host(percentEncoded: false), !host.isEmpty, host.lowercased() != "localhost" { return nil }
            return url
        }
        return nil
    }

    convenience init(record: TabRecord, isPrivate: Bool = false) {
        let url = URL(string: record.url).flatMap { Self.sessionRestorableURL($0) }
        // Rejected URLs may still carry interactionState with back/forward entries the gate refused; drop url and state together or neither — restoring interactionState unconditionally would reopen that hole.
        let savedState = url != nil ? record.interactionState : nil
        self.init(
            url: url, title: record.title, isPinned: record.isPinned, savedState: savedState,
            isPrivate: isPrivate
        )
        sessionID = record.id
        customTitle = record.customTitle
        groupID = record.groupID.flatMap(UUID.init(uuidString:))
        if let date = record.lastActive { lastActive = date }
    }

    /// A View Source tab showing `html` (built by `ViewSource.page`), titled until its page sets the title.
    convenience init(sourceHTML html: String, title: String, isPrivate: Bool) {
        self.init(url: URL(string: "about:blank"), title: title, isPrivate: isPrivate)
        sourceHTML = html
    }

    /// Whether this tab's web views may carry the extension controller: its window's setting, fixed when the
    /// window opened (private windows only when any extension may run in private windows, `anyExtensionInPrivate`).
    var extensionsAllowed: Bool { browser?.extensionsAllowed ?? !isPrivate }
    /// The profile of the window this tab is in (the default profile for a tab not in a window yet).
    var profileID: String { browser?.profileID ?? ProfileStore.defaultID }
    /// The config this tab's profile runs with (`AppModel.config(for:)`).
    var config: PaddleConfig { AppModel.shared.config(for: profileID) }

    /// The Settings pane this tab shows (`paddle://settings/<pane>`; bare `paddle://settings` is General). Nil for
    /// every other tab. A settings tab has no web view: it never wakes or sleeps, and SwiftUI draws it (`SettingsTabView`).
    var settingsPane: SettingsPane? {
        guard url?.scheme?.lowercased() == "paddle", url?.host()?.lowercased() == "settings", let url else { return nil }
        return SettingsLink.parse(url.absoluteString)?.pane.flatMap { SettingsPane(rawValue: $0.rawValue) } ?? .general
    }

    /// A page tab with no web view. A settings tab has none and is not asleep.
    var isAsleep: Bool { !isAwake && settingsPane == nil }

    /// This tab's page is drawn by its own web view in the content area. Settings, the new-tab page, reader and the
    /// HTTPS notice draw something else over that area.
    var hostsWebView: Bool {
        url != nil && settingsPane == nil && httpsOnlyBlocked == nil && readerArticle == nil && responsive == nil
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if settingsPane != nil { return "Settings" }
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return url == nil ? "New Tab" : (url?.absoluteString ?? "")
    }

    /// The id session.json names this tab by: kept across launches for a restored tab (`TabRecord.id`).
    var sessionKey: String { sessionID ?? id.uuidString }

    var record: TabRecord {
        let state = (showsExtensionUnavailable || awaitingBlockers ? savedState : webView?.interactionState ?? savedState) as? Data
        return TabRecord(
            url: url?.absoluteString ?? "", title: title, isPinned: isPinned, interactionState: state,
            id: sessionID ?? id.uuidString, lastActive: lastActive, customTitle: customTitle, groupID: groupID?.uuidString
        )
    }

    // MARK: - Wake / sleep

    /// Creates the web view if the tab is asleep, restoring page and history. An extension page needs that
    /// extension's configuration; until it has loaded (startup, Reload Extensions) the wake is deferred and
    /// returns nil. If the extension isn't loaded at all, an ordinary web view shows an error page. An
    /// ordinary web view's first page waits for the block lists (`WebEnvironment.blockersReady`, at most
    /// 3 s after startup); the web view itself comes back at once.
    @discardableResult
    func wake() -> WKWebView? {
        // Every path that wants the page live (selecting it, navigating it, extension calls) comes through here.
        if let webView {
            unfreeze()
            return webView
        }
        // Settings is drawn by SwiftUI and loads nothing, so it never gets a web view.
        if settingsPane != nil { return nil }
        // This tab's profile's extensions only (private windows: the default profile's).
        let host = AppModel.shared.extensions(for: profileID)
        let configuration: WKWebViewConfiguration
        // A saved page of an extension whose persona changed (webkit-extension:// to moz-extension://) moves to its
        // new address; its old back/forward list points at the old one, so it starts fresh.
        if let current = url, let moved = host?.currentURL(forStale: current) {
            url = moved
            savedState = nil
        }
        let pageID = ExtensionIdentity.identifier(of: url)
        if let url, pageID != nil {
            // A private window without extensions shows no extension page (it would run outside the private store), and
            // neither does a private window for an extension that isn't allowed in private windows (`allowsPrivatePage`).
            guard let host else { return showExtensionUnavailable() }
            guard extensionsAllowed, !isPrivate || host.allowsPrivatePage(url) else { return showExtensionUnavailable(inPrivateWindow: true) }
            guard let pageConfiguration = host.pageConfiguration(for: url) else {
                if host.deferWake(self) { return nil }
                return showExtensionUnavailable()
            }
            configuration = pageConfiguration
        } else {
            // An unloaded on-demand extension for this site (`extensionsOnDemand`) loads first, so the page's web
            // view is made after it and the extension can reach it.
            if extensionsAllowed, let url, let host, host.loadOnDemand(for: url), host.deferWake(self) { return nil }
            configuration = makeWebConfiguration()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        attach(webView, extensionPageID: pageID)
        if let sourceHTML {
            skipNextCommitInHistory = true
            pendingOwnPage = .source
            webView.loadHTMLString(sourceHTML, baseURL: nil)
        } else if pageID == nil, !AppModel.shared.web.blockersReady.isOpen {
            waitForBlockers(webView)
            return webView
        } else {
            startFirstLoad(webView)
        }
        savedState = nil
        return webView
    }

    /// Restores the saved page and history, or loads `url`. Session restore filters URLs in `Tab(record:)`, not here.
    private func startFirstLoad(_ webView: WKWebView) {
        if let savedState {
            skipNextCommitInHistory = true
            webView.interactionState = savedState
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Starts the first load once the block lists are in, unless the tab slept or got another web view meanwhile.
    /// `savedState` stays set until then, so the session and a sleep keep the restored history.
    private func waitForBlockers(_ webView: WKWebView) {
        awaitingBlockers = true
        let gate = AppModel.shared.web.blockersReady
        let started = ContinuousClock.now
        Task { [weak self] in
            // Cold compile (EasyList + EasyPrivacy, 2026-10-12): ~3.7 s, so the 3 s gate cap ends this wait
            // and the page loads unblocked, then reloads once (`AppModel.start`). Warm cache: 58 ms before
            // scriptlets, ~310 ms with them on (same date). Logs: this "first page load waited" line,
            // "startup block lists installed in" (WebEnvironment), and "compiled" (none on a warm start).
            await gate.wait()
            let waited = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            Self.log.notice("first page load waited \(waited, privacy: .public) for the block lists (\(gate.isReady ? "installed" : "timed out", privacy: .public))")
            guard let self, self.webView === webView, awaitingBlockers else { return }
            awaitingBlockers = false
            startFirstLoad(webView)
            savedState = nil
        }
    }

    /// The block lists are installed: a page that committed before then reloads once, unless it came from a form
    /// post, is playing media or using the camera or microphone, or the user typed into it (`UnblockedReload`).
    func reloadIfLoadedUnblocked() async {
        guard loadedUnblocked, let webView else { return }
        loadedUnblocked = false
        unfreeze()
        let page = commitCount
        let post = committedPost
        let busy = await isBusy()
        let typed = (try? await webView.evaluateJavaScript(UnblockedReload.typedProbeScript, in: nil, contentWorld: .defaultClient) as? Bool) ?? true
        // The page may have changed while those answers came back; a newer page committed with the block lists.
        guard self.webView === webView, commitCount == page else { return }
        let decision = UnblockedReload.decide(loadedUnblocked: true, isPost: post, isBusy: busy, userTyped: typed)
        Self.log.info("unblocked startup page: \(String(describing: decision), privacy: .public)")
        if decision == .reload { webView.reload() }
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

    /// A new web view that keeps the tab's history, then `url` in it: an extension loaded on demand reaches only web
    /// views made after it loaded (`ExtensionHost.loadOnDemand`).
    func renewWebView(goingTo url: URL) {
        sleep()
        wake()
        load(url)
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
                title: "This extension is off in private windows",
                message: "Open this page in a normal window, or allow the extension in private windows in Settings > Extensions and open a new private window.",
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
    /// `swipeNavigation` and `pinchZoom` on this tab's web view (or `webView`, one being attached).
    func applyGestures(to view: WKWebView? = nil) {
        guard let view = view ?? webView else { return }
        view.allowsBackForwardNavigationGestures = config.swipeNavigation
        view.allowsMagnification = config.pinchZoom
    }

    /// whose page configuration the web view was made with, nil for an ordinary web view.
    func attach(_ webView: WKWebView, extensionPageID: String?) {
        self.extensionPageID = extensionPageID
        // An extension page sends its extension's persona user agent; a web view for web pages is a fresh one
        // (leaving the extension's origin swaps views), so the agent never follows a tab out of it.
        if let extensionPageID, let agent = AppModel.shared.existingExtensions(for: profileID)?.userAgent(forPageHost: extensionPageID) {
            webView.customUserAgent = agent
        }
        // Remote inspection (Safari's Develop menu) follows `developerTools`, extension pages included.
        webView.isInspectable = AppModel.shared.config.developerTools
        applyGestures(to: webView)
        let delegate = TabWebDelegate(tab: self)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        self.delegate = delegate
        self.webView = webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        applyPageBackdrop(to: webView)
        container.addSubview(webView)
        showWakeCover(over: webView)
        observe(webView)
        audioObserver = AudioPlaybackObserver(webView) { [weak self] playing in
            guard let self, playing != isPlayingAudio else { return }
            isPlayingAudio = playing
            AppModel.shared.existingExtensions(for: profileID)?.tabChanged(self, .playingAudio)
        }
        if isMuted { applyMute(to: webView) }
        isAwake = true
        generation += 1
        // No tab-change notice here or in `sleep()`: WebKit asks `webView(for:)` when it needs the view, and a
        // `.loading` notice would report the status "complete" for a page that hasn't loaded. The load that follows
        // reports itself through the `isLoading` observer.
    }

    /// The color behind a page that has not painted: the theme's new-tab background, or the default chrome.
    /// Follows the appearance, so a dark window stays dark and a light one stays light.
    func refreshPageBackdrop() {
        let color = pageBackdropColor()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.cgColor
        if let webView { webView.underPageBackgroundColor = color }
        wakeCover?.layer?.backgroundColor = color.cgColor
    }

    private func applyPageBackdrop(to webView: WKWebView) {
        let color = pageBackdropColor()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.cgColor
        webView.underPageBackgroundColor = color
    }

    private func pageBackdropColor() -> NSColor {
        let isDark = AppModel.shared.effectiveAppearanceIsDark
        let host = siteHost ?? ""
        let siteDark = !host.isEmpty && resolvedPageDarkEngine(systemIsDark: isDark) != .off
        if siteDark {
            return NSColor(srgbRed: 0.094, green: 0.102, blue: 0.106, alpha: 1)
        }
        let dark = isDark
        let rgb = AppModel.shared.activeTheme(in: config)?.palette(dark: dark)?.newTabBackground ?? DefaultChromeColors.base(dark: dark)
        return NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    /// Covers `webView` until its page is more than a flat field. A new web view paints a blank white document
    /// before the restored page, and that white is what shows for the whole gap.
    private func showWakeCover(over webView: WKWebView) {
        endWakeCover()
        let cover = NSView(frame: webView.frame)
        cover.wantsLayer = true
        cover.layer?.isOpaque = true
        cover.layer?.backgroundColor = pageBackdropColor().cgColor
        cover.autoresizingMask = [.width, .height]
        container.addSubview(cover, positioned: .above, relativeTo: webView)
        wakeCover = cover
        wakeCoverStarted = Date()
        watchWakeCover(generation: wakeCoverGeneration)
    }

    private func endWakeCover() {
        wakeCoverGeneration += 1
        wakeCover?.removeFromSuperview()
        wakeCover = nil
        wakeCoverStarted = nil
    }

    /// How long the cover may hide a page that never paints anything but a flat color.
    private static let wakeCoverLimit: TimeInterval = 3

    private func watchWakeCover(generation: Int) {
        Task { @MainActor [weak self] in
            while let self, self.wakeCoverGeneration == generation, self.wakeCover != nil {
                if let started = self.wakeCoverStarted, Date().timeIntervalSince(started) > Self.wakeCoverLimit {
                    self.endWakeCover()
                    return
                }
                guard let webView = self.webView, webView.window != nil, webView.bounds.width > 2 else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                // The container is often given its size after the web view is created. Keep the cover on it.
                if self.wakeCover?.frame != webView.frame { self.wakeCover?.frame = webView.frame }
                // A background wake can be frozen by the sweep while the cover waits; snapshots raise then.
                if self.isSuspendedInWebKit {
                    self.endWakeCover()
                    return
                }
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = 48
                let image = try? await webView.takeSnapshot(configuration: config)
                guard self.wakeCoverGeneration == generation else { return }
                if let image, Self.pageHasContent(image) {
                    self.endWakeCover()
                    return
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    /// A blank document is one flat color. The edges are ignored: the dark backdrop shows there while the
    /// document in the middle is still white, and that contrast is not the page.
    private static func pageHasContent(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 4, height > 4 else { return false }
        var minLuma = 1.0, maxLuma = 0.0, samples = 0
        let x0 = width / 4, x1 = width * 3 / 4, y0 = height / 4, y1 = height * 3 / 4
        let stepX = max(1, (x1 - x0) / 8), stepY = max(1, (y1 - y0) / 8)
        for y in stride(from: y0, to: y1, by: stepY) {
            for x in stride(from: x0, to: x1, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luma = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
                samples += 1
            }
        }
        return samples > 0 && maxLuma - minLuma > 0.12
    }

    /// Drops the web view. WebKit exits the WebContent process once no web view uses it.
    func sleep() {
        hideContactChip()
        endWakeCover()
        guard let webView else { return }
        exitPictureInPictureIfNeeded()
        // Before the first page commits there is no history worth keeping; waking then loads the URL again. The
        // "Extension not loaded" page keeps the history it was standing in for.
        if !showsExtensionUnavailable && !awaitingBlockers {
            savedState = webView.backForwardList.currentItem == nil ? nil : webView.interactionState
        }
        hoveredLink = nil
        showsExtensionUnavailable = false
        awaitingBlockers = false
        loadedUnblocked = false
        committedErrorPage = false
        isProcessTerminated = false
        readerArticle = nil
        isReaderAvailable = false
        pendingOwnPage = nil
        resumeSelectionWaiters(false)
        pageWork = [:]
        observations.forEach { $0.invalidate() }
        observations = []
        audioObserver?.invalidate()
        audioObserver = nil
        isPlayingAudio = false
        isInPictureInPicture = false
        // WebKit raises NSInternalInconsistencyException ("The WKWebView is suspended") from `stopLoading` on a frozen
        // page. Thrown through the sweep's Task it corrupts Swift's executor tracking and crashes Paddle minutes later
        // in an unrelated actor check. A frozen page never loads (`freeze()` skips loading pages), so nothing to stop.
        if !isSuspendedInWebKit { webView.stopLoading() }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate = nil
        isAwake = false
        isFrozen = false
        suspendRequested = false
        isLoading = false
        progress = 0
        isCapturing = false
        memoryBytes = nil
        sharesProcess = false
        extensionPageID = nil
        generation += 1
    }

    // MARK: - Freeze

    /// WebKit's private `_suspendPage:` and `_resumePage:` both exist. Without them nothing freezes and tabs only sleep.
    private static let suspendSelector = NSSelectorFromString("_suspendPage:")
    private static let resumeSelector = NSSelectorFromString("_resumePage:")
    static let supportsFreezing = WKWebView.instancesRespond(to: suspendSelector) && WKWebView.instancesRespond(to: resumeSelector)

    /// Freezes an awake background page: WebKit stops its JavaScript, timers and animations and keeps it in memory, so
    /// `unfreeze()` shows it again with no reload. Settings tabs have no web view, so they never reach this. Skips a
    /// page still loading or waiting for the block lists, since suspending it would stall its first load. Returns
    /// whether a freeze was asked for; WebKit's answer lands later and sets `isFrozen`.
    @discardableResult
    func freeze() -> Bool {
        guard Self.supportsFreezing, let webView, !isFrozen, !suspendRequested, !isLoading, !awaitingBlockers,
              webView.responds(to: Self.suspendSelector), webView.responds(to: Self.resumeSelector) else { return false }
        // No `PrivateAPI.trimWebKitMemory` here: it acts on the shared process pool, forcing a JavaScript collection in
        // every web process (the page on screen included) and dropping WebKit's cached processes, on each freeze.
        // Memory pressure still trims (`AppModel.trimWebKitMemory`).
        suspendRequested = true
        // The pages WebKit keeps alive for an instant Back (its back-forward cache) go too: a page left for another
        // site keeps a whole WebContent process (measured: 291 MB after Reddit -> Wikipedia). History stays; Back on
        // this tab then loads the page again. Private `_clearBackForwardCache`; without it they stay.
        PrivateAPI.callVoid("_clearBackForwardCache", on: webView)
        // Private WebKit API (`_suspendPage:`, a reply block with a BOOL), called the way `applyMute` calls its selectors.
        typealias Suspend = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void
        let suspend = unsafeBitCast(webView.method(for: Self.suspendSelector), to: Suspend.self)
        suspend(webView, Self.suspendSelector) { [weak self] suspended in
            Task { @MainActor in
                // A sleep, a reload or a select meanwhile has already settled the state: this answer is stale.
                guard let self, self.webView === webView, self.suspendRequested else { return }
                if suspended {
                    self.isFrozen = true
                } else {
                    self.suspendRequested = false
                    Self.log.notice("WebKit did not freeze a background page")
                }
            }
        }
        return true
    }

    /// Shows a frozen page again, and cancels a freeze whose answer hasn't come back. Every path that needs the page
    /// live calls this (`wake()`, `reload`, `load`, the block-list reload, View Source, extension calls).
    func unfreeze() {
        guard isFrozen || suspendRequested else { return }
        isFrozen = false
        suspendRequested = false
        guard let webView, Self.supportsFreezing, webView.responds(to: Self.resumeSelector) else { return }
        typealias Resume = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void
        let resume = unsafeBitCast(webView.method(for: Self.resumeSelector), to: Resume.self)
        resume(webView, Self.resumeSelector) { resumed in
            if !resumed { Self.log.notice("WebKit did not resume a frozen page") }
        }
        // Zoom and dark mode changes skipped while it was frozen (`applySiteZoom`, `applySiteDarkMode`).
        applySiteZoom()
        applySiteDarkMode(systemIsDark: AppModel.shared.effectiveAppearanceIsDark)
    }

    /// Address bar, session restore and extension `tabs.update`. Crossing between an extension page and a web
    /// page (either way) swaps the web view, since each needs its own configuration.
    func load(_ url: URL) {
        self.url = url
        httpsOnlyBlocked = nil
        showsExtensionUnavailable = false
        sourceHTML = nil
        committedErrorPage = false
        isProcessTerminated = false
        readerArticle = nil
        isReaderAvailable = false
        if let webView {
            if ExtensionIdentity.identifier(of: url) != extensionPageID {
                replaceWebView(loading: url)
            } else if awaitingBlockers {
                // The first load, still waiting for the block lists, loads this URL instead.
                savedState = nil
            } else {
                unfreeze()
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
        commitCount += 1
        pageWork = [:]
        committedErrorPage = own == .error
        if own == nil { sourceHTML = nil }
        // Extension pages and Paddle's own pages get no block lists, so they never need the reload.
        loadedUnblocked = own == nil && extensionPageID == nil && !AppModel.shared.web.blockersReady.isReady
        applySiteSettingsAfterCommit(backForward: committingNavigationType == .backForward)
        committingNavigationType = nil
        // A navigation inside the tab is a session change too (its URL and history), not only tab and window changes.
        if !isPrivate && !isPreview { AppModel.shared.sessionChanged() }
    }

    /// Why WebKit stopped a web process (`_WKProcessTerminationReason`, private WebKit API).
    enum TerminationReason: Int {
        case exceededMemoryLimit, exceededCPULimit, requestedByClient, crash, exceededSharedProcessCrashLimit
    }

    /// The web process crashed or was stopped. A background tab just goes to sleep and loads again when shown. The
    /// visible tab shows a crash page with a Reload button instead of reloading by itself, so a page that crashes as
    /// it loads can't loop; it says why when WebKit does (too much memory or CPU).
    func processTerminated(reason: TerminationReason? = nil) {
        isInPictureInPicture = false
        Self.log.notice("web content process ended: \(reason.map { String(describing: $0) } ?? "no reason given", privacy: .public), \(self.browser?.isVisible(self) == true ? "visible, reloading" : "background, sleeping", privacy: .public)")
        guard browser?.isVisible(self) == true, let webView else {
            sleep()
            return
        }
        isProcessTerminated = true
        committedErrorPage = true
        pendingOwnPage = .error
        let (title, message) = switch reason {
        case .exceededMemoryLimit:
            ("This page used too much memory", "macOS stopped its web process because it used more memory than a page may. Reload to start it again.")
        case .exceededCPULimit:
            ("This page used too much CPU", "WebKit stopped its web process because it kept the processor busy for too long. Reload to start it again.")
        default:
            ("This page crashed", "Its web process stopped unexpectedly. Reload to load it again.")
        }
        skipNextCommitInHistory = true
        // Not `loadErrorPage`: after a crash there is no failed load to stand in for, and both of its loads append
        // a second item for the crashed page. Loading with `url` as base URL reuses the crashed page's item.
        webView.loadHTMLString(TabWebDelegate.errorPage(title: title, message: message, url: url, button: "Reload"), baseURL: url)
    }

    /// Turns Responsive Design Mode on or off. Leaving with a device user agent reloads, so the page returns to the tab's own.
    func toggleResponsive() {
        if let old = responsive {
            responsive = nil
            if old.userAgent != .paddle { reload() }
        } else {
            let state = ResponsiveState()
            responsive = state
            if state.userAgent != .paddle { reload() }
        }
        // The page moves between two WebContainers, and SwiftUI can update the outgoing one after the incoming one
        // took the container, leaving the page blank. Once the switch has settled, make the shown one take it again.
        DispatchQueue.main.async { [weak self] in self?.generation += 1 }
    }

    /// Picks a device and starts with its user agent. The page reloads when the agent changes.
    func setResponsiveDevice(_ id: String) {
        guard var state = responsive, let device = ResponsiveDevice.preset(id: id) else { return }
        let old = state.userAgent
        state.deviceID = id
        state.userAgent = device.userAgent
        responsive = state
        if old != state.userAgent { reload() }
    }

    /// Changes the user agent Responsive Design Mode sends and reloads the page.
    func setResponsiveUserAgent(_ agent: ResponsiveUserAgent) {
        guard var state = responsive, state.userAgent != agent else { return }
        state.userAgent = agent
        responsive = state
        reload()
    }

    /// The toolbar's Reload, View > Reload Page and an extension's `tabs.reload`. On one of Paddle's error or crash
    /// pages that loads the page's URL again: WebKit's reload would only show the error page again.
    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        unfreeze()
        if (committedErrorPage || pendingOwnPage == .error || isProcessTerminated), let url {
            isProcessTerminated = false
            committedErrorPage = false
            pendingOwnPage = nil
            webView.load(URLRequest(url: url, cachePolicy: fromOrigin ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy))
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    /// Toggles Reader Mode on this tab. If already showing Reader Mode, closes it and returns to the page.
    /// Otherwise extracts the article and displays Reader Mode.
    func toggleReaderMode() {
        if readerArticle != nil {
            readerArticle = nil
            return
        }
        guard let webView, isAwake, !isShowingErrorPage else { return }
        unfreeze()
        webView.evaluateJavaScript(ReaderExtractor.extractionScript, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let value: Any
            switch result {
            case .success(let v): value = v
            case .failure(let error):
                Self.log.error("reader extraction script failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard let json = value as? String else {
                Self.log.notice("reader extraction found no article (returned \(String(describing: type(of: value)), privacy: .public))")
                return
            }
            do {
                self.readerArticle = try JSONDecoder().decode(ReaderArticle.self, from: Data(json.utf8))
                self.isReaderAvailable = true
            } catch {
                Self.log.error("reader article did not decode: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func checkReaderAvailability() {
        guard let webView, isAwake, !isShowingErrorPage, readerArticle == nil, !isSuspendedInWebKit else {
            isReaderAvailable = false
            return
        }
        webView.evaluateJavaScript(ReaderExtractor.availabilityProbeScript, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, let available = value as? Bool {
                self.isReaderAvailable = available
            } else {
                self.isReaderAvailable = false
            }
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
            // Another sheet is up: wait for it to end. If the window closes first it never does.
            guard await Self.sheetEnds(on: window) else { return .abort }
        }
    }

    /// True when `window`'s sheet ends; false when the window closes first.
    private static func sheetEnds(on window: NSWindow) async -> Bool {
        let wait = SheetWait()
        return await wait.wait(on: window)
    }

    /// True once the tab is selected; false if it closes or sleeps first. A tab already closed answers false at once:
    /// it is never selected again, and nothing would resume the wait.
    func waitUntilSelected() async -> Bool {
        if browser?.isVisible(self) == true { return true }
        guard browser?.allTabs.contains(where: { $0 === self }) == true else { return false }
        return await withCheckedContinuation { selectionWaiters.append($0) }
    }

    func resumeSelectionWaiters(_ selected: Bool) {
        let waiters = selectionWaiters
        selectionWaiters = []
        waiters.forEach { $0.resume(returning: selected) }
    }

    /// What one frame of the page reported through `PageWorkScript`.
    struct PageWork: Equatable {
        var uploading: Bool
        var guardsUnload: Bool
        var isIdle: Bool { !uploading && !guardsUnload }
    }

    /// `PageWorkScript` reports by frame, kept only while a frame has something to report. Cleared when the main frame
    /// commits a new page and when the tab sleeps.
    @ObservationIgnored var pageWork: [String: PageWork] = [:]
    /// A frame of this page is uploading a file.
    var isUploading: Bool { pageWork.values.contains(where: \.uploading) }
    /// A frame of this page asks before it is left (unsaved changes).
    var guardsUnload: Bool { pageWork.values.contains(where: \.guardsUnload) }

    /// Making sound or using camera/mic: never put to sleep (`MediaActivity`). Where WebKit's sound flag can't be
    /// observed, any media playing counts, which takes a round trip to the page.
    func isBusy() async -> Bool {
        if isInPictureInPicture { return true }
        guard let webView else { return false }
        // A frozen page runs nothing, so it plays nothing; asking it would wait on a page that can't answer, and
        // WebKit raises from the call while a freeze is still in flight.
        if isSuspendedInWebKit { return false }
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
        AppModel.shared.existingExtensions(for: profileID)?.tabChanged(self, .muted)
    }

    func toggleMute() {
        setMuted(!isMuted)
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

    // MARK: - Picture in Picture

    /// Toggles Picture in Picture for an HTML5 video on this tab's page.
    func togglePictureInPicture() {
        guard let webView, isAwake, !isShowingErrorPage else { return }
        // The tab menu and media popover can reach a frozen background tab.
        unfreeze()
        // Must run in the same turn as the menu/shortcut or `requestPictureInPicture()` loses user activation.
        webView.evaluateJavaScript(PictureInPictureScript.toggle, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Self.log.debug("picture in picture: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Closes PiP before dropping the web view so WebKit doesn't keep a stray decoder.
    func exitPictureInPictureIfNeeded() {
        guard isInPictureInPicture, let webView, isAwake else { return }
        webView.evaluateJavaScript(PictureInPictureScript.exit, in: nil, in: .page) { _ in }
        isInPictureInPicture = false
    }

    /// Certificate details of the TLS connection, or nil for non-HTTPS pages.
    var certificateInfo: CertificateInfo? {
        guard let webView, let trust = webView.serverTrust else { return nil }
        return CertificateInfo.read(from: trust)
    }

    // MARK: - Site settings

    /// The site of a web page (http or https) showing in an ordinary web view; nil for extension pages and others.
    var siteHost: String? {
        guard extensionPageID == nil, let url = webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host()
    }

    /// Applies per-site zoom and dark mode after a commit. Back/forward waits so `ScrollRestoreScript` can finish
    /// before `pageZoom` layout runs.
    private func applySiteSettingsAfterCommit(backForward: Bool) {
        deferredSiteSettingsTask?.cancel()
        let systemDark = AppModel.shared.effectiveAppearanceIsDark
        if backForward {
            let generation = commitCount
            deferredSiteSettingsTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled, self.commitCount == generation else { return }
                self.applySiteZoom()
                self.applySiteDarkMode(systemIsDark: systemDark)
            }
        } else {
            deferredSiteSettingsTask = nil
            applySiteZoom()
            applySiteDarkMode(systemIsDark: systemDark)
        }
    }

    /// Sets the page's zoom to its site's (`AppModel.siteZoom`), the default zoom for a page with no site (file:,
    /// about:blank) and 100 % for Paddle's own pages, so the last site's zoom doesn't carry over. When a page commits and when `sites`
    /// changes.
    func applySiteZoom() {
        // The setter raises on a suspended page; `unfreeze()` applies it.
        guard let webView, !isSuspendedInWebKit else { return }
        let own = pendingOwnPage != nil || committedErrorPage || sourceHTML != nil
        let model = AppModel.shared
        let zoom = own ? 1 : siteHost.map { model.siteZoom(forHost: $0, isPrivate: isPrivate, profile: profileID) } ?? model.config.defaultZoom
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
    }

    /// View > Zoom In / Zoom Out / Actual Size: zooms the page and remembers the zoom for its site (for this run
    /// only in a private window).
    func setZoom(_ zoom: Double) {
        guard let webView else { return }
        let zoom = SitePolicy.normalizedZoom(zoom)
        webView.pageZoom = zoom
        guard let host = siteHost else { return }
        AppModel.shared.rememberZoom(zoom, forHost: host, isPrivate: isPrivate, profile: profileID)
    }

    /// A Mosaic pane's own dark mode (`mosaicDarkMode` unified or per pane, or the pane toolbar's menu): it wins over
    /// the site setting for this tab only, and isn't saved. Nil follows the site. Cleared when the tab leaves its Mosaic.
    var darkModeOverride: Bool?

    /// Dark mode as this tab shows it: `darkModeOverride`, else the site setting.
    var isDarkModeActive: Bool {
        resolvedPageDarkEngine(systemIsDark: AppModel.shared.effectiveAppearanceIsDark) != .off
    }

    /// Effective dark-mode engine for this tab (Mosaic pane override, then site + global rules).
    func resolvedPageDarkEngine(systemIsDark: Bool) -> PageDarkEngine {
        guard let host = siteHost else { return .off }
        if let override = darkModeOverride {
            if !override { return .off }
            return config.darkMode == .native ? .native : .smart
        }
        return config.sitePolicy(forHost: host, systemIsDark: systemIsDark).pageDarkEngine
    }

    /// Sets `darkModeOverride` and applies it to the open page.
    func setDarkModeOverride(_ dark: Bool?) {
        guard dark != darkModeOverride else { return }
        darkModeOverride = dark
        applySiteDarkMode(systemIsDark: AppModel.shared.effectiveAppearanceIsDark)
    }

    var isSiteDarkModeActive: Bool {
        guard let host = siteHost else { return false }
        let isDark = AppModel.shared.effectiveAppearanceIsDark
        return config.sitePolicy(forHost: host, systemIsDark: isDark).pageDarkEngine != .off
    }

    func applySiteDarkMode(systemIsDark: Bool) {
        applyPageDarkEngine(resolvedPageDarkEngine(systemIsDark: systemIsDark))
    }

    private func applyPageDarkEngine(_ engine: PageDarkEngine) {
        refreshPageBackdrop()
        // Scripts raise on a suspended page; `unfreeze()` applies it.
        guard let webView, !isSuspendedInWebKit, siteHost != nil else { return }
        unfreeze()
        let invert = AppModel.shared.config.invertTextImages
        let js = """
        if (window.__paddleDarkMode) { window.__paddleDarkMode.setPolicy({ engine: '\(engine.rawValue)', invertTextImages: \(invert ? "true" : "false") }); }
        """
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }

    func applyInvertTextImages() {
        guard let webView, !isSuspendedInWebKit else { return }
        let enabled = AppModel.shared.config.invertTextImages
        let js = "if (window.__paddleDarkMode) { window.__paddleDarkMode.setInvertTextImages(\(enabled ? "true" : "false")); }"
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }

    /// Toggles website dark mode for this tab's site and saves it in `sites` (the profile's own settings when it sets
    /// the site's darkMode). A private window writes nothing to config.json: there it changes this tab only
    /// (`darkModeOverride`). Off becomes Dark; any active engine becomes Light.
    func toggleDarkMode() {
        guard let host = siteHost else { return }
        let isDark = AppModel.shared.effectiveAppearanceIsDark
        let turningOn = resolvedPageDarkEngine(systemIsDark: isDark) == .off
        if isPrivate {
            setDarkModeOverride(turningOn)
            unfreeze()
            return
        }
        let key = config.siteKey(forHost: host)
        let mode: SiteSettings.SiteDarkMode = turningOn ? .dark : .light
        Task {
            await AppModel.shared.writeSiteSetting(.darkMode, .string(mode.rawValue), forKey: key, profile: profileID)
        }
        let engine = PageDarkEngine.resolved(site: mode, global: config.darkMode, systemIsDark: isDark)
        applyPageDarkEngine(engine)
    }

    /// View > Dark Mode > Looks Wrong → Keep Light: forces this site to stay light (saved unless the window is private).
    func keepPageLight() {
        guard siteHost != nil else { return }
        if isPrivate {
            setDarkModeOverride(false)
        } else {
            guard let host = siteHost else { return }
            let key = config.siteKey(forHost: host)
            Task {
                await AppModel.shared.writeSiteSetting(.darkMode, .string(SiteSettings.SiteDarkMode.light.rawValue), forKey: key, profile: profileID)
            }
        }
        guard let webView, !isSuspendedInWebKit else { return }
        unfreeze()
        webView.evaluateJavaScript(
            "if (window.__paddleDarkMode) { window.__paddleDarkMode.setKeepLight(); }",
            in: nil, in: .defaultClient, completionHandler: nil
        )
        refreshPageBackdrop()
    }

    /// View > Dark Mode submenu: sets this host's `sites.<host>.darkMode` (Auto removes the key).
    func setSiteDarkMode(_ mode: SiteSettings.SiteDarkMode) {
        guard let host = siteHost, !isPrivate else { return }
        darkModeOverride = nil
        let key = config.siteKey(forHost: host)
        Task {
            await AppModel.shared.writeSiteSetting(.darkMode, .string(mode.rawValue), forKey: key, profile: profileID)
        }
        let isDark = AppModel.shared.effectiveAppearanceIsDark
        let engine = PageDarkEngine.resolved(site: mode, global: config.darkMode, systemIsDark: isDark)
        applyPageDarkEngine(engine)
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
                let nextTitle = webView.title ?? ""
                if tab.title != nextTitle {
                    tab.title = nextTitle
                    AppModel.shared.existingExtensions(for: tab.profileID)?.tabChanged(tab, .title)
                }
                // One write per real title change of the recorded page.
                guard let url = tab.historyURL, webView.url == url, !tab.title.isEmpty, tab.title != tab.historyTitle else { return }
                tab.historyTitle = tab.title
                AppModel.shared.updateHistoryTitle(url, tab.title, profile: tab.profileID)
            },
            watch(\.url) { tab, webView in
                tab.hideContactChip()
                // The error page's about:blank must not replace the extension URL it stands in for.
                guard let url = webView.url, !tab.showsExtensionUnavailable, tab.url != url else { return }
                tab.url = url
                tab.browser?.tabURLChanged(tab)
            },
            watch(\.isLoading) { tab, webView in
                tab.hideContactChip()
                guard tab.isLoading != webView.isLoading else { return }
                tab.isLoading = webView.isLoading
                AppModel.shared.existingExtensions(for: tab.profileID)?.tabChanged(tab, .loading)
            },
            watch(\.estimatedProgress) { tab, webView in
                let next = webView.estimatedProgress
                if abs(tab.progress - next) >= 0.005 || next == 0 || next == 1 {
                    tab.progress = next
                }
            },
            watch(\.canGoBack) { tab, webView in
                if tab.canGoBack != webView.canGoBack { tab.canGoBack = webView.canGoBack }
            },
            watch(\.canGoForward) { tab, webView in
                if tab.canGoForward != webView.canGoForward { tab.canGoForward = webView.canGoForward }
            },
            watch(\.hasOnlySecureContent) { tab, webView in
                if tab.isSecure != webView.hasOnlySecureContent { tab.isSecure = webView.hasOnlySecureContent }
            },
            watch(\.cameraCaptureState) { tab, webView in tab.updateCapturing(webView) },
            watch(\.microphoneCaptureState) { tab, webView in tab.updateCapturing(webView) },
        ]
    }

    private func updateCapturing(_ webView: WKWebView) {
        let next = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        if isCapturing != next { isCapturing = next }
    }

    /// The configuration for this tab's ordinary pages: the private data store in a private window,
    /// and the extension controller only where extensions are allowed.
    private func makeWebConfiguration() -> WKWebViewConfiguration {
        AppModel.shared.web.makeConfiguration(isPrivate: isPrivate, extensions: extensionsAllowed, profile: profileID)
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

/// One wait for a window's sheet to end or the window to close, whichever comes first (`Tab.present`).
private final class SheetWait {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observers: [any NSObjectProtocol] = []

    func wait(on window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for (name, ended) in [(NSWindow.didEndSheetNotification, true), (NSWindow.willCloseNotification, false)] {
                // Posted on the main thread, as `queue: .main` delivers it.
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(ended) }
                })
            }
        }
    }

    private func finish(_ ended: Bool) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        continuation?.resume(returning: ended)
        continuation = nil
    }
}
