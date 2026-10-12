import AppKit
import PaddleCore
import WebKit

/// Errors handed back to extensions through WebKit's completion handlers.
enum PaddleExtensionError: LocalizedError {
    case tabAsleep
    case noWindow
    case noPopup
    case noUserAction
    case noOptions
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .tabAsleep: "The tab is asleep"
        case .noWindow: "No browser window"
        case .noPopup: "The action has no popup"
        case .noUserAction: "A popup opens only when the user clicks the extension's button"
        case .noOptions: "The extension has no options page"
        case .unsupported(let what): "\(what) is not supported in Paddle"
        }
    }

    /// Refuses a URL an extension may not put in a tab: only web pages, about:blank and its own pages
    /// (`ExtensionIdentity.extensionMayOpen`). Paddle starts these loads itself, past WebKit's origin checks.
    @MainActor static func checkOpenable(_ url: URL, for context: WKWebExtensionContext) throws {
        guard ExtensionIdentity.extensionMayOpen(url, extensionID: context.uniqueIdentifier) else {
            throw PaddleExtensionError.unsupported("Opening \(url.scheme ?? "these") URLs from an extension")
        }
    }
}

/// A `Tab` as WebKit's extension API sees it. Reads never wake a sleeping tab (its URL and title are known
/// anyway, like a discarded tab in Chrome); actions that need a page wake it, and the sleep sweep keeps the
/// budget afterwards.
final class ExtensionTab: NSObject, WKWebExtensionTab {
    private(set) weak var tab: Tab?

    init(tab: Tab?) {
        self.tab = tab
    }

    private var browser: BrowserModel? { tab?.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser?.controller?.extensionWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let browser else { return NSNotFound }
        return browser.tabs.firstIndex { $0 === tab } ?? NSNotFound
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab?.opener?.extensionTab
    }

    func setParentTab(_ parentTab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async throws {
        tab?.opener = (parentTab as? ExtensionTab)?.tab
    }

    /// nil while asleep: no content injection until the tab shows again.
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.isPinned ?? false
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { throw PaddleExtensionError.noWindow }
        if tab.isPinned != pinned { browser.togglePin(tab) }
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        guard let tab else { return .zero }
        let container = tab.webView != nil ? tab.container : browser?.selectedTab?.container
        return container?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(tab?.webView?.pageZoom ?? 1)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        guard let webView = tab?.wake() else { throw PaddleExtensionError.tabAsleep }
        webView.pageZoom = min(max(zoomFactor, 0.3), 3)
    }

    /// `tabs.update({url})`. A sleeping tab loads now, as Chrome does for a discarded tab, so the extension sees the
    /// load finish; the sleep sweep keeps the budget afterwards.
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { throw PaddleExtensionError.noWindow }
        try PaddleExtensionError.checkOpenable(url, for: context)
        tab.closesIfOnlyDownload = false
        tab.load(url)
        if !tab.isAwake {
            tab.lastActive = Date()
            tab.wake()
            if browser.selectedID != tab.id { AppModel.shared.sweepSleepingTabs() }
        }
        // An awake tab reports the new URL through its observer; one still asleep (an extension page waiting for
        // its extension to load) reports it here.
        if !tab.isAwake { browser.tabURLChanged(tab) }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab else { throw PaddleExtensionError.noWindow }
        guard let webView = tab.webView else {
            tab.wake()
            return
        }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        guard let webView = tab?.wake() else { throw PaddleExtensionError.tabAsleep }
        webView.goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        guard let webView = tab?.wake() else { throw PaddleExtensionError.tabAsleep }
        webView.goForward()
    }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { throw PaddleExtensionError.noWindow }
        browser.select(tab)
        NSApp.activate()
        browser.controller?.window?.makeKeyAndOrderFront(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let browser else { return false }
        return browser.selectedID == tab.id
    }

    /// Paddle has single selection, so selecting is activating and deselecting does nothing.
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        guard selected else { return }
        try await activate(for: context)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let tab, let browser else { throw PaddleExtensionError.noWindow }
        return browser.duplicate(tab).extensionTab
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { throw PaddleExtensionError.noWindow }
        browser.close(tab)
    }

    /// `takeSnapshotUsingConfiguration:forWebExtensionContext:completionHandler:`; its async Swift name is
    /// `snapshot(using:for:)` (WK_SWIFT_ASYNC_NAME), which the DEBUG selector check guards.
    func snapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let webView = tab?.webView else { return nil }
        return try await webView.takeSnapshot(configuration: configuration)
    }

    /// Clicking the extension's button grants `activeTab` for that click, as in Chrome.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

/// A browser window as WebKit's extension API sees it.
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private(set) weak var controller: BrowserWindowController?

    init(controller: BrowserWindowController?) {
        self.controller = controller
    }

    private var window: NSWindow? { controller?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        controller?.model.tabs.map(\.extensionTab) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        controller?.model.selectedTab?.extensionTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext) async throws {
        guard let window else { throw PaddleExtensionError.noWindow }
        let current = windowState(for: context)
        guard current != state else { return }
        // Leave the current special state first, then enter the wanted one.
        switch current {
        case .minimized: window.deminiaturize(nil)
        case .fullscreen: window.toggleFullScreen(nil)
        case .maximized: window.zoom(nil)
        default: break
        }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .fullscreen: window.toggleFullScreen(nil)
        case .maximized: window.zoom(nil)
        default: break
        }
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        controller?.model.isPrivate ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (window?.screen ?? NSScreen.main)?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard let window else { throw PaddleExtensionError.noWindow }
        window.setFrame(frame, display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        guard let window else { throw PaddleExtensionError.noWindow }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let window else { throw PaddleExtensionError.noWindow }
        window.performClose(nil)
    }
}
