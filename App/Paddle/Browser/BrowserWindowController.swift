import AppKit
import PaddleCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One browser window. Menu commands reach it through the responder chain (it is the window's delegate),
/// so every action works whether the page or the address field has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserModel
    /// Ends address editing on a click outside the field and its suggestions (`endAddressEditing(after:)`).
    private var clickMonitor: Any?

    init(record: WindowRecord?, isPrivate: Bool = false, extensionsAllowed: Bool = true, profile: String = ProfileStore.defaultID) {
        model = BrowserModel(isPrivate: isPrivate, extensionsAllowed: extensionsAllowed, profile: profile)
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
        let host = NSHostingView(rootView: BrowserView(model: model, app: AppModel.shared))
        // The window's size is the user's (with `minSize` above), never the content's: by default the hosting view
        // makes the SwiftUI minimum a window constraint, and a Settings pane whose minimum height is its whole
        // content (the Sites pane's wrapped caption, measured at near-zero width) grew the window past the screen.
        host.sizingOptions = []
        window.contentView = host
        // The tab strip sits in the title bar, and the window server drags the window from anywhere in the title
        // bar, tabs and their close buttons included, so tab drag-reordering moved the window instead. Server-side
        // dragging is off; empty strip space (`WindowDragArea`) starts window drags itself.
        window.isMovable = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.endAddressEditing(after: event)
            self?.focusSplitSide(after: event)
            return event
        }

        if let record {
            if let frame = record.frame { window.setFrame(NSRectFromString(frame), display: false) }
            let isPrivate = isPrivate
            let model = model
            func restoredTabs(_ records: [TabRecord]) -> [Tab] {
                let tabs = records.map { Tab(record: $0, isPrivate: isPrivate) }
                // An old-format record has no lastActive; rank earlier tabs as more recent (1 s apart) so the history
                // cap doesn't favour the end of the strip.
                let now = Date()
                for (i, tab) in tabs.enumerated() where records[i].lastActive == nil {
                    tab.lastActive = now.addingTimeInterval(-Double(i + 1))
                }
                for tab in tabs { tab.browser = model }
                return tabs
            }
            if let space = record.space { model.restoreActiveSpace(space) }
            for other in record.otherSpaces { model.restoreSpace(other, tabs: restoredTabs(other.tabs)) }
            let tabs = restoredTabs(record.tabs)
            model.tabs.append(contentsOf: tabs)
            model.restoreGroups(record.groups)
            model.restoreSplits(record.allLayouts)
            let index = min(max(record.selectedIndex, 0), tabs.count - 1)
            if tabs.indices.contains(index) { model.select(tabs[index]) }
            model.finishRestore(activeSpaceIndex: record.spaceIndex)
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

    /// Gives the keyboard to the page: the link preview's while one shows, else the selected tab's.
    func focusWebView() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.renamingTabID == nil, self.model.renamingGroupID == nil else { return }
            let webView = self.model.preview?.webView ?? self.model.selectedTab?.webView
            if let webView, webView.window === self.window {
                self.window?.makeFirstResponder(webView)
            } else if self.window?.firstResponder is WKWebView {
                // The page stayed in the window under Settings. It must not keep the keyboard.
                self.window?.makeFirstResponder(nil)
            }
        }
    }

    /// A click in an unfocused pane of a multi view focuses it. The click goes on to the page; the selection changes
    /// on the next turn, so the page has already taken it.
    private func focusSplitSide(after event: NSEvent) {
        // The preview's card covers the panes; a click on it is for the preview.
        guard model.paneFrames.count > 1, model.preview == nil, let window, event.window === window, let root = window.contentView else { return }
        let local = root.convert(event.locationInWindow, from: nil)
        let point = root.isFlipped ? local : CGPoint(x: local.x, y: root.bounds.height - local.y)
        // The pane's bar has its own controls (× must not move the focus first); its address field focuses by itself.
        // A freeform card comes forward from a click anywhere on it (its bar is how it's moved).
        guard let (hit, frame) = model.pane(at: point), hit != model.selectedID,
              model.isFreeformShown || point.y > frame.minY + PaneMetrics.barHeight,
              let tab = model.tabs.first(where: { $0.id == hit }) else { return }
        DispatchQueue.main.async { [weak self] in self?.model.select(tab) }
    }

    /// A click outside the address field and its suggestions leaves the field, as a click on a web page does by
    /// taking the focus. Settings and Paddle's other SwiftUI pages don't take the focus, so the field kept it and
    /// its suggestions stayed open over them until Escape.
    private func endAddressEditing(after event: NSEvent) {
        guard let window, event.window === window, model.isEditingAddress, let root = window.contentView else { return }
        let local = root.convert(event.locationInWindow, from: nil)
        let point = root.isFlipped ? local : CGPoint(x: local.x, y: root.bounds.height - local.y)
        if model.addressFieldFrame.contains(point) { return }
        if model.suggestions.isVisible, model.suggestionsFrame.contains(point) { return }
        model.suggestions.dismiss()
        window.makeFirstResponder(nil)
    }

    /// `askBeforeClosingWindow`: a window with more than one tab (any space) asks in a sheet first. Quitting and the
    /// last tab closing (`close()`) don't come through here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = model.allTabs.count
        guard model.config.askBeforeClosingWindow, count > 1 else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this window and its \(count) tabs?"
        alert.informativeText = "Its tabs close with it."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        // The preview first, so extensions hear it closed while the window is still theirs.
        model.closePreview()
        model.extensionHost?.windowClosing(self)
        for tab in model.allTabs { tab.sleep() }
        AppModel.shared.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.selectedTab?.lastActive = Date()
        model.extensionHost?.windowFocused(self)
    }

    /// This window as WebKit's extension API sees it.
    lazy var extensionWindow = ExtensionWindow(controller: self)

    func windowDidResignKey(_ notification: Notification) {
        model.suggestions.dismiss()
    }

    var tab: Tab? { model.selectedTab }
    private var webView: WKWebView? { model.selectedTab?.webView }

    // MARK: - File

    @objc func paddleNewTab(_ sender: Any?) { model.newTabCommand() }
    @objc func paddleOpenLocation(_ sender: Any?) { model.focusAddress() }
    @objc func paddleCloseTab(_ sender: Any?) { if let tab { model.closeCommand(tab) } }
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

    /// File > Share…: standard macOS share sheet for the active page.
    @objc func paddleShare(_ sender: Any?) {
        guard let tab, let url = tab.url, let view = window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url, tab.title])
        let sourceView = (sender as? NSView) ?? view
        let rect = (sender as? NSView)?.bounds ?? NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: sourceView, preferredEdge: .minY)
    }

    /// Invoked by dynamic menu items in File > Share submenu.
    @objc func performSharingService(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService,
              let tab, let url = tab.url else { return }
        service.perform(withItems: [url, tab.title])
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

    /// File > Export as PDF…: exports the active page as a PDF file using WebKit's native PDF renderer.
    @objc func paddleExportPDF(_ sender: Any?) {
        guard canActOnPage, let tab, let webView, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.fileName(for: tab) + ".pdf"
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            let config = WKPDFConfiguration()
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: destination, options: .atomic)
                    } catch {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "The PDF couldn't be saved"
                        alert.informativeText = error.localizedDescription
                        alert.beginSheetModal(for: window) { _ in }
                    }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The PDF couldn't be exported"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    /// Opens the current PDF in macOS Preview.app.
    @objc func paddleOpenInPreview(_ sender: Any?) {
        guard let tab, let url = tab.url else { return }
        if url.isFileURL {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let filename = url.lastPathComponent.isEmpty ? (Self.fileName(for: tab) + ".pdf") : url.lastPathComponent
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                NSWorkspace.shared.open(destination)
            } catch {
                if let webView = tab.webView {
                    let config = WKPDFConfiguration()
                    webView.createPDF(configuration: config) { result in
                        if case .success(let data) = result {
                            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName(for: tab) + ".pdf")
                            try? data.write(to: destination)
                            NSWorkspace.shared.open(destination)
                        }
                    }
                }
            }
        }
    }

    /// View > Translate Page…: presents the translation popover for the active tab.
    @objc func paddleTranslatePage(_ sender: Any?) {
        guard canActOnPage, let tab else { return }
        tab.showTranslatePopover.toggle()
    }

    /// Edit > Copy Link to Highlight: copies a URL with a text fragment for the selected text.
    @objc func paddleCopyLinkToHighlight(_ sender: Any?) {
        guard let tab, let url = tab.url, let webView = tab.webView else { return }
        webView.evaluateJavaScript("window.getSelection().toString()", in: nil, in: .defaultClient) { result in
            guard case .success(let val) = result,
                  let text = val as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "-,")
            let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? clean
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.fragment = ":~:text=" + encoded
            if let fragmentURL = components.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fragmentURL.absoluteString, forType: .string)
                AccessibilityNotification.Announcement("Link to highlight copied").post()
            }
        }
    }

    /// Edit > Search with [Engine]…: searches for selected text in a new tab.
    @objc func paddleSearchSelectedText(_ sender: Any?) {
        guard let tab, let webView = tab.webView else { return }
        webView.evaluateJavaScript("window.getSelection().toString()", in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let val) = result,
                  let text = val as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let resolver = AddressResolver(searchTemplate: self.model.config.searchTemplate)
            if let searchURL = resolver.searchURL(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = self.model.newTab(url: searchURL, select: true, after: tab)
            }
        }
    }

    /// File > Create QR Code…: presents the QR code popover for the active tab.
    @objc func paddleCreateQRCode(_ sender: Any?) {
        guard let tab, tab.url != nil else { return }
        tab.showQRCodePopover.toggle()
    }

    /// A file name from the page title (or host), without characters Finder or the shell trip over.
    private static func fileName(for tab: Tab) -> String {
        let raw = tab.title.isEmpty ? (tab.url?.host() ?? "Page") : tab.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines)).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Page" : cleaned).prefix(120))
    }

    // MARK: - View

    @objc func paddleReload(_ sender: Any?) { model.selectedTab?.reload() }
    @objc func paddleHardReload(_ sender: Any?) { model.selectedTab?.reload(fromOrigin: true) }
    @objc func paddleStop(_ sender: Any?) { webView?.stopLoading() }
    // The zoom is remembered for the site (`Tab.setZoom`).
    /// Every pane of a Mosaic with `mosaicZoom` "all" (each from its own zoom), else the selected tab.
    @objc func paddleZoomIn(_ sender: Any?) { zoom { $0 + SitePolicy.zoomStep } }
    @objc func paddleZoomOut(_ sender: Any?) { zoom { $0 - SitePolicy.zoomStep } }
    /// Actual Size is the default zoom (`defaultZoom`), so it also resets sites that had their own zoom.
    @objc func paddleActualSize(_ sender: Any?) { zoom { _ in AppModel.shared.config.defaultZoom } }

    private func zoom(_ change: (Double) -> Double) {
        guard let tab else { return }
        for target in model.zoomTargets(for: tab) {
            guard let view = target.webView else { continue }
            target.setZoom(change(view.pageZoom))
        }
    }

    /// View > Show Downloads (⌥⌘L): the downloads popover, or the download folder when this window's list is empty.
    @objc func paddleShowDownloads(_ sender: Any?) {
        if AppModel.shared.downloads.items(forPrivateWindow: model.isPrivate).isEmpty {
            NSWorkspace.shared.open(DownloadStore.folder(using: model.config))
        } else {
            model.downloadsVisible = true
        }
    }

    @objc func paddleWebInspector(_ sender: Any?) {
        if let webView { WebInspector.show(webView) }
    }

    @objc func paddleJavaScriptConsole(_ sender: Any?) {
        if let webView { WebInspector.showConsole(webView) }
    }

    @objc func paddleElementSelection(_ sender: Any?) {
        if let webView { WebInspector.toggleElementSelection(webView) }
    }

    /// Reloads this once with the content blockers off; the next load blocks again.
    @objc func paddleReloadWithoutContentBlockers(_ sender: Any?) {
        let selector = NSSelectorFromString("_reloadWithoutContentBlockers")
        if let webView, webView.responds(to: selector) { _ = webView.perform(selector) }
    }

    /// Empties the memory, disk and fetch caches of this window's data store (the private store in a private window).
    /// Cookies, storage and history stay.
    @objc func paddleEmptyCaches(_ sender: Any?) {
        let store = webView?.configuration.websiteDataStore ?? (model.isPrivate ? nil : AppModel.shared.web.dataStore(for: model.profileID))
        guard let store else { return }
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        Task { await store.removeData(ofTypes: types, modifiedSince: .distantPast) }
    }

    /// Develop > Responsive Design Mode: draws the page at a device's size under a bar with the device controls.
    @objc func paddleToggleResponsiveDesignMode(_ sender: Any?) {
        guard canActOnPage, let tab else { return }
        tab.toggleResponsive()
    }

    @objc func paddleViewSource(_ sender: Any?) {
        guard canActOnPage, let tab else { return }
        Task { await model.viewSource(of: tab) }
    }

    /// View > Picture in Picture (⌃⌘P): pops any playing HTML5 video into a floating Picture-in-Picture window.
    @objc func paddleTogglePictureInPicture(_ sender: Any?) {
        guard canActOnPage, let tab else { return }
        tab.togglePictureInPicture()
    }

    /// View > Show Reader (⇧⌘R): toggles distraction-free Reader Mode for article pages.
    @objc func paddleToggleReaderMode(_ sender: Any?) {
        guard let tab else { return }
        tab.toggleReaderMode()
    }

    /// View > Dark Mode (⇧⌘D): toggles dark mode for the current tab's site.
    @objc func paddleToggleDarkMode(_ sender: Any?) {
        guard let tab else { return }
        model.toggleDarkMode(tab)
    }

    /// View > Invert Bright Text Images: toggles automatic inversion of bright text images in dark mode.
    @objc func paddleToggleInvertTextImages(_ sender: Any?) {
        Task {
            await AppModel.shared.toggleInvertTextImages()
        }
    }

    // MARK: - History

    @objc func paddleBack(_ sender: Any?) { webView?.goBack() }

    // MARK: - Bookmarks

    @objc func paddleToggleBookmark(_ sender: Any?) {
        guard let tab, let url = tab.url, HistoryStore.isRecordable(url) else { return }
        AppModel.shared.bookmarks.toggle(url: url, title: tab.title)
    }

    /// Bookmarks > Add Page to New Tab Page: pins the page as a tile, or removes its tile when it is pinned.
    @objc func paddleToggleNewTabSite(_ sender: Any?) {
        if let tab { Self.toggleNewTabSite(for: tab) }
    }

    /// Adds `tab`'s page to the New Tab page, or removes it when it is there: Bookmarks > Add Page to New Tab Page,
    /// and the page's right-click menu (`TabWebDelegate`). Nothing for private windows or pages history doesn't keep.
    static func toggleNewTabSite(for tab: Tab) {
        guard !tab.isPrivate, let url = tab.url, HistoryStore.isRecordable(url) else { return }
        let store = AppModel.shared.newTab
        if let id = store.id(forURL: HistoryStore.storedURL(url)) {
            store.remove(id)
        } else if !store.add(title: tab.displayTitle, url: HistoryStore.storedURL(url)) {
            NSSound.beep()
        }
    }
    @objc func paddleForward(_ sender: Any?) { webView?.goForward() }

    // MARK: - Find

    @objc func paddleFind(_ sender: Any?) { model.showFind() }
    /// With text to search for and the bar hidden, opens the bar and searches at once.
    @objc func paddleFindNext(_ sender: Any?) { findStep(backwards: false) }
    @objc func paddleFindPrevious(_ sender: Any?) { findStep(backwards: true) }

    private func findStep(backwards: Bool) {
        if model.findVisible {
            model.find(backwards: backwards)
        } else {
            model.showFind()
            if !model.findText.isEmpty { model.find(backwards: backwards) }
        }
    }

    /// Edit > Use Selection for Find (⌘E): the page's selected text becomes the search text and goes on the find
    /// pasteboard. Doesn't open the find bar.
    @objc func paddleUseSelectionForFind(_ sender: Any?) {
        guard let webView else { return }
        Task { @MainActor [weak self] in
            let result = try? await webView.callAsyncJavaScript(
                "return window.getSelection().toString()", arguments: [:], in: nil, contentWorld: .defaultClient
            )
            guard let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            let capped = String(text.prefix(1000))
            self?.model.findText = capped
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(capped, forType: .string)
        }
    }

    /// Edit > Jump to Selection (⌘J): scrolls the page's selection to the middle of the view.
    @objc func paddleJumpToSelection(_ sender: Any?) {
        guard let webView else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "const s = getSelection(); if (s.rangeCount) { const n = s.getRangeAt(0).startContainer; (n.nodeType === 1 ? n : n.parentElement)?.scrollIntoView({block: \"center\"}) }",
                arguments: [:], in: nil, contentWorld: .defaultClient
            )
        }
    }

    // MARK: - Tabs

    @objc func paddleNextTab(_ sender: Any?) { model.selectNeighbor(offset: 1) }
    @objc func paddlePreviousTab(_ sender: Any?) { model.selectNeighbor(offset: -1) }
    @objc func paddleTogglePin(_ sender: Any?) { if let tab { model.togglePin(tab) } }
    @objc func paddleDuplicateTab(_ sender: Any?) { if let tab { model.duplicate(tab) } }
    @objc func paddleCloseOtherTabs(_ sender: Any?) { if let tab { model.closeOthers(tab) } }
    @objc func paddleCloseTabsToTheRight(_ sender: Any?) { if let tab { model.closeTabsToTheRight(tab) } }
    @objc func paddleMuteOtherTabs(_ sender: Any?) { if let tab { model.muteOthers(tab) } }
    @objc func paddleRenameTab(_ sender: Any?) { if let tab { model.renamingTabID = tab.id } }
    @objc func paddleAddTabToNewGroup(_ sender: Any?) { if let tab, !tab.isPinned { model.addToNewGroup(tab) } }
    @objc func paddleRemoveTabFromGroup(_ sender: Any?) { if let tab { model.removeFromGroup(tab) } }
    @objc func paddleMoveTabLeft(_ sender: Any?) { model.moveSelectedTab(by: -1) }
    @objc func paddleMoveTabRight(_ sender: Any?) { model.moveSelectedTab(by: 1) }
    @objc func paddleToggleMute(_ sender: Any?) { if let tab { model.toggleMute(tab) } }
    @objc func paddleSearchTabs(_ sender: Any?) { model.tabSearchVisible.toggle() }
    @objc func paddleSleepBackgroundTabs(_ sender: Any?) { AppModel.shared.sleepBackgroundTabs() }

    // MARK: - Spaces

    @objc func paddleSelectSpace(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, model.spaces.indices.contains(item.tag - 1) else { return }
        model.switchToSpace(model.spaces[item.tag - 1].id)
    }
    @objc func paddleNextSpace(_ sender: Any?) { model.nextSpace(offset: 1) }
    @objc func paddlePreviousSpace(_ sender: Any?) { model.nextSpace(offset: -1) }
    @objc func paddleNewSpace(_ sender: Any?) {
        model.newSpace()
        model.editSpaceRequest += 1
    }
    @objc func paddleEditSpace(_ sender: Any?) { model.editSpaceRequest += 1 }

    // MARK: - Mosaic

    @objc func paddleToggleSplitView(_ sender: Any?) { model.toggleSplitView() }
    @objc func paddleSwapSplitSides(_ sender: Any?) { model.swapSplitSides() }
    @objc func paddleFocusOtherSplitSide(_ sender: Any?) { model.focusOtherSplitSide() }
    @objc func paddleFocusPaneLeft(_ sender: Any?) { model.focusPane(toward: .left) }
    @objc func paddleFocusPaneRight(_ sender: Any?) { model.focusPane(toward: .right) }
    @objc func paddleFocusPaneUp(_ sender: Any?) { model.focusPane(toward: .top) }
    @objc func paddleFocusPaneDown(_ sender: Any?) { model.focusPane(toward: .bottom) }
    @objc func paddleEvenOutPanes(_ sender: Any?) { model.equalizePanes() }
    @objc func paddleArrangeColumns(_ sender: Any?) { model.arrangeMosaic(.columns) }
    @objc func paddleArrangeRows(_ sender: Any?) { model.arrangeMosaic(.rows) }
    @objc func paddleArrangeGrid(_ sender: Any?) { model.arrangeMosaic(.grid) }
    @objc func paddleArrangeMainAndStack(_ sender: Any?) { model.arrangeMosaic(.mainAndStack) }
    @objc func paddleRotatePanes(_ sender: Any?) { model.rotatePanes() }
    @objc func paddleAddPane(_ sender: Any?) { model.addPaneToMosaic() }
    @objc func paddleReloadAllPanes(_ sender: Any?) { model.reloadAllPanes() }
    @objc func paddleZoomPane(_ sender: Any?) { model.toggleZoomPane() }
    @objc func paddleMovePaneLeft(_ sender: Any?) { model.movePane(toward: .left) }
    @objc func paddleMovePaneRight(_ sender: Any?) { model.movePane(toward: .right) }
    @objc func paddleMovePaneUp(_ sender: Any?) { model.movePane(toward: .top) }
    @objc func paddleMovePaneDown(_ sender: Any?) { model.movePane(toward: .bottom) }
    @objc func paddleMuteOtherPanes(_ sender: Any?) { model.muteOtherPanes() }
    @objc func paddleToggleFreeform(_ sender: Any?) { model.toggleFreeform() }
    @objc func paddleTidyUp(_ sender: Any?) { model.tidyUp() }
    @objc func paddleRemoveFromView(_ sender: Any?) { if let tab = model.selectedTab { model.removeFromView(tab) } }

    /// `screen` (a screen point) in the window's content view, top-left origin as SwiftUI's global frames; nil when
    /// the window has no content view.
    func contentPoint(fromScreen screen: NSPoint) -> CGPoint? {
        guard let window, let root = window.contentView else { return nil }
        let local = root.convert(window.convertPoint(fromScreen: screen), from: nil)
        return root.isFlipped ? local : CGPoint(x: local.x, y: root.bounds.height - local.y)
    }

    // MARK: - Link preview

    @objc func paddleOpenLinkPreviewAsTab(_ sender: Any?) { model.openPreviewAsTab(split: false) }
    @objc func paddleCloseLinkPreview(_ sender: Any?) { model.closePreview() }

    /// Escape closes the preview only when the page didn't use the key, so a site's dialogs keep Escape.
    /// No menu key and no key monitor — those would see the key before the page. WKWebView hands an
    /// unhandled key back to AppKit; NSWindow turns Escape into `cancelOperation:`. NSWindow's own
    /// `cancelOperation:` comes first in the chain, so `BrowserWindow` forwards both here first.
    @discardableResult
    func closePreviewOnEscape() -> Bool {
        guard model.preview != nil else { return false }
        model.closePreview()
        return true
    }

    override func cancelOperation(_ sender: Any?) { closePreviewOnEscape() }

    @objc func paddleMoveTabToSpace(_ sender: Any?) {
        guard let tab, let id = (sender as? NSMenuItem)?.representedObject as? String else { return }
        model.moveTab(tab, toSpace: id)
    }

    /// Tabs > Delete Space: the active space, after asking when it has tabs.
    @objc func paddleDeleteSpace(_ sender: Any?) { deleteActiveSpace() }

    /// Confirms, then deletes the active space. `completion` gets whether it was deleted.
    func deleteActiveSpace(completion: ((Bool) -> Void)? = nil) {
        guard model.spaces.count > 1 else { completion?(false); return }
        let space = model.activeSpace
        let count = model.tabs.count
        guard count > 0, let window else {
            model.deleteSpace(space.id)
            completion?(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete the space \(space.name)? Its \(count) \(count == 1 ? "tab closes" : "tabs close")."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { completion?(false); return }
            self?.model.deleteSpace(space.id)
            completion?(true)
        }
    }

    @objc func paddleSelectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if item.tag == 9 { model.selectLastTab() } else { model.select(index: item.tag - 1) }
    }

    override func noResponder(for eventSelector: Selector) {
        guard AppModel.shared.config(for: model.profileID).soundEffects else { return }
        super.noResponder(for: eventSelector)
    }
}

/// Side buttons (3 back, 4 forward) go back/forward on mouse-up, as in Chrome. The trackpad swipe
/// already does (`allowsBackForwardNavigationGestures`). Both down and up are swallowed so the page
/// doesn't react. Other buttons, middle-click included (the strip closes tabs with it), pass through.
///
/// Control shortcuts without Command go to the menu first, as Safari does; a focused web view would
/// keep them otherwise. Ctrl-Tab is AppKit's focus key (it jumped to the address field), and ⌃1–⌃9
/// never reached the Tabs menu while a page had focus. A control key no menu item uses (⌃A in a
/// field) still reaches the page.
///
/// Extension commands don't come through here: `ExtensionHost` runs them before dispatch, before the
/// page sees the key, unless a Paddle menu item uses that key.
final class BrowserWindow: NSWindow {
    private var allowsSoundEffects: Bool {
        (windowController as? BrowserWindowController).map {
            AppModel.shared.config(for: $0.model.profileID).soundEffects
        } ?? AppModel.shared.config.soundEffects
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown || event.type == .otherMouseUp, event.buttonNumber == 3 || event.buttonNumber == 4,
           let controller = windowController as? BrowserWindowController {
            if event.type == .otherMouseUp {
                // The link preview, while one shows, goes back and forward itself.
                if let preview = controller.model.preview {
                    if event.buttonNumber == 3, preview.canGoBack { preview.webView?.goBack() }
                    if event.buttonNumber == 4, preview.canGoForward { preview.webView?.goForward() }
                } else if event.buttonNumber == 3, controller.model.selectedTab?.canGoBack == true {
                    controller.paddleBack(nil)
                } else if event.buttonNumber == 4, controller.model.selectedTab?.canGoForward == true {
                    controller.paddleForward(nil)
                }
            }
            return
        }
        super.sendEvent(event)
    }

    /// An Escape the page didn't use, coming back up from the web view (`BrowserWindowController.closePreviewOnEscape`).
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        if event.keyCode == 53, flags.isEmpty, (windowController as? BrowserWindowController)?.closePreviewOnEscape() == true { return }
        super.keyDown(with: event)
    }

    /// The same Escape as an action; NSWindow's own `cancelOperation:` runs when no preview closed.
    override func cancelOperation(_ sender: Any?) {
        if (windowController as? BrowserWindowController)?.closePreviewOnEscape() == true { return }
        guard allowsSoundEffects else { return }
        super.cancelOperation(sender)
    }

    override func noResponder(for eventSelector: Selector) {
        guard allowsSoundEffects else { return }
        super.noResponder(for: eventSelector)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paddleToggleResponsiveDesignMode(_:)):
            menuItem.state = tab?.responsive != nil ? .on : .off
            return canActOnPage
        case #selector(paddleElementSelection(_:)):
            let active = webView.map(WebInspector.isElementSelectionActive) ?? false
            menuItem.title = active ? "Stop Element Selection" : "Start Element Selection"
            return webView != nil
        case #selector(paddleBack(_:)): return tab?.canGoBack ?? false
        case #selector(paddleForward(_:)): return tab?.canGoForward ?? false
        case #selector(paddleRenameTab(_:)): return tab != nil
        case #selector(paddleAddTabToNewGroup(_:)): return tab.map { !$0.isPinned } ?? false
        case #selector(paddleRemoveTabFromGroup(_:)): return tab?.groupID != nil
        case #selector(paddleTogglePin(_:)):
            menuItem.title = tab?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil
        case #selector(paddleToggleMute(_:)):
            menuItem.title = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return tab != nil && Tab.supportsMuting
        case #selector(paddleMuteOtherTabs(_:)):
            return Tab.supportsMuting && model.allTabs.count > 1
        case #selector(paddleCloseOtherTabs(_:)):
            return model.tabs.count > 1
        case #selector(paddleCloseTabsToTheRight(_:)):
            guard let tab, let idx = model.tabs.firstIndex(where: { $0 === tab }) else { return false }
            return idx < model.tabs.count - 1
        case #selector(paddleShare(_:)):
            return tab?.url != nil
        case #selector(paddleToggleReaderMode(_:)):
            menuItem.title = tab?.readerArticle != nil ? "Hide Reader" : "Show Reader"
            return tab != nil && (tab?.isReaderAvailable == true || tab?.readerArticle != nil)
        case #selector(paddleToggleDarkMode(_:)):
            guard let tab, tab.siteHost != nil else { return false }
            menuItem.state = tab.isDarkModeActive ? .on : .off
            return true
        case #selector(paddleToggleInvertTextImages(_:)):
            menuItem.state = AppModel.shared.config.invertTextImages ? .on : .off
            return true
        case #selector(paddlePrint(_:)), #selector(paddleSavePage(_:)), #selector(paddleExportPDF(_:)),
             #selector(paddleTranslatePage(_:)), #selector(paddleCopyLinkToHighlight(_:)),
             #selector(paddleSearchSelectedText(_:)), #selector(paddleCreateQRCode(_:)),
             #selector(paddleViewSource(_:)), #selector(paddleTogglePictureInPicture(_:)):
            return canActOnPage
        case #selector(paddleOpenInPreview(_:)):
            return tab?.isPDF == true || tab?.url?.pathExtension.lowercased() == "pdf"
        case #selector(paddleReload(_:)), #selector(paddleHardReload(_:)), #selector(paddleStop(_:)),
             #selector(paddleZoomIn(_:)), #selector(paddleZoomOut(_:)), #selector(paddleActualSize(_:)),
             #selector(paddleWebInspector(_:)), #selector(paddleJavaScriptConsole(_:)),
             #selector(paddleReloadWithoutContentBlockers(_:)), #selector(paddleEmptyCaches(_:)):
            return webView != nil
        case #selector(paddleToggleBookmark(_:)):
            let bookmarked = AppModel.shared.bookmarks.isBookmarked(tab?.url)
            menuItem.title = bookmarked ? "Remove Bookmark" : "Bookmark This Page"
            return tab?.url.map(HistoryStore.isRecordable) ?? false
        case #selector(paddleToggleNewTabSite(_:)):
            guard !model.isPrivate, let url = tab?.url, HistoryStore.isRecordable(url) else { return false }
            let pinned = AppModel.shared.newTab.contains(url: HistoryStore.storedURL(url))
            menuItem.title = pinned ? "Remove from New Tab Page" : "Add Page to New Tab Page"
            return pinned || AppModel.shared.newTab.sites.count < NewTabSites.maxSites
        case #selector(paddleFindNext(_:)), #selector(paddleFindPrevious(_:)),
             #selector(paddleUseSelectionForFind(_:)), #selector(paddleJumpToSelection(_:)):
            return tab?.settingsPane == nil && webView != nil
        case #selector(paddleMoveTabLeft(_:)): return model.canMoveSelectedTab(by: -1)
        case #selector(paddleMoveTabRight(_:)): return model.canMoveSelectedTab(by: 1)
        case #selector(paddleSelectSpace(_:)): return model.spaces.indices.contains(menuItem.tag - 1)
        case #selector(paddleNextSpace(_:)), #selector(paddlePreviousSpace(_:)): return model.spaces.count > 1
        case #selector(paddleDeleteSpace(_:)): return model.spaces.count > 1
        case #selector(paddleMoveTabToSpace(_:)): return tab != nil
        case #selector(paddleToggleSplitView(_:)):
            let split = tab.map { model.split(of: $0) != nil } ?? false
            menuItem.title = split ? "End Mosaic" : "Mosaic"
            return split || (tab.map { !$0.isPinned } ?? false)
        case #selector(paddleSwapSplitSides(_:)):
            return tab.flatMap { model.split(of: $0) }?.layout.count == 2
        case #selector(paddleFocusOtherSplitSide(_:)), #selector(paddleFocusPaneLeft(_:)), #selector(paddleFocusPaneRight(_:)),
             #selector(paddleFocusPaneUp(_:)), #selector(paddleFocusPaneDown(_:)), #selector(paddleEvenOutPanes(_:)),
             #selector(paddleRemoveFromView(_:)), #selector(paddleArrangeColumns(_:)), #selector(paddleArrangeRows(_:)),
             #selector(paddleArrangeGrid(_:)), #selector(paddleArrangeMainAndStack(_:)), #selector(paddleRotatePanes(_:)),
             #selector(paddleReloadAllPanes(_:)), #selector(paddleMovePaneLeft(_:)), #selector(paddleMovePaneRight(_:)),
             #selector(paddleMovePaneUp(_:)), #selector(paddleMovePaneDown(_:)), #selector(paddleMuteOtherPanes(_:)):
            return tab.map { model.split(of: $0) != nil } ?? false
        case #selector(paddleAddPane(_:)): return model.canAddPane
        case #selector(paddleToggleFreeform(_:)):
            menuItem.state = model.isFreeformShown ? .on : .off
            return tab.map { model.split(of: $0) != nil } ?? false
        case #selector(paddleTidyUp(_:)): return model.isFreeformShown
        case #selector(paddleZoomPane(_:)):
            let zoomed = tab.map { model.zoomedPaneID == $0.id } ?? false
            menuItem.title = zoomed ? "Unzoom Pane" : "Zoom Pane"
            return tab.map { model.split(of: $0) != nil } ?? false
        case #selector(paddleOpenLinkPreviewAsTab(_:)), #selector(paddleCloseLinkPreview(_:)):
            return model.preview != nil
        case #selector(paddleSelectTab(_:)):
            return menuItem.tag == 9 ? !model.tabs.isEmpty : model.tabs.count >= menuItem.tag
        default:
            return true
        }
    }
}
