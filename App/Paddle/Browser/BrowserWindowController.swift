import AppKit
import PaddleCore
import SwiftUI
import WebKit

/// One browser window. Menu commands reach it through the responder chain (it is the window's delegate),
/// so every action works whether the page or the address field has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model = BrowserModel()

    init(record: WindowRecord?) {
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
            let tabs = record.tabs.map(Tab.init(record:))
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
        for tab in model.tabs { tab.sleep() }
        AppModel.shared.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.selectedTab?.lastActive = Date()
    }

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

    // MARK: - View

    @objc func paddleReload(_ sender: Any?) { webView?.reload() }
    @objc func paddleHardReload(_ sender: Any?) { webView?.reloadFromOrigin() }
    @objc func paddleStop(_ sender: Any?) { webView?.stopLoading() }
    @objc func paddleZoomIn(_ sender: Any?) { if let webView { webView.pageZoom = min(webView.pageZoom + 0.1, 3) } }
    @objc func paddleZoomOut(_ sender: Any?) { if let webView { webView.pageZoom = max(webView.pageZoom - 0.1, 0.3) } }
    @objc func paddleActualSize(_ sender: Any?) { webView?.pageZoom = 1 }

    @objc func paddleWebInspector(_ sender: Any?) {
        // `_inspector` is private WebKit API (personal build); does nothing if it ever goes away.
        guard let webView, webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return }
        inspector.perform(NSSelectorFromString("show"))
    }

    // MARK: - History

    @objc func paddleBack(_ sender: Any?) { webView?.goBack() }
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
    @objc func paddleSleepBackgroundTabs(_ sender: Any?) { AppModel.shared.sleepBackgroundTabs() }

    @objc func paddleSelectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if item.tag == 9 { model.selectLastTab() } else { model.select(index: item.tag - 1) }
    }
}

/// Ctrl-Tab is AppKit's keyboard-focus key: a focused web view passes it on to the key view loop, so the
/// Tabs menu never saw it and focus jumped to the address field instead. Offer it to the menu first, as Safari does.
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
        case #selector(paddleReload(_:)), #selector(paddleHardReload(_:)), #selector(paddleStop(_:)),
             #selector(paddleZoomIn(_:)), #selector(paddleZoomOut(_:)), #selector(paddleActualSize(_:)),
             #selector(paddleWebInspector(_:)):
            return webView != nil
        case #selector(paddleSelectTab(_:)):
            return menuItem.tag == 9 ? !model.tabs.isEmpty : model.tabs.count >= menuItem.tag
        default:
            return true
        }
    }
}
