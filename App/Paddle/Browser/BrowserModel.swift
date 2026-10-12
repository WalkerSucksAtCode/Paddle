import AppKit
import Foundation
import PaddleCore
import WebKit

/// The tabs and chrome state of one browser window.
@Observable
final class BrowserModel {
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

    private var config: PaddleConfig { AppModel.shared.config }

    // MARK: - Opening and selecting

    /// A tab for `url`; with `anchor`, a link opened from that tab.
    @discardableResult
    func newTab(url: URL?, select: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(url: url)
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
        syncAddress()
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
    ///   - remember: offer the tab in Reopen Closed Tab.
    ///   - returnToOpener: select the tab's opener next; by default only for a popup the user hasn't left.
    func close(_ tab: Tab, remember: Bool = true, returnToOpener: Bool? = nil) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if remember {
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
        insert(Tab(record: record), after: selectedTab, select: true)
    }

    @discardableResult
    func duplicate(_ tab: Tab) -> Tab {
        let copy = Tab(record: tab.record)
        insert(copy, after: tab, select: true)
        return copy
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
        guard let url = AddressResolver(searchTemplate: config.searchTemplate).resolve(input) else { return }
        go(to: url, typed: true)
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

    var record: WindowRecord {
        WindowRecord(
            tabs: tabs.map(\.record),
            selectedIndex: tabs.firstIndex { $0.id == selectedID } ?? 0,
            frame: controller?.window.map { NSStringFromRect($0.frame) }
        )
    }
}
