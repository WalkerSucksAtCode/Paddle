import AppKit
import Foundation
import os
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

    /// The window's profile (`ProfileStore`): its data store, history and extensions. Private windows are always the
    /// default profile's id; they ignore it.
    let profileID: String

    /// The window's id for the control bridge (`ControlBridge`); new each launch.
    let id = UUID()

    init(isPrivate: Bool = false, extensionsAllowed: Bool = true, profile: String = ProfileStore.defaultID) {
        self.isPrivate = isPrivate
        self.profileID = isPrivate ? ProfileStore.defaultID : profile
        self.extensionsAllowed = extensionsAllowed
        self.activeSpaceID = spaces[0].id
    }

    /// The active space's tabs. The other spaces' are in `stashes`; `allTabs` has every one.
    var tabs: [Tab] = []
    var selectedID: UUID?
    /// The web page selected before `selectedID`, kept mounted beside it so switching back is instant. A tab that
    /// draws no web page (Settings, New Tab, reader) doesn't take the slot, so the page before it stays.
    private(set) var previousSelectedID: UUID?
    /// An awake tab the pointer is resting on in the tab strip or sidebar. Its page is mounted (transparent) ahead of
    /// the click, so WebKit has painted it by the time the click selects it (measured: a detached page otherwise
    /// takes 33-118 ms to show).
    private(set) var hoveredTabID: UUID?
    @ObservationIgnored private var hoverWork: DispatchWorkItem?
    /// The active space's tab groups. Each group's tabs are adjacent in `tabs`, and a group with no tabs is removed.
    var groups: [TabGroup] = []
    /// The active space's multi views. Each one's tabs are adjacent in the strip, in one group (or none);
    /// `normalizeSplits` takes out the tabs a change breaks away.
    private(set) var splits: [Split] = []

    /// The window's spaces in order, the active one included. A window starts with one, "Main".
    private(set) var spaces: [Space] = [Space()]
    private(set) var activeSpaceID = ""
    /// Incremented to ask the view to open the Edit Space popover for the active space.
    var editSpaceRequest = 0

    /// What an inactive space keeps while another is shown.
    private struct Stash {
        var tabs: [Tab] = []
        var groups: [TabGroup] = []
        var selectedID: UUID?
        var splits: [Split] = []
    }
    private var stashes: [String: Stash] = [:]
    /// The tab whose title is being edited in place in the strip.
    var renamingTabID: UUID?
    /// The group whose label in the strip is a text field.
    var renamingGroupID: UUID?

    var addressText = ""
    /// Text Paddle itself put in the address field while it is being edited (the new tab's address after a tab
    /// switch): the field's change handler would take it for typing and open the suggestions. Consumed by that change.
    @ObservationIgnored private var addressWrittenByPaddle: String?
    var isEditingAddress = false
    /// Where the address field and its suggestion list are, in the window's SwiftUI coordinates (top-left
    /// origin), for `BrowserWindowController`'s click-outside check.
    @ObservationIgnored var addressFieldFrame: CGRect = .zero
    @ObservationIgnored var suggestionsFrame: CGRect = .zero
    /// Incremented to ask the view to focus the address field.
    var focusAddressRequest = 0
    /// Bumped by Find… on a Settings tab: the Settings search field takes focus and selects its text.
    var settingsSearchFocusRequest = 0

    let suggestions = AddressSuggestions()

    /// Search Tabs… (Shift-Cmd-A): the popover on the tab strip.
    var tabSearchVisible = false

    /// The toolbar's downloads popover is open (Show Downloads, the toolbar button and the menu button drive it).
    var downloadsVisible = false

    /// While a tab is dragged over this window's tabs: the slot in `tabs` it would land in, drawn as an insertion bar
    /// (`TabDragController`).
    var tabDropIndex: Int?

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

    // MARK: - Speculative loading

    @ObservationIgnored private var preconnects = PreconnectPolicy()
    private static let preconnectSelector = NSSelectorFromString("_preconnectToServer:")

    /// Opens a connection to `url`'s site ahead of the click or Return (`speculativeLoading`): DNS, TCP and TLS, no
    /// request. Through one of this window's web pages, so it uses the window's data store. Never in a private
    /// window; a no-op where WebKit lacks the private call or the site was warmed moments ago.
    func preconnect(to url: URL?) {
        guard !isPrivate, AppModel.shared.config.speculativeLoading else { return }
        let pages = [selectedTab].compactMap { $0 } + allTabs
        guard let webView = pages.lazy.filter({ $0.extensionPageID == nil }).compactMap(\.webView).first,
              webView.responds(to: Self.preconnectSelector),
              let origin = preconnects.originToWarm(url) else { return }
        webView.perform(Self.preconnectSelector, with: origin)
        Self.speculativeLog.info("preconnect \(origin.absoluteString, privacy: .private)")
    }

    private static let speculativeLog = Logger(subsystem: "com.walker.Paddle", category: "web")

    /// Pages kept in the window: the selected tab's, the web page selected before it, an awake tab the pointer rests
    /// on (`hoveredTabID`, not inside a collapsed group) and the tab closing the selected one would show
    /// (`closeSuccessorID`), so each of those switches is an opacity flip of a page WebKit has already painted.
    /// Every other page is detached, so WebKit treats it as hidden and throttles it (measured with 8 tabs: the
    /// app's CPU 61% -> 25%).
    /// With `mosaicStaysReady`, every pane of the Mosaic the previous tab is in counts as the previous tab: leaving a
    /// Mosaic for another tab keeps all its pages attached, so none of them is told it was hidden (X refreshed its
    /// timeline on the way back) and going back is an opacity flip for each.
    var mountedWebTabs: [Tab] {
        let successor = closeSuccessorID
        let readyMosaic: Set<UUID> = {
            guard config.mosaicStaysReady, let previous = previousSelectedID, let tab = tabs.first(where: { $0.id == previous }),
                  let split = split(of: tab) else { return [] }
            return Set(split.tabIDs)
        }()
        return tabs.filter { tab in
            let hovered = tab.id == hoveredTabID && group(of: tab)?.isCollapsed != true
            return (tab.id == selectedID || tab.id == previousSelectedID || readyMosaic.contains(tab.id) || hovered || tab.id == successor)
                && tab.hostsWebView && tab.webView != nil
        }
    }

    /// The Mosaic `tab` is a pane of, in any space of this window (the sleep sweep's `TabSnapshot.mosaic`).
    func mosaicID(of tab: Tab) -> UUID? {
        if let split = split(of: tab) { return split.id }
        return stashes.values.lazy.flatMap(\.splits).first { $0.contains(tab) }?.id
    }

    /// The tab `close` would select if the selected tab closed now (Cmd-W): its opener when closing returns there,
    /// else the nearest visible tab on the right (on the left for the last tab).
    private var closeSuccessorID: UUID? {
        guard let selected = selectedTab, let index = tabs.firstIndex(where: { $0 === selected }), tabs.count > 1 else { return nil }
        if selected.returnsToOpener, let opener = selected.opener, opener !== selected, tabs.contains(where: { $0 === opener }) {
            return opener.id
        }
        var rest = tabs
        rest.remove(at: index)
        let target = min(index, rest.count - 1)
        let visible = rest.indices.filter { group(of: rest[$0])?.isCollapsed != true }
        return (visible.min { abs($0 - target) < abs($1 - target) }.map { rest[$0] } ?? rest[target]).id
    }

    /// The pointer entered (`inside`) or left a tab in the strip or sidebar. After a short rest the tab's page is
    /// mounted ahead of a click; passing over tabs on the way elsewhere mounts nothing.
    func pointerRests(on tab: Tab, _ inside: Bool) {
        hoverWork?.cancel()
        hoverWork = nil
        guard inside else {
            if hoveredTabID == tab.id { hoveredTabID = nil }
            return
        }
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab.webView != nil, tab.id != self.selectedID else { return }
            self.hoveredTabID = tab.id
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Every tab of the window, in space order: the active space's and the stashed ones.
    var allTabs: [Tab] {
        spaces.flatMap { $0.id == activeSpaceID ? tabs : (stashes[$0.id]?.tabs ?? []) }
    }

    /// How many tabs sit in the spaces before `id`: what turns an index within that space into an `allTabs` index,
    /// the index space extensions see.
    private func tabOffset(ofSpace id: String) -> Int {
        var count = 0
        for space in spaces {
            if space.id == id { break }
            count += space.id == activeSpaceID ? tabs.count : (stashes[space.id]?.tabs.count ?? 0)
        }
        return count
    }

    var activeSpace: Space { spaces.first { $0.id == activeSpaceID } ?? spaces[0] }

    /// The tab "Current Page" and "Add Current Site" mean: the selected tab when it shows a page with one of
    /// `schemes`, else the most recently active tab that does. The selected one comes first because switching tabs
    /// stamps the old and new tab with the same time. With Settings selected, that is the page before it.
    func currentPageTab(schemes: Set<String>) -> Tab? {
        func showsPage(_ tab: Tab) -> Bool {
            guard let scheme = tab.url?.scheme?.lowercased() else { return false }
            return schemes.contains(scheme)
        }
        if let selected = selectedTab, showsPage(selected) { return selected }
        return tabs.filter(showsPage).max { $0.lastActive < $1.lastActive }
    }

    /// The window's title (hidden in the title bar; shown in the Window menu, Mission Control and the Dock).
    /// Private windows get a fixed title: window titles reach other apps (window server, Accessibility), and
    /// time trackers log them.
    var windowTitle: String {
        isPrivate ? "Private Window" : selectedTab?.displayTitle ?? "Paddle"
    }

    /// This window's profile's config (`AppModel.config(for:)`).
    var config: PaddleConfig { AppModel.shared.config(for: profileID) }

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
    /// `newTabPosition` afterCurrent puts it right after the selected tab (not as a link from it: no opener). An
    /// extension's New Tab page (`newTabExtension`) wins over `newTabPage`.
    func openNewTabPage() {
        let override = AppModel.shared.newTabOverrideURL(for: self)
        let page = override ?? URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        if config.newTabPosition == .afterCurrent, let current = selectedTab {
            let tab = Tab(url: page, isPrivate: isPrivate)
            insert(tab, after: current, select: true)
        } else {
            newTab(url: page)
        }
        if page == nil || override != nil { focusAddress() }
    }

    /// `announce` false: extensions already know the tab (the link preview becoming one), so no tab-opened event.
    func insert(_ tab: Tab, after anchor: Tab?, select: Bool, announce: Bool = true) {
        tab.browser = self
        var select = select
        // A link from a tab of a hidden space lands in that space, behind the scenes.
        if let anchor, !tabs.contains(where: { $0 === anchor }), let home = stashedSpace(of: anchor) {
            withSpace(home.id) { place(tab, after: anchor) }
            select = false
        } else {
            place(tab, after: anchor)
        }
        if announce { extensionHost?.tabOpened(tab) }
        if select {
            self.select(tab)
        } else if tab.url != nil {
            // Background tabs load right away (the user asked for the page); the sweep keeps maxAwakeTabs.
            tab.wake()
            AppModel.shared.sweepSleepingTabs()
        }
        AppModel.shared.sessionChanged()
    }

    /// Puts `tab` in the current `tabs`: after `anchor` when it is there, else at the end.
    private func place(_ tab: Tab, after anchor: Tab?) {
        if let anchor, let index = tabs.firstIndex(where: { $0 === anchor }) {
            // Like Safari and Firefox: links open right after the tab that opened them.
            var slot = TabOrder.insertionIndex(
                after: index, isPinned: tab.isPinned, pinnedFlags: tabs.map(\.isPinned),
                openedFromAnchor: tabs.map { $0.opener === anchor }
            )
            // A link from the left side of a split lands after the pair, not between its tabs.
            slot = outsideSplits(slot, in: tabs, moving: tab)
            // A tab opened from a grouped tab lands in its group.
            if let group = TabGroups.groupForInsertion(after: index, slots: groupSlots) { tab.groupID = UUID(uuidString: group) }
            tabs.insert(tab, at: slot)
        } else {
            tabs.append(tab)
        }
        normalizeGroups()
    }

    /// `index` (an insertion point in `list`) moved out of the middle of any multi view `tab` isn't part of, to just
    /// after its tabs.
    private func outsideSplits(_ index: Int, in list: [Tab], moving tab: Tab) -> Int {
        guard split(of: tab) == nil else { return index }
        var index = index
        for view in splits {
            let members = Set(view.tabIDs)
            let spots = list.indices.filter { members.contains(list[$0].id) }
            guard let l = spots.min(), let r = spots.max(), index > l, index <= r else { continue }
            index = r + 1
        }
        return index
    }

    /// `focusPage` false leaves the keyboard where it is (a pane's address field taking a click).
    func select(_ tab: Tab, focusPage: Bool = true) {
        // A tab of another space: show that space first.
        if !tabs.contains(where: { $0 === tab }), let home = stashedSpace(of: tab) {
            switchToSpace(home.id, selecting: tab)
            return
        }
        activate(tab, previous: selectedTab, focusPage: focusPage)
    }

    private func activate(_ tab: Tab, previous: Tab?, focusPage: Bool = true) {
        // Selecting any tab but the one under the preview closes it (another tab, a space switch, a popup).
        if preview != nil, tab !== previewSource { closePreview() }
        // A zoomed pane gives the Mosaic back when another tab is focused.
        if let zoomed = zoomedPaneID, zoomed != tab.id { zoomedPaneID = nil }
        let now = Date()
        if let previous, previous !== tab {
            previous.lastActive = now
            previous.hoveredLink = nil
            // Once the user has moved on, closing a popup no longer jumps back to its opener (as in Chrome).
            previous.returnsToOpener = false
        }
        if previous !== tab, let previous, previous.hostsWebView, previous.webView != nil { previousSelectedID = previous.id }
        hoverWork?.cancel()
        hoveredTabID = nil
        selectedID = tab.id
        if let group = group(of: tab), group.isCollapsed { group.isCollapsed = false }
        tab.lastActive = now
        let state = tab.webView == nil ? "cold: page created" : tab.isFrozen ? "frozen: resumed" : "live"
        tab.wake()
        // The other panes of a multi view are on screen too.
        for other in others(of: tab) {
            other.lastActive = now
            other.wake()
        }
        applyMosaicSound(focused: tab)
        // A freeform card that is focused comes to the front.
        if let split = split(of: tab), split.layout.isFreeform, let at = splits.firstIndex(where: { $0.id == split.id }) {
            splits[at].layout.bringToFront(tab.id.uuidString)
        }
        if previous !== tab { extensionHost?.tabActivated(tab, previous: previous) }
        tab.resumeSelectionWaiters(true)
        suggestions.dismiss()
        if previous !== tab {
            // The field's text belonged to the old tab, typed or not: show this tab's address even while the field
            // keeps focus (⌘L then ⌘T, or closing a tab mid-edit), when `syncAddress` would leave it alone.
            let address = tab.url.map(Self.displayString) ?? ""
            if isEditingAddress, address != addressText { addressWrittenByPaddle = address }
            addressText = address
        } else {
            syncAddress()
        }
        findNoMatch = false
        if focusPage { controller?.focusWebView() }
        AppModel.shared.sessionChanged()
        if previous !== tab { SwitchTrace.activated(tab, state: state) }
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
        // Tabs of collapsed groups aren't in the strip, so they are skipped.
        for step in 1...tabs.count {
            let candidate = tabs[((index + offset * step) % tabs.count + tabs.count) % tabs.count]
            if group(of: candidate)?.isCollapsed != true {
                select(candidate)
                return
            }
        }
    }

    // MARK: - Closing

    /// - Parameters:
    ///   - remember: offer the tab in Reopen Closed Tab. Never for private windows or View Source tabs.
    ///   - returnToOpener: select the tab's opener next; by default only for a popup the user hasn't left.
    func close(_ tab: Tab, remember: Bool = true, returnToOpener: Bool? = nil) {
        if tab === previewSource { closePreview() }
        guard let index = tabs.firstIndex(where: { $0 === tab }) else {
            // A tab of a hidden space closes there, without changing what is shown.
            if let home = stashedSpace(of: tab) {
                if remember { rememberClosed(tab) }
                tab.sleep()
                withSpace(home.id) {
                    tabs.removeAll { $0 === tab }
                    normalizeGroups()
                    if selectedID == tab.id { selectedID = tabs.last?.id }
                }
                extensionHost?.tabClosed(tab, windowIsClosing: false)
                AppModel.shared.sessionChanged()
            }
            return
        }
        if remember { rememberClosed(tab) }
        let wasSelected = tab.id == selectedID
        if renamingTabID == tab.id { renamingTabID = nil }
        tab.sleep()
        tabs.remove(at: index)
        normalizeGroups()
        extensionHost?.tabClosed(tab, windowIsClosing: allTabs.isEmpty)

        if tabs.isEmpty {
            selectedID = nil
            // The space is empty: show another one that has tabs, or close the window when none has.
            if !showSpaceWithTabs() { controller?.close() }
            return
        }
        if wasSelected {
            if returnToOpener ?? tab.returnsToOpener, let opener = tab.opener, tabs.contains(where: { $0 === opener }) {
                select(opener)
            } else {
                let next = TabOrder.selectionAfterClosing(index, rule: config.afterClosingTab, lastActive: tabs.map(\.lastActive))
                select(nearestVisibleTab(to: next ?? 0))
            }
        }
        AppModel.shared.sessionChanged()
    }

    /// Offers the tab in Reopen Closed Tab. Never for private windows or View Source tabs.
    private func rememberClosed(_ tab: Tab) {
        guard !isPrivate, tab.sourceHTML == nil else { return }
        closedTabs.append(tab.record)
        if closedTabs.count > 50 { closedTabs.removeFirst() }
    }

    func closeOthers(_ keep: Tab) {
        // Select first, so closing the selected tab doesn't wake neighbours that are about to close too.
        if keep.id != selectedID { select(keep) }
        for tab in tabs where tab !== keep && !tab.isPinned { close(tab) }
    }

    func closeTabsToTheRight(_ from: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === from }) else { return }
        let toClose = Array(tabs.suffix(from: index + 1).filter { !$0.isPinned })
        for tab in toClose { close(tab) }
    }

    func muteOthers(_ keep: Tab) {
        for tab in allTabs where tab !== keep {
            tab.setMuted(true)
        }
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
        for tab in allTabs where tab.isAwake { tab.sleep() }
        for tab in visibleTabs { tab.wake() }
    }

    // MARK: - Sound

    /// Tabs > Mute Tab, the tab strip's speaker and the tab context menu. Kept while the tab sleeps, not across
    /// relaunches.
    func toggleMute(_ tab: Tab) {
        tab.setMuted(!tab.isMuted)
        // Your own choice: `mosaicSound` leaves it alone from now on.
        autoMutedPanes.remove(tab.id)
    }

    /// Panes `mosaicSound` "focused" muted (not the user), to unmute when they're focused or the rule no longer applies.
    @ObservationIgnored private var autoMutedPanes: Set<UUID> = []

    /// `mosaicSound`: with "focused", the panes of `focused`'s Mosaic but it are muted and it is unmuted (if Paddle
    /// muted it); every pane Paddle muted that the rule no longer covers is unmuted.
    func applyMosaicSound(focused: Tab) {
        let covered: Set<UUID> = config.mosaicSound == .focused ? Set(split(of: focused)?.tabIDs ?? []).subtracting([focused.id]) : []
        for id in autoMutedPanes.subtracting(covered) {
            autoMutedPanes.remove(id)
            allTabs.first { $0.id == id }?.setMuted(false)
        }
        for tab in tabs where covered.contains(tab.id) && !tab.isMuted {
            tab.setMuted(true)
            autoMutedPanes.insert(tab.id)
        }
    }

    /// ⇧⌘D in a Mosaic, by `mosaicDarkMode`: the site setting of `tab` (saved), every pane together, or `tab` alone.
    func toggleDarkMode(_ tab: Tab) {
        guard let split = split(of: tab), config.mosaicDarkMode != .site else {
            // A private tab keeps its toggle in the override (nothing is saved), so it isn't cleared here.
            if !tab.isPrivate { tab.setDarkModeOverride(nil) }
            tab.toggleDarkMode()
            return
        }
        let next = !tab.isDarkModeActive
        let targets = config.mosaicDarkMode == .unified ? panes(of: split) : [tab]
        for pane in targets { pane.setDarkModeOverride(next) }
    }

    /// The tabs ⌘+, ⌘− and ⌘0 zoom: every pane of `tab`'s Mosaic with `mosaicZoom` "all", else `tab`.
    func zoomTargets(for tab: Tab) -> [Tab] {
        guard config.mosaicZoom == .all, let split = split(of: tab) else { return [tab] }
        return panes(of: split)
    }

    /// ⌘W: closes `tab`, or with `mosaicCloseKey` "removePane" only takes a Mosaic pane out of its Mosaic.
    func closeCommand(_ tab: Tab) {
        if config.mosaicCloseKey == .removePane, split(of: tab) != nil {
            removeFromView(tab)
        } else {
            close(tab)
        }
    }

    // MARK: - View Source

    /// View > View Source: the page's current DOM, read from the open page in an isolated script world (no new
    /// request to the site), shown as escaped text in a new tab after this one.
    func viewSource(of tab: Tab) async {
        guard let webView = tab.webView else { return }
        tab.unfreeze()
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
        guard allTabs.contains(where: { $0 === tab }) else { return }
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
        if renamingTabID == tab.id { renamingTabID = nil }
        tab.isPinned.toggle()
        tabs.remove(at: from)
        let to = TabOrder.pinBoundary(tabs.map(\.isPinned))
        tabs.insert(tab, at: to)
        normalizeGroups()
        let extensions = extensionHost
        extensions?.tabChanged(tab, .pinned)
        if to != from { extensions?.tabMoved(tab, from: from + tabOffset(ofSpace: activeSpaceID)) }
        AppModel.shared.sessionChanged()
    }

    /// An extension asked for a tab at `index` (`tabs.create`, `tabs.move`), an index into `allTabs`. The tab moves
    /// within its own space, clamped to its side of the pinned boundary.
    func place(_ tab: Tab, at index: Int) {
        let home = stashedSpace(of: tab)?.id ?? activeSpaceID
        let offset = tabOffset(ofSpace: home)
        let from: Int? = withSpace(home) {
            guard let from = tabs.firstIndex(where: { $0 === tab }) else { return nil }
            var others = tabs
            others.remove(at: from)
            let boundary = TabOrder.pinBoundary(others.map(\.isPinned))
            let local = index - offset
            var to = tab.isPinned ? min(max(local, 0), boundary) : min(max(local, boundary), others.count)
            to = outsideSplits(to, in: others, moving: tab)
            guard to != from else { return nil }
            others.insert(tab, at: to)
            tabs = others
            normalizeGroups()
            return from
        }
        guard let from else { return }
        extensionHost?.tabMoved(tab, from: from + offset)
        AppModel.shared.sessionChanged()
    }

    func sleep(_ tab: Tab) {
        guard !isVisible(tab) else { return }
        tab.sleep()
    }

    /// Drag and drop in the tab strip. Tabs can't cross the pinned/unpinned boundary.
    /// Returns false when the drop is refused, so the drag animates back.
    @discardableResult
    func move(_ tab: Tab, onto target: Tab) -> Bool {
        // A dragged tab takes the group of the tab it lands on.
        reorder(tab, onto: target, groupID: target.groupID)
    }

    private func reorder(_ tab: Tab, onto target: Tab, groupID: UUID?) -> Bool {
        guard tab !== target, tab.isPinned == target.isPinned,
              let from = tabs.firstIndex(where: { $0 === tab }),
              let to = tabs.firstIndex(where: { $0 === target }) else { return false }
        // Landing on a tab of a multi view that `tab` isn't in goes to the view's far edge, so the view stays whole.
        var dest = to
        if split(of: tab) == nil, let view = split(of: target) {
            let members = Set(view.tabIDs)
            let spots = tabs.indices.filter { members.contains(tabs[$0].id) }
            if let l = spots.min(), let r = spots.max() { dest = from < to ? r : l }
        }
        TabOrder.move(&tabs, from: from, onto: dest)
        tab.groupID = groupID
        normalizeGroups()
        // Never leave the selection hidden in a collapsed group.
        if tab.id == selectedID, let group = group(of: tab), group.isCollapsed { group.isCollapsed = false }
        extensionHost?.tabMoved(tab, from: from + tabOffset(ofSpace: activeSpaceID))
        AppModel.shared.sessionChanged()
        return true
    }

    /// Whether Move Tab Left/Right (`offset` -1/+1) can move the selected tab: not past either end or across the
    /// pinned/unpinned boundary.
    func canMoveSelectedTab(by offset: Int) -> Bool {
        guard let tab = selectedTab else { return false }
        return moveDestination(of: tab, by: offset) != nil
    }

    /// Where Move Tab Left/Right puts `tab`: the neighbour it lands on and the group it ends up in. An ungrouped tab
    /// hops over a whole collapsed group instead of joining it; a grouped tab at its group's edge leaves the group
    /// (hopping a group it meets there).
    private func moveDestination(of tab: Tab, by offset: Int) -> (target: Tab, groupID: UUID?)? {
        guard let index = tabs.firstIndex(where: { $0 === tab }), tabs.indices.contains(index + offset) else { return nil }
        let neighbour = tabs[index + offset]
        guard neighbour.isPinned == tab.isPinned else { return nil }
        guard neighbour.groupID != tab.groupID else { return (neighbour, neighbour.groupID) }
        let neighbourGroup = group(of: neighbour)
        guard tab.groupID != nil || neighbourGroup?.isCollapsed == true, let neighbourGroup else {
            // Leaving a group onto an ungrouped tab, or joining an open group.
            return (neighbour, tab.groupID != nil ? nil : neighbour.groupID)
        }
        let members = tabs(in: neighbourGroup)
        guard let far = offset > 0 ? members.last : members.first else { return nil }
        return (far, nil)
    }

    /// The tab nearest `index` that the strip shows (not inside a collapsed group); `tabs[index]` when none is.
    private func nearestVisibleTab(to index: Int) -> Tab {
        let visible = tabs.indices.filter { group(of: tabs[$0])?.isCollapsed != true }
        return visible.min { abs($0 - index) < abs($1 - index) }.map { tabs[$0] } ?? tabs[index]
    }

    /// Tells extensions about every tab whose index differs from `before`.
    private func reportMoves(from before: [Tab]) {
        let offset = tabOffset(ofSpace: activeSpaceID)
        for (to, tab) in tabs.enumerated() {
            if let from = before.firstIndex(where: { $0 === tab }), from != to {
                extensionHost?.tabMoved(tab, from: from + offset)
            }
        }
    }

    /// Moves the selected tab one place left (-1) or right (+1); no wrap-around.
    func moveSelectedTab(by offset: Int) {
        guard let tab = selectedTab, let destination = moveDestination(of: tab, by: offset) else { return }
        reorder(tab, onto: destination.target, groupID: destination.groupID)
    }

    // MARK: - Spaces

    /// The hidden space that holds `tab`, nil when it is in the active space or none.
    private func stashedSpace(of tab: Tab) -> Space? {
        spaces.first { $0.id != activeSpaceID && stashes[$0.id]?.tabs.contains { $0 === tab } == true }
    }

    /// The space `tab` is in; the active one for a tab that is in none yet.
    func space(of tab: Tab) -> Space {
        stashedSpace(of: tab) ?? activeSpace
    }

    /// Runs `body` with space `id` as the one in `tabs`, `groups` and `selectedID`, then puts things back. Nothing
    /// is reported; for editing a hidden space.
    private func withSpace<T>(_ id: String, _ body: () -> T) -> T {
        if id == activeSpaceID { return body() }
        let keep = Stash(tabs: tabs, groups: groups, selectedID: selectedID, splits: splits)
        let stash = stashes[id] ?? Stash()
        tabs = stash.tabs
        groups = stash.groups
        selectedID = stash.selectedID
        splits = stash.splits
        let result = body()
        stashes[id] = Stash(tabs: tabs, groups: groups, selectedID: selectedID, splits: splits)
        tabs = keep.tabs
        groups = keep.groups
        selectedID = keep.selectedID
        splits = keep.splits
        return result
    }

    /// Shows space `id`: the current one's tabs are stashed (they keep their web views per the sleep policy), the
    /// target's selected tab is shown and focused. `selecting` picks a tab of the target instead. A space with no
    /// tabs gets a New Tab. No-op for the active space.
    func switchToSpace(_ id: String) {
        switchToSpace(id, selecting: nil)
    }

    private func switchToSpace(_ id: String, selecting chosen: Tab?) {
        guard id != activeSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        closePreview()
        let previous = selectedTab
        stashes[activeSpaceID] = Stash(tabs: tabs, groups: groups, selectedID: selectedID, splits: splits)
        let stash = stashes.removeValue(forKey: id) ?? Stash()
        tabs = stash.tabs
        groups = stash.groups
        splits = stash.splits
        selectedID = nil
        activeSpaceID = id
        renamingTabID = nil
        renamingGroupID = nil
        if let tab = chosen ?? tabs.first(where: { $0.id == stash.selectedID }) ?? tabs.last {
            activate(tab, previous: previous)
        } else {
            previous?.hoveredLink = nil
            openNewTabPage()
        }
        AppModel.shared.sessionChanged()
    }

    /// The active space has no tabs: shows the nearest space that has some. False when none has.
    @discardableResult
    private func showSpaceWithTabs() -> Bool {
        guard let at = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return false }
        let others = spaces.indices.filter { stashes[spaces[$0].id]?.tabs.isEmpty == false }
        guard let nearest = others.min(by: { abs($0 - at) < abs($1 - at) }) else { return false }
        switchToSpace(spaces[nearest].id)
        return true
    }

    func nextSpace(offset: Int) {
        guard spaces.count > 1, let at = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        switchToSpace(spaces[((at + offset) % spaces.count + spaces.count) % spaces.count].id)
    }

    /// Adds a space after the others and switches to it; it opens one New Tab. An empty name becomes "Space N".
    @discardableResult
    func newSpace(name: String = "", symbol: SpaceSymbol = .star) -> Space {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(name: trimmed.isEmpty ? "Space \(spaces.count + 1)" : trimmed, symbol: symbol)
        spaces.append(space)
        switchToSpace(space.id)
        return space
    }

    /// Removes a space, never the last. Its tabs close into Reopen Closed Tab. The active space first hands the
    /// window to a neighbour.
    func deleteSpace(_ id: String) {
        guard spaces.count > 1, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if id == activeSpaceID { switchToSpace(spaces[at > 0 ? at - 1 : 1].id) }
        let doomed = stashes.removeValue(forKey: id)?.tabs ?? []
        spaces.removeAll { $0.id == id }
        for tab in doomed {
            rememberClosed(tab)
            tab.sleep()
            extensionHost?.tabClosed(tab, windowIsClosing: false)
        }
        AppModel.shared.sessionChanged()
    }

    func renameSpace(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let space = spaces.first(where: { $0.id == id }) else { return }
        space.name = trimmed
        AppModel.shared.sessionChanged()
    }

    func setSymbol(_ symbol: SpaceSymbol, of id: String) {
        spaces.first { $0.id == id }?.symbol = symbol
        AppModel.shared.sessionChanged()
    }

    func setTint(_ tint: ColorPreset?, of id: String) {
        spaces.first { $0.id == id }?.tint = tint
        AppModel.shared.sessionChanged()
    }

    /// Moves `tab` to the end of space `id` (a pinned tab to the end of its pins). It leaves its group, and the
    /// source space selects a neighbour.
    func moveTab(_ tab: Tab, toSpace id: String) {
        let source = space(of: tab)
        guard source.id != id, spaces.contains(where: { $0.id == id }), allTabs.contains(where: { $0 === tab }) else { return }
        if tab === previewSource { closePreview() }
        if renamingTabID == tab.id { renamingTabID = nil }
        let leave: () -> Void = { [self] in
            let index = tabs.firstIndex { $0 === tab } ?? 0
            tabs.removeAll { $0 === tab }
            tab.groupID = nil
            normalizeGroups()
            if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : nearestVisibleTab(to: min(index, tabs.count - 1)).id }
        }
        let arrive: () -> Void = { [self] in
            let to = tab.isPinned ? TabOrder.pinBoundary(tabs.map(\.isPinned)) : tabs.count
            tabs.insert(tab, at: to)
            if selectedID == nil { selectedID = tab.id }
        }
        let sourceWasActive = source.id == activeSpaceID
        let wasSelected = sourceWasActive && tab.id == selectedID
        withSpace(source.id, leave)
        withSpace(id, arrive)
        if sourceWasActive {
            if let next = selectedTab, wasSelected { activate(next, previous: tab) } else if tabs.isEmpty { openNewTabPage() }
        }
        AppModel.shared.sessionChanged()
    }

    /// Session restore: the saved name, symbol and tint of the active space (it keeps `tabs`).
    func restoreActiveSpace(_ record: SpaceRecord) {
        let space = Space(record: record)
        spaces = [space]
        activeSpaceID = space.id
    }

    /// Session restore: an inactive space with its tabs (already owned by this window). Duplicate ids are skipped.
    func restoreSpace(_ record: SpaceRecord, tabs restored: [Tab]) {
        guard !spaces.contains(where: { $0.id == record.id }) else { return }
        spaces.append(Space(record: record))
        withSpace(record.id) {
            tabs = restored
            groups = record.groups.compactMap(TabGroup.init(record:))
            splits = Self.splits(from: record.allLayouts, in: restored)
            normalizeGroups()
            if restored.indices.contains(record.selectedIndex) { selectedID = restored[record.selectedIndex].id } else { selectedID = restored.last?.id }
        }
    }

    /// Session restore, last step: the active space goes back to its saved place among the others (restore adds it
    /// first), and an active space that restored empty gives way to one with tabs.
    func finishRestore(activeSpaceIndex: Int? = nil) {
        if let index = activeSpaceIndex, let from = spaces.firstIndex(where: { $0.id == activeSpaceID }) {
            let space = spaces.remove(at: from)
            spaces.insert(space, at: min(max(index, 0), spaces.count))
        }
        if tabs.isEmpty { showSpaceWithTabs() }
    }

    // MARK: - Multi view

    /// Tabs shown at once, tiled (`PaneLayout`, naming tabs by `Tab.id`): split view's two side by side, or up to
    /// `maxPanes`. Its tabs sit next to each other in the strip; the selected one is the focused pane.
    struct Split: Identifiable, Equatable {
        var id = UUID()
        var layout: PaneLayout

        var tabIDs: [UUID] { layout.tabs.compactMap(UUID.init(uuidString:)) }
        func contains(_ tab: Tab) -> Bool { layout.contains(tab.id.uuidString) }
    }

    /// The most panes a Mosaic in this window may have (`mosaicMaxPanes`).
    var maxPanes: Int { config.mosaicMaxPanes }

    /// The content area in the window's content view (top-left origin), set by the content area as it lays out.
    @ObservationIgnored var paneArea: CGRect = .zero

    /// Where each pane is now, in the window's content view: the selected tab's view laid out in `paneArea` (only the
    /// focused pane when one would be under `PaneMetrics.minimumPane`), or the single page. Worked out when asked, so
    /// it always matches the layout. A click in an unfocused pane focuses it; a tab drag over one drops there.
    var paneFrames: [UUID: CGRect] {
        guard let selected = selectedTab, paneArea.width > 0 else { return [:] }
        let local = CGRect(origin: .zero, size: paneArea.size)
        guard let split = split(of: selected) else { return [selected.id: paneArea] }
        let frames = split.layout.frames(in: local, gap: PaneMetrics.gap)
        if (!split.layout.isFreeform && PaneMetrics.isNarrow(frames)) || zoomedPaneID == selected.id { return [selected.id: paneArea] }
        return Dictionary(uniqueKeysWithValues: frames.compactMap { key, frame in
            UUID(uuidString: key).map { ($0, frame.offsetBy(dx: paneArea.minX, dy: paneArea.minY)) }
        })
    }
    /// The pane under `point` (window content coordinates, as `paneFrames`) and its frame: in a freeform Mosaic the
    /// card on top, else the one pane there.
    func pane(at point: CGPoint) -> (id: UUID, frame: CGRect)? {
        let frames = paneFrames
        let order = selectedTab.flatMap { split(of: $0)?.layout.freeform?.order.compactMap(UUID.init(uuidString:)) } ?? Array(frames.keys)
        for id in order.reversed() {
            if let frame = frames[id], frame.contains(point) { return (id, frame) }
        }
        return nil
    }

    /// Where a tab being dragged over the content area would land: a pane and an edge (nil: the middle, a swap or
    /// replace). The content area draws it.
    var paneDropHint: (target: UUID, edge: PaneEdge?)?
    /// The tab being dragged while `paneDropHint` is set, for the live preview (`paneDragPreview`).
    var paneDragTabID: UUID?
    /// A divider is being dragged: the panes follow the pointer with no spring.
    var isDraggingDivider = false

    /// Incremented to put the keyboard in the focused pane's address field (⌘L in a multi view).
    var paneAddressFocusRequest = 0
    /// The pane whose address field is being edited: its suggestions show, and it draws above the other panes.
    var editingPaneID: UUID?
    /// The view a dragged tab would join when let go (over its strip or sidebar item).
    var viewDropTargetID: UUID?
    /// The view whose Rename View popover is open in the strip or sidebar.
    var renamingViewID: UUID?
    /// The Mosaic whose Choose Icon popover is open in the strip or sidebar.
    var iconPickerViewID: UUID?

    /// What the strip calls `split`: its name, else the focused (or most recently used) pane's site.
    func displayName(of split: Split) -> String {
        if let name = split.layout.name { return name }
        let shown = panes(of: split)
        // `mosaicStripName` "all": every pane's site, in pane order.
        if config.mosaicStripName == .all {
            let names = shown.map { tab -> String in
                guard let host = tab.url?.host(), !host.isEmpty else { return tab.displayTitle }
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            if !names.isEmpty { return names.joined(separator: " · ") }
        }
        guard let lead = shown.first(where: { $0.id == selectedID }) ?? shown.max(by: { $0.lastActive < $1.lastActive }) else { return "View" }
        if let host = lead.url?.host(), !host.isEmpty { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return lead.displayTitle
    }

    /// Rename View: `name` empty or blank goes back to the site.
    func renameView(_ split: Split, to name: String) {
        guard let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        splits[at].layout.name = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        AppModel.shared.sessionChanged()
    }

    /// Choose Icon…: `split`'s icon and its tint (nil: the grid symbol, the text color).
    func setIcon(_ icon: MosaicIcon?, tint: ColorPreset?, of split: Split) {
        guard let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        guard splits[at].layout.icon != icon || splits[at].layout.iconTint != tint else { return }
        splits[at].layout.icon = icon
        splits[at].layout.iconTint = tint
        AppModel.shared.sessionChanged()
    }

    /// A tab joining a Mosaic (dropped on its strip item, Add Pane, ⌘T or a link set to open as a pane): it takes half
    /// of the pane `mosaicNewPanePlacement` names, split along that pane's longer side; `focused` is the pane `.focused`
    /// means (the selected tab when nil). False when it can't: in the Mosaic already, pinned, another space, or full.
    @discardableResult
    func addToView(_ tab: Tab, _ split: Split, focused: Tab? = nil) -> Bool {
        guard !split.contains(tab), split.layout.count < maxPanes else { return false }
        let area = paneArea.size == .zero ? CGSize(width: 1200, height: 800) : paneArea.size
        let slot = split.layout.slotForNewPane(
            config.mosaicNewPanePlacement, focused: (focused?.id ?? selectedID)?.uuidString,
            in: CGRect(origin: .zero, size: area), gap: PaneMetrics.gap
        )
        guard let target = tabs.first(where: { $0.id.uuidString == slot.target }) else { return false }
        return dropTab(tab, onto: target, edge: slot.edge)
    }

    /// File > New Tab: with `mosaicNewTab` "pane" and a Mosaic on screen that has room, a new pane in it; else a tab.
    func newTabCommand() {
        if config.mosaicNewTab == .pane, canAddPane {
            addPaneToMosaic()
        } else {
            openNewTabPage()
        }
    }

    /// A link `opener` opened in a new tab (⌘-click, middle-click, a target=_blank click): with `mosaicLinks` "pane"
    /// and `opener` in a Mosaic with room, `tab` joins it beside `opener`'s pane. `select` false keeps the focus
    /// where it was, as a background tab would.
    func placeLinkTab(_ tab: Tab, from opener: Tab, select: Bool) {
        guard config.mosaicLinks == .pane, let split = split(of: opener), split.layout.count < maxPanes else { return }
        let keep = selectedTab
        guard addToView(tab, split, focused: opener) else { return }
        if !select, let keep, keep !== tab { self.select(keep) }
    }

    /// Shows `split` with its most recently used pane focused.
    func selectView(_ split: Split) {
        guard let lead = panes(of: split).max(by: { $0.lastActive < $1.lastActive }) else { return }
        select(lead)
    }

    /// The view `id` names, in this space.
    func view(id: UUID) -> Split? { splits.first { $0.id == id } }

    /// The multi view `tab` is in; the active space's only.
    func split(of tab: Tab) -> Split? {
        splits.first { $0.contains(tab) }
    }

    /// `split`'s tabs in pane order (left to right, top to bottom).
    func panes(of split: Split) -> [Tab] {
        split.tabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    /// The other tabs of `tab`'s multi view, in pane order.
    func others(of tab: Tab) -> [Tab] {
        guard let split = split(of: tab) else { return [] }
        return panes(of: split).filter { $0 !== tab }
    }

    /// The tabs on screen in pane order: the selected tab's multi view, else just the selected tab.
    var visibleTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        guard let split = split(of: selected) else { return [selected] }
        return panes(of: split)
    }

    /// On screen: a pane of what `visibleTabs` shows, or the link preview over it (so its dialogs show).
    func isVisible(_ tab: Tab) -> Bool {
        tab === preview || visibleTabs.contains { $0 === tab }
    }

    /// Shows `b` with `a`: in `a`'s multi view, to the right of `a`'s pane (when it has room), or as a new two-pane
    /// view with `b` on the right. `b` leaves any other multi view and moves next to the others in the strip (into
    /// their group). Refused for pinned tabs, the same tab, a full multi view, or tabs not both in this space.
    func makeSplit(_ a: Tab, with b: Tab) {
        _ = dropTab(b, onto: a, edge: .right)
    }

    /// A tab let go over a pane (`edge` nil: its middle). On an edge, `tab` takes that side of `target`'s pane, which
    /// becomes a multi view if it wasn't one. In the middle, two panes of one view swap, and a tab not shown yet
    /// takes `target`'s place (which stays a tab). `tab` is selected. False when refused: the same tab, a pinned
    /// one, one not in this space, or a full view.
    @discardableResult
    func dropTab(_ tab: Tab, onto target: Tab, edge: PaneEdge?) -> Bool {
        guard tab !== target, !tab.isPinned, !target.isPinned,
              tabs.contains(where: { $0 === tab }), tabs.contains(where: { $0 === target }) else { return false }
        let tid = tab.id.uuidString, gid = target.id.uuidString
        let existing = split(of: target)
        var layout: PaneLayout
        if let existing {
            guard let dropped = Self.dropping(tid, onto: gid, edge: edge, in: existing.layout, limit: maxPanes) else { return false }
            layout = dropped
        } else {
            guard let edge else {
                select(tab)
                return true
            }
            guard let two = Self.twoPanes(tid, at: gid, edge: edge) else { return false }
            layout = two
        }
        let before = tabs
        // `tab` leaves any other multi view.
        if let own = split(of: tab), own.id != existing?.id { setLayout(own.layout.removing(tid), for: own) }
        // `mosaicDefaultLayout`: a new Mosaic starts in it; with `mosaicAutoArrange`, one that gained a pane goes back to it.
        if let arrangement = config.mosaicDefaultLayout.arrangement,
           existing == nil || (config.mosaicAutoArrange && layout.count != existing?.layout.count) {
            layout = layout.arranged(arrangement)
        }
        if let existing { setLayout(layout, for: existing) } else { splits.append(Split(layout: layout)) }
        gather(around: target, adding: tab)
        reportMoves(from: before)
        for shown in visibleTabs(of: target) {
            shown.lastActive = Date()
            shown.wake()
        }
        select(tab)
        AppModel.shared.sessionChanged()
        return true
    }

    /// `layout` once tab `tid` is let go on `edge` of `gid`'s pane (nil: its middle), as `dropTab` does it; nil when
    /// refused (a full Mosaic's edge). Also the live preview of a drag (`paneDragPreview`).
    private static func dropping(_ tid: String, onto gid: String, edge: PaneEdge?, in layout: PaneLayout, limit: Int) -> PaneLayout? {
        var layout = layout
        if let edge {
            if layout.contains(tid) {
                if layout.count > 2 {
                    guard layout.move(tid, to: gid, edge: edge) else { return nil }
                } else {
                    return twoPanes(tid, at: gid, edge: edge).map { two in
                        var same = two
                        same.takeLooks(of: layout)
                        return same
                    }
                }
            } else {
                guard layout.insert(tid, at: gid, edge: edge, limit: limit) else { return nil }
            }
        } else if layout.contains(tid) {
            layout.swap(tid, gid)
        } else {
            guard layout.replace(gid, with: tid) else { return nil }
        }
        return layout
    }

    /// What `split` would look like if the tab being dragged (`paneDragTabID`) were let go where `paneDropHint`
    /// says: the content area draws this while the drag goes on, the panes moving aside for it. Nil when no drag is
    /// over `split`'s panes.
    func paneDragPreview(for split: Split) -> PaneLayout? {
        guard let hint = paneDropHint, let dragged = paneDragTabID, split.tabIDs.contains(hint.target) else { return nil }
        return Self.dropping(dragged.uuidString, onto: hint.target.uuidString, edge: hint.edge, in: split.layout, limit: maxPanes)
    }

    /// `new` on `edge` of `target`, the two alone.
    private static func twoPanes(_ new: String, at target: String, edge: PaneEdge) -> PaneLayout? {
        let axis: PaneAxis = edge == .left || edge == .right ? .horizontal : .vertical
        let newFirst = edge == .left || edge == .top
        return PaneLayout(root: .split(axis, ratio: 0.5, newFirst ? .tab(new) : .tab(target), newFirst ? .tab(target) : .tab(new)))
    }

    /// The tabs `target`'s multi view shows (or `target` alone).
    private func visibleTabs(of target: Tab) -> [Tab] {
        split(of: target).map(panes(of:)) ?? [target]
    }

    /// Moves `tab` next to the other tabs of `target`'s multi view in the strip (after the last of them), into their
    /// group, so the rules hold.
    private func gather(around target: Tab, adding tab: Tab) {
        guard let split = split(of: target) else { return }
        let members = Set(split.tabIDs)
        tab.groupID = target.groupID
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        let last = tabs.lastIndex { members.contains($0.id) && $0 !== tab } ?? (tabs.firstIndex { $0 === target } ?? tabs.count - 1)
        tabs.insert(tab, at: min(last + 1, tabs.count))
        normalizeGroups()
    }

    /// Replaces `split`'s layout, or ends it (nil).
    private func setLayout(_ layout: PaneLayout?, for split: Split) {
        guard let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        // A tab that leaves (the last one too, when the Mosaic ends) goes back to its site's dark mode.
        clearDarkOverrides(leaving: splits[at].layout, for: layout)
        if let layout { splits[at].layout = layout } else { splits.remove(at: at) }
    }

    /// Takes `tab` out of its multi view, which closes up (or ends with one pane left); the tab stays in the strip,
    /// moved to just after the view's other tabs so they stay together.
    func removeFromView(_ tab: Tab) {
        guard let split = split(of: tab) else { return }
        let rest = split.layout.removing(tab.id.uuidString).map(autoArranged)
        setLayout(rest, for: split)
        if let rest {
            let members = Set(rest.tabs.compactMap(UUID.init(uuidString:)))
            let before = tabs
            if let from = tabs.firstIndex(where: { $0 === tab }) {
                tabs.remove(at: from)
                let last = tabs.lastIndex { members.contains($0.id) } ?? from - 1
                tabs.insert(tab, at: min(last + 1, tabs.count))
                normalizeGroups()
                reportMoves(from: before)
            }
        }
        if selectedID == tab.id, let next = rest?.tabs.first.flatMap(UUID.init(uuidString:)).flatMap({ id in tabs.first { $0.id == id } }) {
            select(next)
        }
        AppModel.shared.sessionChanged()
    }

    /// Ends the multi view `tab` is in; its tabs stay where they are.
    func endSplit(of tab: Tab) {
        guard let split = split(of: tab) else { return }
        clearDarkOverrides(leaving: split.layout, for: nil)
        splits.removeAll { $0.id == split.id }
        AppModel.shared.sessionChanged()
    }

    /// Tabs > Split View: ends the selected tab's multi view; else shows it with the next tab in the strip (not
    /// pinned, not in a view, same group), or with a new New Tab page after it, which is then focused.
    func toggleSplitView() {
        guard let current = selectedTab else { return }
        if split(of: current) != nil {
            endSplit(of: current)
            return
        }
        guard !current.isPinned, let index = tabs.firstIndex(where: { $0 === current }) else { return }
        if tabs.indices.contains(index + 1) {
            let next = tabs[index + 1]
            if !next.isPinned, next.groupID == current.groupID, split(of: next) == nil {
                makeSplit(current, with: next)
                select(current)
                return
            }
        }
        let page = URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        let fresh = newTab(url: page, select: false, after: current)
        fresh.opener = nil
        fresh.groupID = current.groupID
        makeSplit(current, with: fresh)
        select(fresh)
        if page == nil { focusAddress() }
    }

    /// Tabs > Swap Sides: in a two-pane view the two tabs trade panes and strip places; the focused tab stays focused.
    func swapSplitSides() {
        guard let selected = selectedTab, let split = split(of: selected), split.layout.count == 2,
              case .split(let axis, let ratio, .tab(let first), .tab(let second)) = split.layout.root,
              let l = tabs.firstIndex(where: { $0.id.uuidString == first }), let r = tabs.firstIndex(where: { $0.id.uuidString == second }) else { return }
        let before = tabs
        tabs.swapAt(l, r)
        setLayout(PaneLayout(root: .split(axis, ratio: 1 - ratio, .tab(second), .tab(first))), for: split)
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
    }

    /// Tabs > Focus Next Pane: the next pane of the selected tab's view, in pane order, round to the first.
    func focusOtherSplitSide() {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        let shown = panes(of: split)
        guard let at = shown.firstIndex(where: { $0 === selected }), shown.count > 1 else { return }
        select(shown[(at + 1) % shown.count])
    }

    /// ⌘⌥ and an arrow: the pane next to the focused one that way.
    func focusPane(toward edge: PaneEdge) {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        let size = paneArea.size == .zero ? CGSize(width: 1200, height: 800) : paneArea.size
        guard let id = split.layout.neighbor(of: selected.id.uuidString, toward: edge, in: CGRect(origin: .zero, size: size)),
              let next = tabs.first(where: { $0.id.uuidString == id }) else { return }
        select(next)
    }

    /// Moves a divider: `ratio` is the first side's share of the split at `path`, kept within `PaneLayout.ratioRange`.
    func setSplitRatio(_ ratio: Double, at path: [Int], for split: Split) {
        guard let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        var layout = splits[at].layout
        guard layout.setRatio(ratio, at: path), layout != splits[at].layout else { return }
        splits[at].layout = layout
        AppModel.shared.sessionChanged()
    }

    /// Freeform (the Mosaic bar, Tabs > Mosaic Layout): the selected tab's Mosaic becomes cards where its tiles are, or,
    /// already freeform, is tidied up.
    func toggleFreeform() {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        if split.layout.isFreeform {
            tidyUp()
            return
        }
        let area = paneArea.size == .zero ? CGSize(width: 1200, height: 800) : paneArea.size
        setLayout(split.layout.freeformed(in: CGRect(origin: .zero, size: area), gap: PaneMetrics.gap, front: selected.id.uuidString), for: split)
        AppModel.shared.sessionChanged()
    }

    /// Tidy Up: a freeform Mosaic back to tiles in reading order, in `mosaicDefaultLayout` (a grid when that is
    /// "as dropped").
    func tidyUp() {
        guard let selected = selectedTab, let split = split(of: selected), split.layout.isFreeform else { return }
        setLayout(split.layout.tidied(config.mosaicDefaultLayout.arrangement ?? .grid), for: split)
        AppModel.shared.sessionChanged()
    }

    /// The selected tab's Mosaic is freeform.
    var isFreeformShown: Bool { selectedTab.flatMap { split(of: $0) }?.layout.isFreeform ?? false }

    /// A freeform card moved or resized to `rect`, in fractions of the content area.
    func setFreeformFrame(_ rect: CGRect, of tab: Tab) {
        guard let split = split(of: tab), let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        var layout = splits[at].layout
        guard layout.setFreeformFrame(rect, of: tab.id.uuidString), layout != splits[at].layout else { return }
        splits[at].layout = layout
        AppModel.shared.sessionChanged()
    }

    /// A freeform card is being moved or resized: the cards follow the pointer with no spring.
    var isMovingFreeform = false

    /// The focused pane fills its Mosaic for now (Zoom Pane, ⌃⌘↩); the other panes stay as they were. Focusing
    /// another tab, or Zoom Pane again, gives the space back. Not saved.
    var zoomedPaneID: UUID?

    func toggleZoomPane() {
        guard let selected = selectedTab, split(of: selected) != nil else { return }
        zoomedPaneID = zoomedPaneID == selected.id ? nil : selected.id
    }

    /// ⌃⌥⇧⌘ and an arrow: the focused pane trades places with the pane next to it that way; it stays focused.
    func movePane(toward edge: PaneEdge) {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        let size = paneArea.size == .zero ? CGSize(width: 1200, height: 800) : paneArea.size
        guard let other = split.layout.neighbor(of: selected.id.uuidString, toward: edge, in: CGRect(origin: .zero, size: size)) else { return }
        var layout = split.layout
        guard layout.swap(selected.id.uuidString, other) else { return }
        setLayout(layout, for: split)
        AppModel.shared.sessionChanged()
    }

    /// Mute Other Panes: every pane of the focused pane's Mosaic but it.
    func muteOtherPanes() {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        for tab in panes(of: split) where tab !== selected { tab.setMuted(true) }
    }

    /// The selected tab's Mosaic, laid out as `arrangement` in its pane order (the Mosaic bar's layout buttons).
    func arrangeMosaic(_ arrangement: PaneArrangement) {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        let arranged = split.layout.arranged(arrangement)
        guard arranged != split.layout else { return }
        setLayout(arranged, for: split)
        AppModel.shared.sessionChanged()
    }

    /// Tabs > Rotate Panes: each tab of the selected tab's Mosaic moves one pane along; the focused tab stays focused.
    func rotatePanes(forward: Bool = true) {
        guard let selected = selectedTab, let split = split(of: selected), split.layout.count > 1 else { return }
        setLayout(split.layout.rotated(forward: forward), for: split)
        AppModel.shared.sessionChanged()
    }

    /// The selected tab's Mosaic has room for another pane.
    var canAddPane: Bool {
        guard let selected = selectedTab, let split = split(of: selected) else { return false }
        return split.layout.count < maxPanes
    }

    /// Tabs > Add Pane: a new New Tab page joins the selected tab's Mosaic in half of its largest pane, focused with
    /// the keyboard in its address field.
    func addPaneToMosaic() {
        guard canAddPane, let selected = selectedTab, let split = split(of: selected) else { return }
        let last = panes(of: split).max { a, b in
            (tabs.firstIndex { $0 === a } ?? 0) < (tabs.firstIndex { $0 === b } ?? 0)
        } ?? selected
        let page = URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        let fresh = newTab(url: page, select: false, after: last)
        fresh.opener = nil
        fresh.groupID = selected.groupID
        guard addToView(fresh, split) else {
            close(fresh, remember: false)
            return
        }
        select(fresh)
        if page == nil { focusAddress() }
    }

    /// Tabs > Reload All Panes: every page of the selected tab's Mosaic (a Settings pane has nothing to reload).
    func reloadAllPanes() {
        guard let selected = selectedTab, let split = split(of: selected) else { return }
        for tab in panes(of: split) where tab.url != nil && tab.settingsPane == nil { tab.reload() }
    }

    /// Even Out Panes: every pane of the selected tab's Mosaic its even share (`PaneLayout.equalize`).
    func equalizePanes() {
        guard let selected = selectedTab, let split = split(of: selected), let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        splits[at].layout.equalize()
        AppModel.shared.sessionChanged()
    }

    /// Makes the multi views fit the tab order again (a tab closed, moved away, pinned or regrouped leaves its view;
    /// a view left with one tab ends). Ids are kept, so the panes stay as they are on screen.
    private func normalizeSplits() {
        guard !splits.isEmpty else { return }
        let kept = MultiViewRules.normalized(
            layouts: splits.map(\.layout),
            tabs: tabs.map { SplitTab(id: $0.id.uuidString, groupID: $0.groupID?.uuidString, isPinned: $0.isPinned) }
        )
        guard kept != splits.map(\.layout) else { return }
        for old in splits { clearDarkOverrides(leaving: old.layout, for: kept.first { $0.tabs.contains(where: old.layout.tabs.contains) }) }
        splits = kept.map { layout in
            let old = splits.first { $0.layout.tabs.contains(where: layout.tabs.contains) }
            // A Mosaic that lost a pane (closed, moved away) goes back to its default layout with `mosaicAutoArrange`.
            let shrank = old.map { $0.layout.count > layout.count } ?? false
            return Split(id: old?.id ?? UUID(), layout: shrank ? autoArranged(layout) : layout)
        }
    }

    /// The tabs of `old` that aren't in `new` (all of them for nil) lose their Mosaic dark mode (`darkModeOverride`).
    private func clearDarkOverrides(leaving old: PaneLayout, for new: PaneLayout?) {
        let gone = Set(old.tabs).subtracting(new?.tabs ?? [])
        for tab in allTabs where gone.contains(tab.id.uuidString) { tab.setDarkModeOverride(nil) }
    }

    /// `layout` in `mosaicDefaultLayout` when `mosaicAutoArrange` is on, else unchanged.
    private func autoArranged(_ layout: PaneLayout) -> PaneLayout {
        guard config.mosaicAutoArrange, let arrangement = config.mosaicDefaultLayout.arrangement else { return layout }
        return layout.arranged(arrangement)
    }

    /// Session restore: the active space's saved multi views, for tabs already in `tabs`.
    func restoreSplits(_ layouts: [PaneLayout]) {
        splits = Self.splits(from: layouts, in: tabs)
        normalizeSplits()
    }

    /// Layouts named by session id, renamed to tab ids; tabs that aren't in `tabs` are taken out.
    private static func splits(from layouts: [PaneLayout], in tabs: [Tab]) -> [Split] {
        let ids = Dictionary(tabs.map { ($0.sessionKey, $0.id.uuidString) }, uniquingKeysWith: { a, _ in a })
        return layouts.compactMap { layout in layout.mapped { ids[$0] }.map { Split(layout: $0) } }
    }

    /// The saved form of `splits`, naming tabs by session id. A tab that isn't saved (View Source) is left out.
    private static func records(of splits: [Split], in tabs: [Tab]) -> [PaneLayout] {
        let keys = Dictionary(tabs.filter { $0.sourceHTML == nil }.map { ($0.id.uuidString, $0.sessionKey) }, uniquingKeysWith: { a, _ in a })
        return splits.compactMap { $0.layout.mapped { keys[$0] } }
    }

    // MARK: - Link preview

    /// The link preview (⌥-click): a page over the content area, its own `Tab` with `isPreview` set and never in `tabs`
    /// or `allTabs`, so no tab walk (strip, session, sleep policy, memory sampling, tab search, Reopen Closed Tab, the
    /// bridge's tab lists) sees it. Extensions do (`extensionTabs`). One per window; nil when none shows.
    private(set) var preview: Tab?

    /// The tabs extensions see: every tab of every space, then the link preview while one shows. WebKit delivers a
    /// content script's messages only from a web view it knows as a tab, so the preview is registered with them while
    /// it shows (inactive, last in the window) and its extensions' content scripts reach their background pages.
    var extensionTabs: [Tab] { preview.map { allTabs + [$0] } ?? allTabs }
    /// The tab under the preview, where its links and popups open and next to which it becomes a tab.
    @ObservationIgnored private(set) weak var previewSource: Tab?

    /// Open in Split View is offered: the tab underneath is in this space, not pinned, and its multi view (if any)
    /// has room. The new tab joins it, to the right of the tab underneath.
    var canSplitPreview: Bool {
        guard preview != nil, let source = previewSource, tabs.contains(where: { $0 === source }) else { return false }
        return !source.isPinned && (split(of: source).map { $0.layout.count < maxPanes } ?? true)
    }

    /// Shows `url` (http or https) in the preview over `source`, replacing any preview already open. It gets this
    /// window's profile, data store, block lists, user scripts and extensions' content scripts, as a tab would.
    func openPreview(_ url: URL, from source: Tab) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), tabs.contains(where: { $0 === source }) else { return }
        closePreview()
        let tab = Tab(url: url, isPrivate: source.isPrivate)
        tab.browser = self
        tab.isPreview = true
        tab.opener = source
        // A link that only downloads a file leaves nothing to show (`TabWebDelegate.tabShowsNothingAfterDownload`).
        tab.closesIfOnlyDownload = true
        previewSource = source
        preview = tab
        tab.wake()
        extensionHost?.tabOpened(tab)
        controller?.focusWebView()
    }

    /// Closes the preview and drops its web view (delegate, observers and all), so its WebContent process can exit.
    /// It goes nowhere: not into Reopen Closed Tab, never into the session. The keyboard goes back to the tab.
    func closePreview() {
        guard let tab = preview else { return }
        preview = nil
        previewSource = nil
        extensionHost?.tabClosed(tab, windowIsClosing: false)
        tab.sleep()
        tab.opener = nil
        controller?.focusWebView()
    }

    /// Open as Tab (`split` false) or Open in Split View: the preview's own tab, web view and all (no reload; history,
    /// scroll and form input kept), goes into the strip after the tab underneath through the usual insert, so the
    /// session saves it, and is selected; extensions, which knew it as the preview, hear it moved. With `split` and `canSplitPreview` it is split
    /// with that tab, on the right.
    func openPreviewAsTab(split: Bool) {
        guard let tab = preview else { return }
        let source = previewSource.flatMap { source in tabs.contains { $0 === source } ? source : nil } ?? selectedTab
        let partner = split && canSplitPreview ? source : nil
        preview = nil
        previewSource = nil
        tab.isPreview = false
        // Extensions knew it as the window's last tab (`extensionTabs`); now it moves into the strip.
        let previewIndex = allTabs.count
        insert(tab, after: source, select: true, announce: false)
        extensionHost?.tabMoved(tab, from: previewIndex)
        // Already selected, so it stays the focused side.
        if let partner { makeSplit(partner, with: tab) }
        // The page moves from the preview's card into the tab's WebContainer; the card's never takes it back
        // (`WebContainer.forPreview`).
        tab.generation += 1
    }

    // MARK: - Tab groups

    private var groupSlots: [TabSlot] { tabs.map { TabSlot(groupID: $0.groupID?.uuidString, isPinned: $0.isPinned) } }

    func group(of tab: Tab) -> TabGroup? {
        guard let id = tab.groupID else { return nil }
        return groups.first { $0.id == id }
    }

    /// The group's tabs in strip order.
    func tabs(in group: TabGroup) -> [Tab] {
        tabs.filter { $0.groupID == group.id }
    }

    /// Makes the rules hold again after tabs changed: pinned tabs and tabs of unknown groups lose their group,
    /// each group's tabs become adjacent (at the place of its first one), and groups left empty are removed.
    /// Callers report the change (session, extensions).
    func normalizeGroups() {
        let known = Set(groups.map(\.id))
        for tab in tabs where tab.isPinned || (tab.groupID.map { !known.contains($0) } ?? false) { tab.groupID = nil }
        let order = TabGroups.contiguousOrder(groupSlots)
        if order != Array(tabs.indices) { tabs = order.map { tabs[$0] } }
        let live = Set(tabs.compactMap(\.groupID))
        if groups.contains(where: { !live.contains($0.id) }) { groups.removeAll { !live.contains($0.id) } }
        if let renaming = renamingGroupID, !groups.contains(where: { $0.id == renaming }) { renamingGroupID = nil }
        normalizeSplits()
    }

    /// Session restore: the saved groups, for tabs that were appended with their `groupID`s.
    func restoreGroups(_ records: [TabGroupRecord]) {
        groups = records.compactMap(TabGroup.init(record:))
        normalizeGroups()
    }

    /// Groups `tabs` (pinned ones are skipped) into a new group, adjacent at the first one's place. Nil when no
    /// unpinned tab is left. The colour is the first one no other group in this window uses.
    @discardableResult
    func createGroup(with members: [Tab], name: String = "", color: TabGroupColor? = nil) -> TabGroup? {
        let members = tabs.filter { tab in !tab.isPinned && members.contains { $0 === tab } }
        guard !members.isEmpty else { return nil }
        let used = Set(groups.map(\.color))
        let group = TabGroup(name: name, color: color ?? TabGroupColor.allCases.first { !used.contains($0) } ?? .grey)
        let before = tabs
        groups.append(group)
        for tab in members { tab.groupID = group.id }
        normalizeGroups()
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
        return group
    }

    /// Add Tab to New Group: groups `tab` alone and opens the new group's name field, as Chrome opens its editor.
    func addToNewGroup(_ tab: Tab) {
        if let group = createGroup(with: [tab]) { renamingGroupID = group.id }
    }

    /// A new tab page right after the group's last tab, inside the group (the group opens if it was collapsed).
    func newTab(in group: TabGroup) {
        guard let last = tabs(in: group).last else { return }
        group.isCollapsed = false
        let page = URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
        let tab = newTab(url: page, after: last)
        tab.opener = nil
        add(tab, to: group)
        if page == nil { focusAddress() }
    }

    /// Moves `tab` to the end of the group's tabs.
    func add(_ tab: Tab, to group: TabGroup) {
        guard !tab.isPinned, groups.contains(where: { $0 === group }),
              let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let before = tabs
        tabs.remove(at: from)
        tab.groupID = group.id
        tabs.insert(tab, at: tabs.lastIndex { $0.groupID == group.id }.map { $0 + 1 } ?? min(from, tabs.count))
        if group.isCollapsed, tab.id == selectedID { group.isCollapsed = false }
        normalizeGroups()
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
    }

    /// Takes `tab` out of its group, to just after the group's last tab.
    func removeFromGroup(_ tab: Tab) {
        guard let old = group(of: tab), let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let before = tabs
        tabs.remove(at: from)
        tab.groupID = nil
        tabs.insert(tab, at: tabs.lastIndex { $0.groupID == old.id }.map { $0 + 1 } ?? from)
        normalizeGroups()
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
    }

    /// Dissolves the group; its tabs stay where they are.
    func ungroup(_ group: TabGroup) {
        for tab in tabs(in: group) { tab.groupID = nil }
        normalizeGroups()
        AppModel.shared.sessionChanged()
    }

    /// Closes the group's tabs, one by one into the recently closed list. A window left with no tabs closes.
    func closeGroup(_ group: TabGroup) {
        let members = tabs(in: group)
        // Select a tab that stays first, so closing the selected one doesn't wake neighbours that are about to close too.
        if members.contains(where: { $0.id == selectedID }), let outside = nearestTab(outside: group, visibleOnly: true) ?? nearestTab(outside: group, visibleOnly: false) { select(outside) }
        for tab in members { close(tab) }
    }

    func toggleCollapsed(_ group: TabGroup) {
        hoveredTabID = nil
        if group.isCollapsed {
            group.isCollapsed = false
        } else {
            // The selected tab would vanish with its group: another visible tab takes the selection, and with none
            // the group stays open.
            if selectedTab.map({ $0.groupID == group.id }) == true {
                guard let other = nearestTab(outside: group, visibleOnly: true) else { return }
                select(other)
            }
            group.isCollapsed = true
        }
        AppModel.shared.sessionChanged()
    }

    /// The tab closest to the selected one that isn't in `group`, optionally only among tabs shown in the strip.
    private func nearestTab(outside group: TabGroup, visibleOnly: Bool) -> Tab? {
        guard let selected = tabs.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let candidates = tabs.indices.filter { index in
            let tab = tabs[index]
            return tab.groupID != group.id && !(visibleOnly && self.group(of: tab)?.isCollapsed == true)
        }
        return candidates.min { abs($0 - selected) < abs($1 - selected) }.map { tabs[$0] }
    }

    func renameGroup(_ group: TabGroup, to name: String) {
        group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if renamingGroupID == group.id { renamingGroupID = nil }
        AppModel.shared.sessionChanged()
    }

    func setColor(_ color: TabGroupColor, of group: TabGroup) {
        group.color = color
        AppModel.shared.sessionChanged()
    }

    /// Moves the group's tabs to a new window, where they form the same group, expanded.
    func moveGroupToNewWindow(_ group: TabGroup) {
        let members = tabs(in: group)
        guard !members.isEmpty else { return }
        let controller = AppModel.shared.openWindow(isPrivate: isPrivate, profile: profileID, moving: members)
        let moved = TabGroup(id: group.id, name: group.name, color: group.color)
        controller.model.groups = [moved]
        for tab in members { tab.groupID = moved.id }
        controller.model.normalizeGroups()
        AppModel.shared.sessionChanged()
    }

    // MARK: - Renaming

    /// Rename Tab…: the user's title for `tab`; empty or nil goes back to the page's title.
    func rename(_ tab: Tab, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The page's own title as a name would stop following navigation: that is no custom name.
        tab.customTitle = trimmed.isEmpty || trimmed == tab.title ? nil : trimmed
        if renamingTabID == tab.id { renamingTabID = nil }
        AppModel.shared.sessionChanged()
    }

    // MARK: - Moving between windows (`AppModel.move`)

    /// Takes `tab` out for another window. It keeps its web view, history and state. A selected tab hands the
    /// selection to its neighbour; a window left empty stays open for the caller to close once the tab has arrived.
    func detach(_ tab: Tab) -> Int? {
        if tab === previewSource { closePreview() }
        guard let index = tabs.firstIndex(where: { $0 === tab }) else {
            guard let home = stashedSpace(of: tab) else { return nil }
            let offset = tabOffset(ofSpace: home.id)
            let local = withSpace(home.id) {
                let local = tabs.firstIndex { $0 === tab } ?? 0
                tabs.removeAll { $0 === tab }
                normalizeGroups()
                if selectedID == tab.id { selectedID = tabs.last?.id }
                return local
            }
            return offset + local
        }
        let offset = tabOffset(ofSpace: activeSpaceID)
        let wasSelected = tab.id == selectedID
        if renamingTabID == tab.id { renamingTabID = nil }
        tabs.remove(at: index)
        normalizeGroups()
        if wasSelected {
            if tabs.isEmpty {
                selectedID = nil
                showSpaceWithTabs()
            } else {
                select(nearestVisibleTab(to: min(index, tabs.count - 1)))
            }
        }
        return index + offset
    }

    /// A tab may only move into a window of the same profile and privacy: its web view carries that profile's cookies.
    /// A tab not in any window yet has no profile and fits where its privacy does.
    func canAccept(_ tab: Tab) -> Bool {
        tab.isPrivate == isPrivate && (tab.browser.map { $0.profileID == profileID } ?? true)
    }

    /// Puts a tab from another window at `index`, clamped to its side of the pinned boundary. Not selected.
    /// Refused (false) when `canAccept` says no.
    @discardableResult
    func adopt(_ tab: Tab, at index: Int) -> Bool {
        guard canAccept(tab) else { return false }
        tab.browser = self
        tab.returnsToOpener = false
        if let opener = tab.opener, !allTabs.contains(where: { $0 === opener }) { tab.opener = nil }
        let boundary = TabOrder.pinBoundary(tabs.map(\.isPinned))
        let to = outsideSplits(tab.isPinned ? min(max(index, 0), boundary) : min(max(index, boundary), tabs.count), in: tabs, moving: tab)
        tabs.insert(tab, at: to)
        // The group stays behind unless this window has it (`moveGroupToNewWindow` gives it over afterwards).
        normalizeGroups()
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
        if let link = SettingsLink.parse(input) {
            openSettings(link)
            return
        }
        guard let url = AddressResolver(searchTemplate: config.searchTemplate).resolve(input) else { return }
        go(to: url, typed: true)
    }

    /// Shows Settings in this window: its settings tab moves to `pane` and is selected, or a new one opens after the
    /// selected tab. A window can hold more than one settings tab (Duplicate Tab); the first one is used.
    func showSettings(pane: SettingsPane) {
        if let tab = allTabs.first(where: { $0.settingsPane != nil }) {
            showPane(pane, in: tab)
            select(tab)
        } else {
            insert(Tab(url: pane.url, isPrivate: isPrivate), after: selectedTab, select: true)
        }
    }

    /// Moves the settings tab `tab` to `pane`. Its address follows, so the field and the session do too.
    func showPane(_ pane: SettingsPane, in tab: Tab) {
        tab.load(pane.url)
        SettingsPane.remembered = pane
        tabURLChanged(tab)
        // A click in the sidebar ends address editing, as a click on a page does. The field is left before the new
        // pane's address goes in: written while it still had focus, the change read as typing and opened the
        // suggestions over the pane.
        if tab.id == selectedID, let url = tab.url {
            if isEditingAddress {
                isEditingAddress = false
                controller?.window?.makeFirstResponder(nil)
            }
            suggestions.dismiss()
            addressText = Self.displayString(url)
        }
    }

    /// A settings address typed into the field: Settings opens (on its pane) and the field shows the tab's page again.
    private func openSettings(_ link: SettingsLink) {
        AppModel.shared.showSettings(pane: link.pane.flatMap { SettingsPane(rawValue: $0.rawValue) })
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
            guard let window = AppModel.shared.windows.first(where: { $0.model.allTabs.contains { $0.id == id } }),
                  let tab = window.model.allTabs.first(where: { $0.id == id }) else { return }
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
        if let written = addressWrittenByPaddle {
            addressWrittenByPaddle = nil
            if new == written { return nil }
        }
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
        // The preview isn't in the address field or the session; extensions know it (`extensionTabs`).
        if tab.isPreview {
            extensionHost?.tabChanged(tab, .URL)
            return
        }
        if tab.id == selectedID { syncAddress() }
        extensionHost?.tabChanged(tab, .URL)
        AppModel.shared.sessionChanged()
    }

    func syncAddress() {
        guard !isEditingAddress else { return }
        addressText = selectedTab?.url.map(Self.displayString) ?? ""
    }

    /// ⌘L and New Tab: the window's address field, or in a multi view the focused pane's.
    func focusAddress() {
        if let selected = selectedTab, split(of: selected) != nil {
            paneAddressFocusRequest += 1
            return
        }
        focusAddressRequest += 1
    }

    /// The address field's text for `url`: empty for a blank page and an extension's New Tab page, as for Paddle's.
    static func displayString(_ url: URL) -> String {
        url.absoluteString == "about:blank" || AppModel.shared.isNewTabOverridePage(url) ? "" : DisplayURL.string(url)
    }

    // MARK: - Find

    func showFind() {
        if selectedTab?.settingsPane != nil {
            settingsSearchFocusRequest += 1
            return
        }
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
        func saved(_ tabs: [Tab], _ groups: [TabGroup], _ selectedID: UUID?, frame: String? = nil, space: SpaceRecord? = nil, others: [SpaceRecord] = [], spaceIndex: Int? = nil, layouts: [PaneLayout] = []) -> WindowRecord {
            WindowRecord.saving(
                tabs, selected: { $0.id == selectedID }, isSaved: { $0.sourceHTML == nil }, record: \.record,
                frame: frame, groups: groups.map(\.record),
                profile: profileID == ProfileStore.defaultID ? nil : profileID, space: space, otherSpaces: others,
                spaceIndex: spaceIndex, layouts: layouts
            )
        }
        var others: [SpaceRecord] = []
        for space in spaces where space.id != activeSpaceID {
            let stash = stashes[space.id] ?? Stash()
            let part = saved(stash.tabs, stash.groups, stash.selectedID)
            others.append(space.record(
                tabs: part.tabs, selectedIndex: part.selectedIndex, groups: part.groups,
                layouts: Self.records(of: stash.splits, in: stash.tabs)
            ))
        }
        return saved(
            tabs, groups, selectedID, frame: controller?.window.map { NSStringFromRect($0.frame) },
            space: activeSpace.record(), others: others,
            spaceIndex: spaces.count > 1 ? spaces.firstIndex { $0.id == activeSpaceID } : nil,
            layouts: Self.records(of: splits, in: tabs)
        )
    }
}

// MARK: - Control bridge

extension BrowserModel {
    /// Space `id`'s tabs in strip order, for a hidden space too.
    func tabs(inSpace id: String) -> [Tab] {
        id == activeSpaceID ? tabs : stashes[id]?.tabs ?? []
    }

    /// The group `tab` is in, whichever space holds it.
    func anyGroup(of tab: Tab) -> TabGroup? {
        guard let id = tab.groupID else { return nil }
        return (groups + stashes.values.flatMap(\.groups)).first { $0.id == id }
    }
}
