import AppKit
import Foundation
import PaddleCore
import WebKit

/// The tabs and chrome state of one browser window.
@Observable
final class BrowserModel {
    /// A private window: non-persistent data store, no history, favicons, session or recently closed tabs.
    let isPrivate: Bool
    /// Extensions see this window and its web views carry the extension controller. Always for normal windows;
    /// private windows only when any extension may run in private windows (`anyExtensionInPrivate`), as it was when
    /// the window opened, until that is turned off.
    private(set) var extensionsAllowed: Bool

    init(isPrivate: Bool = false, extensionsAllowed: Bool = true) {
        self.isPrivate = isPrivate
        self.extensionsAllowed = extensionsAllowed
    }

    var tabs: [Tab] = []
    var selectedID: UUID?

    var addressText = ""
    var isEditingAddress = false
    /// Incremented to ask the view to focus the address field.
    var focusAddressRequest = 0

    /// The address-bar dropdown.
    let suggestions = AddressSuggestions()

    var findVisible = false
    var findText = ""
    var findFocusRequest = 0
    var findNoMatch = false

    @ObservationIgnored weak var controller: BrowserWindowController?
    @ObservationIgnored private var closedTabs: [TabRecord] = []

    /// Clear History also forgets recently closed tabs, which carry their own back/forward lists.
    func forgetClosedTabs() {
        closedTabs = []
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedID } }

    /// The window's title (hidden in the title bar; shown in the Window menu, Mission Control and the Dock).
    /// Private windows get a fixed title: window titles reach other apps (window server, Accessibility), and
    /// time trackers log them.
    var windowTitle: String {
        isPrivate ? "Private Window" : selectedTab?.displayTitle ?? "Paddle"
    }

    private var config: PaddleConfig { AppModel.shared.config }

    // MARK: - Opening and selecting

    /// A tab for `url`; with `anchor`, a link opened from that tab.
    @discardableResult
    func newTab(url: URL?, select: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(url: url, isPrivate: isPrivate)
        tab.opener = anchor
        tab.closesIfOnlyDownload = url != nil
        insert(tab, after: anchor, select: select)
        return tab
    }

    /// New tab from the "new tab" command: the configured new-tab page, or empty with the address field focused.
    func openNewTabPage() {
        let page = URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        newTab(url: page)
        if page == nil { focusAddress() }
    }

    func insert(_ tab: Tab, after anchor: Tab?, select: Bool) {
        tab.browser = self
        if let anchor, let index = tabs.firstIndex(where: { $0 === anchor }) {
            // Like Safari and Firefox: links open right after the tab that opened them.
            let slot = TabOrder.insertionIndex(
                after: index, isPinned: tab.isPinned, pinnedFlags: tabs.map(\.isPinned),
                openedFromAnchor: tabs.map { $0.opener === anchor }
            )
            tabs.insert(tab, at: slot)
        } else {
            tabs.append(tab)
        }
        AppModel.shared.extensions.tabOpened(tab)
        if select {
            self.select(tab)
        } else if tab.url != nil {
            // Background tabs load right away (the user asked for the page); the sweep keeps maxAwakeTabs.
            tab.wake()
            AppModel.shared.sweepSleepingTabs()
        }
        AppModel.shared.sessionChanged()
    }

    func select(_ tab: Tab) {
        let now = Date()
        let previous = selectedTab
        if let previous, previous !== tab {
            previous.lastActive = now
            // Once the user has moved on, closing a popup no longer jumps back to its opener (as in Chrome).
            previous.returnsToOpener = false
        }
        selectedID = tab.id
        tab.lastActive = now
        tab.wake()
        if previous !== tab { AppModel.shared.extensions.tabActivated(tab, previous: previous) }
        tab.resumeSelectionWaiters(true)
        suggestions.dismiss()
        if previous !== tab {
            // The field's text belonged to the old tab, typed or not: show this tab's address even while the field
            // keeps focus (⌘L then ⌘T, or closing a tab mid-edit), when `syncAddress` would leave it alone.
            addressText = tab.url.map(Self.displayString) ?? ""
        } else {
            syncAddress()
        }
        findNoMatch = false
        controller?.focusWebView()
        AppModel.shared.sessionChanged()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectLastTab() {
        if let last = tabs.last { select(last) }
    }

    func selectNeighbor(offset: Int) {
        guard let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }), !tabs.isEmpty else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    // MARK: - Closing

    /// - Parameters:
    ///   - remember: offer the tab in Reopen Closed Tab. Never for private windows or View Source tabs.
    ///   - returnToOpener: select the tab's opener next; by default only for a popup the user hasn't left.
    func close(_ tab: Tab, remember: Bool = true, returnToOpener: Bool? = nil) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if remember, !isPrivate, tab.sourceHTML == nil {
            closedTabs.append(tab.record)
            if closedTabs.count > 50 { closedTabs.removeFirst() }
        }
        let wasSelected = tab.id == selectedID
        tab.sleep()
        tabs.remove(at: index)
        AppModel.shared.extensions.tabClosed(tab, windowIsClosing: tabs.isEmpty)

        if tabs.isEmpty {
            selectedID = nil
            controller?.close()
            return
        }
        if wasSelected {
            if returnToOpener ?? tab.returnsToOpener, let opener = tab.opener, tabs.contains(where: { $0 === opener }) {
                select(opener)
            } else {
                select(tabs[min(index, tabs.count - 1)])
            }
        }
        AppModel.shared.sessionChanged()
    }

    func closeOthers(_ keep: Tab) {
        // Select first, so closing the selected tab doesn't wake neighbours that are about to close too.
        if keep.id != selectedID { select(keep) }
        for tab in tabs where tab !== keep && !tab.isPinned { close(tab) }
    }

    func reopenClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        insert(Tab(record: record, isPrivate: isPrivate), after: selectedTab, select: true)
    }

    @discardableResult
    func duplicate(_ tab: Tab) -> Tab {
        let copy = tab.sourceHTML.map { Tab(sourceHTML: $0, title: tab.title, isPrivate: isPrivate) }
            ?? Tab(record: Self.copied(tab.record), isPrivate: isPrivate)
        copy.setMuted(tab.isMuted)
        insert(copy, after: tab, select: true)
        return copy
    }

    /// A record for a second tab: without the session id, which names the original's state file.
    private static func copied(_ record: TabRecord) -> TabRecord {
        var record = record
        record.id = nil
        return record
    }

    /// No extension may run in private windows any more (`anyExtensionInPrivate` turned off) while this private
    /// window was open (the host has already been told it closed). Awake web views were made with the extension
    /// controller, so they are dropped; the selected tab comes back in an ordinary web view with its history, other
    /// tabs when next selected.
    func withdrawExtensions() {
        extensionsAllowed = false
        for tab in tabs where tab.isAwake { tab.sleep() }
        selectedTab?.wake()
    }

    // MARK: - Sound

    /// Tabs > Mute Tab, the tab strip's speaker and the tab context menu. Kept while the tab sleeps, not across
    /// relaunches.
    func toggleMute(_ tab: Tab) {
        tab.setMuted(!tab.isMuted)
    }

    // MARK: - View Source

    /// View > View Source: the page's current DOM, read from the open page in an isolated script world (no new
    /// request to the site), shown as escaped text in a new tab after this one.
    func viewSource(of tab: Tab) async {
        guard let webView = tab.webView else { return }
        let script = """
            const doctype = document.doctype ? new XMLSerializer().serializeToString(document.doctype) + "\\n" : "";
            return doctype + (document.documentElement ? document.documentElement.outerHTML : "");
            """
        let source: String
        do {
            source = (try await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String) ?? ""
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't show the source of this page"
            alert.informativeText = error.localizedDescription
            _ = await tab.present(alert)
            return
        }
        guard tabs.contains(where: { $0 === tab }) else { return }
        let pageURL = webView.url ?? tab.url
        let sourceTab = Tab(
            sourceHTML: ViewSource.page(source: source, url: pageURL), title: ViewSource.title(for: pageURL), isPrivate: isPrivate
        )
        sourceTab.opener = tab
        insert(sourceTab, after: tab, select: true)
    }

    // MARK: - Tab state

    func togglePin(_ tab: Tab) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.isPinned.toggle()
        tabs.remove(at: from)
        let to = TabOrder.pinBoundary(tabs.map(\.isPinned))
        tabs.insert(tab, at: to)
        let extensions = AppModel.shared.extensions
        extensions.tabChanged(tab, .pinned)
        if to != from { extensions.tabMoved(tab, from: from) }
        AppModel.shared.sessionChanged()
    }

    /// An extension asked for a tab at `index` (`tabs.create`, `tabs.move`). Clamped to the tab's side of the
    /// pinned boundary.
    func place(_ tab: Tab, at index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        var others = tabs
        others.remove(at: from)
        let boundary = TabOrder.pinBoundary(others.map(\.isPinned))
        let to = tab.isPinned ? min(max(index, 0), boundary) : min(max(index, boundary), others.count)
        guard to != from else { return }
        others.insert(tab, at: to)
        tabs = others
        AppModel.shared.extensions.tabMoved(tab, from: from)
        AppModel.shared.sessionChanged()
    }

    func sleep(_ tab: Tab) {
        guard tab.id != selectedID else { return }
        tab.sleep()
    }

    /// Drag and drop in the tab strip. Tabs can't cross the pinned/unpinned boundary.
    /// Returns false when the drop is refused, so the drag animates back.
    @discardableResult
    func move(_ tab: Tab, onto target: Tab) -> Bool {
        guard tab !== target, tab.isPinned == target.isPinned,
              let from = tabs.firstIndex(where: { $0 === tab }),
              let to = tabs.firstIndex(where: { $0 === target }) else { return false }
        TabOrder.move(&tabs, from: from, onto: to)
        AppModel.shared.extensions.tabMoved(tab, from: from)
        AppModel.shared.sessionChanged()
        return true
    }

    // MARK: - Moving between windows (`AppModel.move`)

    /// Takes `tab` out for another window. It keeps its web view, history and state. A selected tab hands the
    /// selection to its neighbour; a window left empty stays open for the caller to close once the tab has arrived.
    /// Returns the tab's old index.
    func detach(_ tab: Tab) -> Int? {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return nil }
        let wasSelected = tab.id == selectedID
        tabs.remove(at: index)
        if wasSelected {
            if tabs.isEmpty { selectedID = nil } else { select(tabs[min(index, tabs.count - 1)]) }
        }
        return index
    }

    /// Puts a tab from another window at `index`, clamped to its side of the pinned boundary. Not selected.
    func adopt(_ tab: Tab, at index: Int) {
        tab.browser = self
        tab.returnsToOpener = false
        if let opener = tab.opener, !tabs.contains(where: { $0 === opener }) { tab.opener = nil }
        let boundary = TabOrder.pinBoundary(tabs.map(\.isPinned))
        let to = tab.isPinned ? min(max(index, 0), boundary) : min(max(index, boundary), tabs.count)
        tabs.insert(tab, at: to)
    }

    // MARK: - Navigation

    /// Return in the address field: the highlighted suggestion, or what was typed.
    func submitAddress() {
        if suggestions.highlighted > 0, let row = suggestions.highlightedRow {
            open(row)
        } else {
            navigate(addressText)
        }
    }

    func navigate(_ input: String) {
        if let link = SettingsLink.parse(input) {
            openSettings(link)
            return
        }
        guard let url = AddressResolver(searchTemplate: config.searchTemplate).resolve(input) else { return }
        go(to: url, typed: true)
    }

    /// A settings address typed into the field: Settings opens (on its pane) and the field shows the tab's page again.
    private func openSettings(_ link: SettingsLink) {
        SettingsWindowController.show(pane: link.pane.flatMap { SettingsPane(rawValue: $0.rawValue) })
        suggestions.dismiss()
        isEditingAddress = false
        // Leave the field too (as picking an open tab does), or it stays in edit mode when this window is key again.
        controller?.window?.makeFirstResponder(nil)
        syncAddress()
    }

    /// Loads `url` in the selected tab (a new one if there is none).
    func go(to url: URL, typed: Bool) {
        let tab = selectedTab ?? newTab(url: nil)
        // Typed by the user: keep the tab even if the URL turns out to be a download.
        tab.closesIfOnlyDownload = false
        tab.typedNavigationPending = typed
        tab.skipNextCommitInHistory = false
        tab.load(url)
        tab.wake()
        suggestions.dismiss()
        isEditingAddress = false
        addressText = Self.displayString(url)
        controller?.focusWebView()
    }

    /// A row picked in the address-bar dropdown. Picking counts as typing for history ranking.
    func open(_ suggestion: Suggestion) {
        // The typed row (search or address) is what Return navigates to, so a settings address there opens Settings.
        if suggestion.kind == .search || suggestion.kind == .url,
           let link = SettingsLink.parse(suggestion.query ?? suggestion.url ?? "") {
            openSettings(link)
            return
        }
        switch suggestion.kind {
        case .openTab(let id):
            suggestions.dismiss()
            isEditingAddress = false
            // Leave the field here too, in case the tab is in another window.
            controller?.window?.makeFirstResponder(nil)
            guard let window = AppModel.shared.windows.first(where: { $0.model.tabs.contains { $0.id == id } }),
                  let tab = window.model.tabs.first(where: { $0.id == id }) else { return }
            syncAddress()
            window.model.select(tab)
            window.window?.makeKeyAndOrderFront(nil)
        case .search:
            if let query = suggestion.query, let url = AddressResolver(searchTemplate: config.searchTemplate).searchURL(for: query) {
                go(to: url, typed: true)
            }
        case .history, .bookmark, .url:
            if let string = suggestion.url, let url = URL(string: string) { go(to: url, typed: true) }
        }
    }

    /// The user edited the address text: refresh suggestions and, when they typed at the end, complete a known
    /// host inline (Safari style). Returns the completed text and where the typed part ends, or nil.
    func addressEdited(from old: String, to new: String) -> (text: String, typedEnd: String.Index)? {
        guard isEditingAddress else { return nil }
        let typed = suggestions.typedText
        suggestions.update(for: new, in: self)
        // Only one key added to what was typed (typing over a shown completion counts), or a first key replacing
        // the whole field: not a paste, a deletion, or IME text still being composed.
        let composing = (controller?.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        let oneKey = new.count == 1 || (new.count == typed.count + 1 && new.hasPrefix(typed))
        guard !composing, oneKey,
              let completion = suggestions.inlineCompletion(for: new),
              completion.count > new.count, completion.lowercased().hasPrefix(new.lowercased()) else { return nil }
        let text = new + completion.dropFirst(new.count)
        suggestions.completionApplied(text)
        return (text, text.index(text.startIndex, offsetBy: new.count))
    }

    func tabURLChanged(_ tab: Tab) {
        if tab.id == selectedID { syncAddress() }
        AppModel.shared.extensions.tabChanged(tab, .URL)
        AppModel.shared.sessionChanged()
    }

    func syncAddress() {
        guard !isEditingAddress else { return }
        addressText = selectedTab?.url.map(Self.displayString) ?? ""
    }

    func focusAddress() {
        focusAddressRequest += 1
    }

    static func displayString(_ url: URL) -> String {
        url.absoluteString == "about:blank" ? "" : url.absoluteString
    }

    // MARK: - Find

    func showFind() {
        findVisible = true
        findFocusRequest += 1
    }

    func hideFind() {
        findVisible = false
        findNoMatch = false
        controller?.focusWebView()
    }

    func find(backwards: Bool = false) {
        guard let webView = selectedTab?.webView, !findText.isEmpty else {
            findNoMatch = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(findText, configuration: configuration) { [weak self] result in
            self?.findNoMatch = !result.matchFound
        }
    }

    // MARK: - Session

    /// This window for session.json, without View Source tabs. Private windows are never saved (`AppModel`).
    var record: WindowRecord {
        WindowRecord.saving(
            tabs, selected: { $0.id == self.selectedID }, isSaved: { $0.sourceHTML == nil }, record: \.record,
            frame: controller?.window.map { NSStringFromRect($0.frame) }
        )
    }
}
