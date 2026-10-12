import AppKit
import PaddleCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One browser window. Menu commands reach it through the responder chain (it is the window's delegate),
/// so every action works whether the page or the address field has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserModel

    init(record: WindowRecord?, isPrivate: Bool = false, extensionsAllowed: Bool = true) {
        model = BrowserModel(isPrivate: isPrivate, extensionsAllowed: extensionsAllowed)
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty compact toolbar makes the titlebar 38pt tall, so the traffic lights sit centred in the tab strip.
        window.toolbar = NSToolbar(identifier: "PaddleToolbar")
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: window)
        window.delegate = self
        model.controller = self
        window.contentView = NSHostingView(rootView: BrowserView(model: model, app: AppModel.shared))
        // The tab strip sits in the title bar, and the window server drags the window from anywhere in the title
        // bar, tabs and their close buttons included, so tab drag-reordering moved the window instead. Server-side
        // dragging is off; empty strip space (`WindowDragArea`) starts window drags itself.
        window.isMovable = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        if let record {
            if let frame = record.frame { window.setFrame(NSRectFromString(frame), display: false) }
            let tabs = record.tabs.map { Tab(record: $0, isPrivate: isPrivate) }
            // An old-format record has no lastActive; rank earlier tabs as more recent (1 s apart) so the history
            // cap doesn't favour the end of the strip.
            let now = Date()
            for (i, tab) in tabs.enumerated() where record.tabs[i].lastActive == nil {
                tab.lastActive = now.addingTimeInterval(-Double(i + 1))
            }
            for tab in tabs {
                tab.browser = model
                model.tabs.append(tab)
            }
            let index = min(max(record.selectedIndex, 0), tabs.count - 1)
            if tabs.indices.contains(index) { model.select(tabs[index]) }
        } else if let front = AppModel.shared.frontWindow?.window {
            window.setFrame(front.frame.offsetBy(dx: 24, dy: -24), display: false)
        } else {
            window.center()
        }
        screensChanged()
    }

    /// The system doesn't move or resize a non-movable window when displays change, so Paddle does: a window on
    /// no screen is centred on the main one, and one whose tab strip ended up above a screen's top is pulled down
    /// so it can still be dragged. Restored frames from a disconnected display get the same treatment.
    @objc private func screensChanged() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        } else {
            let constrained = window.constrainFrameRect(window.frame, to: screen)
            if constrained != window.frame { window.setFrame(constrained, display: true) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focusWebView() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.model.selectedTab?.webView, webView.window === self.window else { return }
            self.window?.makeFirstResponder(webView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.extensions.windowClosing(self)
        for tab in model.tabs { tab.sleep() }
        AppModel.shared.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.selectedTab?.lastActive = Date()
        AppModel.shared.extensions.windowFocused(self)
    }

    /// This window as WebKit's extension API sees it.
    lazy var extensionWindow = ExtensionWindow(controller: self)

    func windowDidResignKey(_ notification: Notification) {
        model.suggestions.dismiss()
    }

    private var tab: Tab? { model.selectedTab }
    private var webView: WKWebView? { model.selectedTab?.webView }

    // MARK: - File

    @objc func paddleNewTab(_ sender: Any?) { model.openNewTabPage() }
    @objc func paddleOpenLocation(_ sender: Any?) { model.focusAddress() }
    @objc func paddleCloseTab(_ sender: Any?) { if let tab { model.close(tab) } }
    @objc func paddleReopenClosedTab(_ sender: Any?) { model.reopenClosedTab() }

    /// Print, Save Page As and View Source need the site's page showing: not the start page, a sleeping tab, a tab
    /// waiting for its extension or one of Paddle's error pages. And no sheet up already (the save or print panel,
    /// a page's alert), which AppKit would queue a second sheet behind, for whatever tab was current then.
    private var canActOnPage: Bool {
        guard let tab, webView != nil, tab.url != nil, !tab.isShowingErrorPage else { return false }
        return window?.attachedSheet == nil
    }

    /// File > Print…: WebKit's print operation for the page, as a sheet on this window.
    @objc func paddlePrint(_ sender: Any?) {
        guard canActOnPage, let webView, let window else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = tab?.displayTitle ?? "Page"
        // WebKit's print view has no size of its own; without one the operation can print blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// File > Save Page As…: the page as a Web Archive (`createWebArchiveData`: the page and its loaded
    /// resources, as WebKit holds them now).
    @objc func paddleSavePage(_ sender: Any?) {
        guard canActOnPage, let tab, let webView, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.webArchive]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.fileName(for: tab) + ".webarchive"
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            webView.createWebArchiveData { result in
                do {
                    try result.get().write(to: destination, options: .atomic)
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The page couldn't be saved"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    /// A file name from the page title (or host), without characters Finder or the shell trip over.
    private static func fileName(for tab: Tab) -> String {
        let raw = tab.title.isEmpty ? (tab.url?.host() ?? "Page") : tab.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines)).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Page" : cleaned).prefix(120))
    }

    // MARK: - View

    @objc func paddleReload(_ sender: Any?) { webView?.reload() }
    @objc func paddleHardReload(_ sender: Any?) { webView?.reloadFromOrigin() }
    @objc func paddleStop(_ sender: Any?) { webView?.stopLoading() }
    // The zoom is remembered for the site (`Tab.setZoom`).
    @objc func paddleZoomIn(_ sender: Any?) { if let tab, let webView { tab.setZoom(webView.pageZoom + SitePolicy.zoomStep) } }
    @objc func paddleZoomOut(_ sender: Any?) { if let tab, let webView { tab.setZoom(webView.pageZoom - SitePolicy.zoomStep) } }
    @objc func paddleActualSize(_ sender: Any?) { tab?.setZoom(1) }

    @objc func paddleWebInspector(_ sender: Any?) {
        if let webView { WebInspector.show(webView) }
    }

    @objc func paddleViewSource(_ sender: Any?) {
        guard canActOnPage, let tab else { return }
        Task { await model.viewSource(of: tab) }
    }

    // MARK: - History

    @objc func paddleBack(_ sender: Any?) { webView?.goBack() }

    // MARK: - Bookmarks

    @objc func paddleToggleBookmark(_ sender: Any?) {
        guard let tab, let url = tab.url, HistoryStore.isRecordable(url) else { return }
        AppModel.shared.bookmarks.toggle(url: url, title: tab.title)
    }
    @objc func paddleForward(_ sender: Any?) { webView?.goForward() }

    // MARK: - Find

    @objc func paddleFind(_ sender: Any?) { model.showFind() }
    @objc func paddleFindNext(_ sender: Any?) { model.findVisible ? model.find() : model.showFind() }
    @objc func paddleFindPrevious(_ sender: Any?) { model.findVisible ? model.find(backwards: true) : model.showFind() }

    // MARK: - Tabs

    @objc func paddleNextTab(_ sender: Any?) { model.selectNeighbor(offset: 1) }
    @objc func paddlePreviousTab(_ sender: Any?) { model.selectNeighbor(offset: -1) }
    @objc func paddleTogglePin(_ sender: Any?) { if let tab { model.togglePin(tab) } }
    @objc func paddleDuplicateTab(_ sender: Any?) { if let tab { model.duplicate(tab) } }
    @objc func paddleToggleMute(_ sender: Any?) { if let tab { model.toggleMute(tab) } }
    @objc func paddleSleepBackgroundTabs(_ sender: Any?) { AppModel.shared.sleepBackgroundTabs() }

    @objc func paddleSelectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if item.tag == 9 { model.selectLastTab() } else { model.select(index: item.tag - 1) }
    }
}

/// Ctrl-Tab is AppKit's keyboard-focus key: a focused web view passes it on to the key view loop, so the
/// Tabs menu never saw it and focus jumped to the address field instead. Offer it to the menu first, as Safari does.
///
/// Extension commands (manifest `commands`) don't come through here: `ExtensionHost` runs them before dispatch,
/// before the page sees the key, unless one of Paddle's menu items uses that key.
final class BrowserWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 48, event.modifierFlags.contains(.control),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paddleBack(_:)): return tab?.canGoBack ?? false
        case #selector(paddleForward(_:)): return tab?.canGoForward ?? false
        case #selector(paddleTogglePin(_:)):
            menuItem.title = tab?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil
        case #selector(paddleToggleMute(_:)):
            menuItem.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab != nil && Tab.supportsMuting
        case #selector(paddlePrint(_:)), #selector(paddleSavePage(_:)), #selector(paddleViewSource(_:)):
            return canActOnPage
        case #selector(paddleReload(_:)), #selector(paddleHardReload(_:)), #selector(paddleStop(_:)),
             #selector(paddleZoomIn(_:)), #selector(paddleZoomOut(_:)), #selector(paddleActualSize(_:)),
             #selector(paddleWebInspector(_:)):
            return webView != nil
        case #selector(paddleToggleBookmark(_:)):
            let bookmarked = AppModel.shared.bookmarks.isBookmarked(tab?.url)
            menuItem.title = bookmarked ? "Remove Bookmark" : "Bookmark This Page"
            return tab?.url.map(HistoryStore.isRecordable) ?? false
        case #selector(paddleSelectTab(_:)):
            return menuItem.tag == 9 ? !model.tabs.isEmpty : model.tabs.count >= menuItem.tag
        default:
            return true
        }
    }
}
