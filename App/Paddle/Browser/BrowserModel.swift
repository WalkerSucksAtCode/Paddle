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

    var findVisible = false
    var findText = ""
    var findFocusRequest = 0
    var findNoMatch = false

    @ObservationIgnored weak var controller: BrowserWindowController?
    @ObservationIgnored private var closedTabs: [TabRecord] = []

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
        if let previous = selectedTab, previous !== tab {
            previous.lastActive = now
            // Once the user has moved on, closing a popup no longer jumps back to its opener (as in Chrome).
            previous.returnsToOpener = false
        }
        selectedID = tab.id
        tab.lastActive = now
        tab.wake()
        tab.resumeSelectionWaiters(true)
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

    func duplicate(_ tab: Tab) {
        insert(Tab(record: tab.record), after: tab, select: true)
    }

    // MARK: - Tab state

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        tabs.removeAll { $0 === tab }
        tabs.insert(tab, at: TabOrder.pinBoundary(tabs.map(\.isPinned)))
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
        AppModel.shared.sessionChanged()
        return true
    }

    // MARK: - Navigation

    func navigate(_ input: String) {
        guard let url = AddressResolver(searchTemplate: config.searchTemplate).resolve(input) else { return }
        let tab = selectedTab ?? newTab(url: nil)
        // Typed by the user: keep the tab even if the URL turns out to be a download.
        tab.closesIfOnlyDownload = false
        tab.load(url)
        tab.wake()
        isEditingAddress = false
        addressText = Self.displayString(url)
        controller?.focusWebView()
    }

    func tabURLChanged(_ tab: Tab) {
        if tab.id == selectedID { syncAddress() }
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
