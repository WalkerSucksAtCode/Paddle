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
    /// Recent web process crashes, with the host that was showing.
    @ObservationIgnored private var crashes: [(date: Date, host: String?)] = []
    @ObservationIgnored private var selectionWaiters: [CheckedContinuation<Bool, Never>] = []

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
        let state = (webView?.interactionState ?? savedState) as? Data
        return TabRecord(url: url?.absoluteString ?? "", title: title, isPinned: isPinned, interactionState: state)
    }

    // MARK: - Wake / sleep

    /// Creates the web view if the tab is asleep, restoring its page and history.
    @discardableResult
    func wake() -> WKWebView {
        if let webView { return webView }
        let webView = WKWebView(frame: .zero, configuration: AppModel.shared.web.makeConfiguration())
        attach(webView)
        if let savedState {
            webView.interactionState = savedState
        } else if let url {
            webView.load(URLRequest(url: url))
        }
        savedState = nil
        return webView
    }

    /// Adopts a web view, either one this tab made or one WebKit made for a popup.
    func attach(_ webView: WKWebView) {
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
    }

    /// Drops the web view. WebKit exits the WebContent process once no web view uses it.
    func sleep() {
        guard let webView else { return }
        // Before the first page commits there is no history worth keeping; waking then loads the URL again.
        savedState = webView.backForwardList.currentItem == nil ? nil : webView.interactionState
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
        generation += 1
    }

    func load(_ url: URL) {
        self.url = url
        if let webView {
            webView.load(URLRequest(url: url))
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
            watch(\.title) { tab, webView in tab.title = webView.title ?? "" },
            watch(\.url) { tab, webView in
                guard let url = webView.url else { return }
                tab.url = url
                tab.browser?.tabURLChanged(tab)
            },
            watch(\.isLoading) { tab, webView in tab.isLoading = webView.isLoading },
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
