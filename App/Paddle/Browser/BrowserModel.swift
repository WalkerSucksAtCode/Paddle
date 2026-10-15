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
    /// The active space's tab groups. Each group's tabs are adjacent in `tabs`, and a group with no tabs is removed.
    var groups: [TabGroup] = []
    /// The active space's split views. Each pairs two adjacent tabs of the same group (or none); `normalizeSplits` ends
    /// the ones a change breaks.
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
    var isEditingAddress = false
    /// Where the address field and its suggestion list are, in the window's SwiftUI coordinates (top-left
    /// origin), for `BrowserWindowController`'s click-outside check.
    @ObservationIgnored var addressFieldFrame: CGRect = .zero
    /// The unfocused side of a split in window coordinates (zero when not split or too narrow); a click in it focuses it.
    @ObservationIgnored var splitUnfocusedFrame: CGRect = .zero
    @ObservationIgnored var suggestionsFrame: CGRect = .zero
    /// Incremented to ask the view to focus the address field.
    var focusAddressRequest = 0
    /// Bumped by Find… on a Settings tab: the Settings search field takes focus and selects its text.
    var settingsSearchFocusRequest = 0

    /// The address-bar dropdown.
    let suggestions = AddressSuggestions()

    /// Search Tabs… (Shift-Cmd-A): the popover on the tab strip.
    var tabSearchVisible = false

    /// The toolbar's downloads popover is open (Show Downloads, the toolbar button and the menu button drive it).
    var downloadsVisible = false

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
        var select = select
        // A link from a tab of a hidden space lands in that space, behind the scenes.
        if let anchor, !tabs.contains(where: { $0 === anchor }), let home = stashedSpace(of: anchor) {
            withSpace(home.id) { place(tab, after: anchor) }
            select = false
        } else {
            place(tab, after: anchor)
        }
        extensionHost?.tabOpened(tab)
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

    /// `index` (an insertion point in `list`) moved out of the middle of any split `tab` isn't part of, to just after it.
    private func outsideSplits(_ index: Int, in list: [Tab], moving tab: Tab) -> Int {
        guard split(of: tab) == nil else { return index }
        var index = index
        for pair in splits {
            guard let l = list.firstIndex(where: { $0.id == pair.leftID }), let r = list.firstIndex(where: { $0.id == pair.rightID }),
                  r == l + 1, index > l, index <= r else { continue }
            index = r + 1
        }
        return index
    }

    func select(_ tab: Tab) {
        // A tab of another space: show that space first.
        if !tabs.contains(where: { $0 === tab }), let home = stashedSpace(of: tab) {
            switchToSpace(home.id, selecting: tab)
            return
        }
        activate(tab, previous: selectedTab)
    }

    private func activate(_ tab: Tab, previous: Tab?) {
        // Selecting any tab but the one under the preview closes it (another tab, a space switch, a popup).
        if preview != nil, tab !== previewSource { closePreview() }
        let now = Date()
        if let previous, previous !== tab {
            previous.lastActive = now
            previous.hoveredLink = nil
            // Once the user has moved on, closing a popup no longer jumps back to its opener (as in Chrome).
            previous.returnsToOpener = false
        }
        selectedID = tab.id
        if let group = group(of: tab), group.isCollapsed { group.isCollapsed = false }
        tab.lastActive = now
        tab.wake()
        // The other side of a split is on screen too.
        if let partner = partner(of: tab) {
            partner.lastActive = now
            partner.wake()
        }
        if previous !== tab { extensionHost?.tabActivated(tab, previous: previous) }
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
                select(nearestVisibleTab(to: min(index, tabs.count - 1)))
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
        // Landing on a side of a split that `tab` isn't in goes to the pair's far edge, so the split stays whole.
        var dest = to
        if split(of: tab) == nil, let pair = split(of: target),
           let l = tabs.firstIndex(where: { $0.id == pair.leftID }), let r = tabs.firstIndex(where: { $0.id == pair.rightID }) {
            dest = from < to ? max(l, r) : min(l, r)
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
            splits = Self.splits(from: record.splits, in: restored)
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

    // MARK: - Split view

    /// Two adjacent tabs shown side by side. The selected one is the focused side.
    struct Split: Identifiable, Equatable {
        let id = UUID()
        var leftID: UUID
        var rightID: UUID
        /// The left side's share of the width (`SplitRecord.ratioRange`).
        var ratio = 0.5

        /// The split with its tabs named by `Tab.id`, for the rules in PaddleCore.
        var record: SplitRecord { SplitRecord(left: leftID.uuidString, right: rightID.uuidString, ratio: ratio) }
    }

    /// The split `tab` is in; the active space's only.
    func split(of tab: Tab) -> Split? {
        splits.first { $0.leftID == tab.id || $0.rightID == tab.id }
    }

    /// The other tab of `tab`'s split.
    func partner(of tab: Tab) -> Tab? {
        guard let split = split(of: tab) else { return nil }
        let id = split.leftID == tab.id ? split.rightID : split.leftID
        return tabs.first { $0.id == id }
    }

    /// The tabs on screen in left-to-right order: the selected tab and its partner, else just the selected one.
    var visibleTabs: [Tab] {
        guard let selected = selectedTab else { return [] }
        guard let split = split(of: selected), let partner = partner(of: selected) else { return [selected] }
        return split.leftID == selected.id ? [selected, partner] : [partner, selected]
    }

    /// On screen: a side of what `visibleTabs` shows, or the link preview over it (so its dialogs show).
    func isVisible(_ tab: Tab) -> Bool {
        tab === preview || visibleTabs.contains { $0 === tab }
    }

    /// Splits `a` and `b`: `b` moves to just right of `a` (into `a`'s group, or none). Refused for pinned tabs, the same
    /// tab, or tabs not both in this window's active space. Either tab's earlier split ends.
    func makeSplit(_ a: Tab, with b: Tab) {
        guard a !== b, !a.isPinned, !b.isPinned,
              tabs.contains(where: { $0 === a }), let from = tabs.firstIndex(where: { $0 === b }) else { return }
        splits.removeAll { $0.leftID == a.id || $0.rightID == a.id || $0.leftID == b.id || $0.rightID == b.id }
        let before = tabs
        tabs.remove(at: from)
        b.groupID = a.groupID
        let at = tabs.firstIndex { $0 === a } ?? tabs.count
        tabs.insert(b, at: at + 1)
        normalizeGroups()
        splits.append(Split(leftID: a.id, rightID: b.id))
        a.lastActive = Date()
        a.wake()
        b.lastActive = Date()
        b.wake()
        if selectedID != a.id && selectedID != b.id { select(a) }
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
    }

    /// Ends the split `tab` is in; both tabs stay where they are.
    func endSplit(of tab: Tab) {
        guard let split = split(of: tab) else { return }
        splits.removeAll { $0.id == split.id }
        AppModel.shared.sessionChanged()
    }

    /// Tabs > Split View: ends the selected tab's split; else splits it with the next tab in the strip (not pinned, not
    /// in a split, same group), or with a new New Tab page after it, which is then focused.
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

    /// Tabs > Swap Sides: the two tabs trade places; the focused tab stays focused.
    func swapSplitSides() {
        guard let selected = selectedTab, let split = split(of: selected),
              let l = tabs.firstIndex(where: { $0.id == split.leftID }), tabs.indices.contains(l + 1), tabs[l + 1].id == split.rightID,
              let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        let before = tabs
        tabs.swapAt(l, l + 1)
        splits[at].leftID = split.rightID
        splits[at].rightID = split.leftID
        splits[at].ratio = SplitRecord.clamped(1 - split.ratio)
        reportMoves(from: before)
        AppModel.shared.sessionChanged()
    }

    /// Tabs > Focus Other Side: selects the partner, which becomes the focused side.
    func focusOtherSplitSide() {
        guard let selected = selectedTab, let partner = partner(of: selected) else { return }
        select(partner)
    }

    /// Moves the divider: `ratio` is the left side's share, kept within `SplitRecord.ratioRange`.
    func setSplitRatio(_ ratio: Double, for split: Split) {
        guard let at = splits.firstIndex(where: { $0.id == split.id }) else { return }
        let clamped = SplitRecord.clamped(ratio)
        guard splits[at].ratio != clamped else { return }
        splits[at].ratio = clamped
        AppModel.shared.sessionChanged()
    }

    /// Ends the splits the tab order no longer supports (a side closed, moved, pinned, regrouped or separated).
    private func normalizeSplits() {
        guard !splits.isEmpty else { return }
        let kept = SplitRules.normalized(
            splits: splits.map(\.record),
            tabs: tabs.map { SplitTab(id: $0.id.uuidString, groupID: $0.groupID?.uuidString, isPinned: $0.isPinned) }
        )
        let keptLeft = Set(kept.map(\.left))
        if kept.count != splits.count { splits = splits.filter { keptLeft.contains($0.leftID.uuidString) } }
    }

    /// Session restore: the active space's saved splits, for tabs already in `tabs`.
    func restoreSplits(_ records: [SplitRecord]) {
        splits = Self.splits(from: records, in: tabs)
        normalizeSplits()
    }

    /// Splits named by session id; the ones whose tabs aren't in `tabs` are skipped.
    private static func splits(from records: [SplitRecord], in tabs: [Tab]) -> [Split] {
        records.compactMap { record in
            guard let left = tabs.first(where: { $0.sessionKey == record.left }),
                  let right = tabs.first(where: { $0.sessionKey == record.right }) else { return nil }
            return Split(leftID: left.id, rightID: right.id, ratio: record.ratio)
        }
    }

    /// The saved form of `splits`, naming tabs by session id. Splits with a tab that isn't saved (View Source) are skipped.
    private static func records(of splits: [Split], in tabs: [Tab]) -> [SplitRecord] {
        func key(_ id: UUID) -> String? { tabs.first { $0.id == id && $0.sourceHTML == nil }?.sessionKey }
        return splits.compactMap { split in
            guard let left = key(split.leftID), let right = key(split.rightID) else { return nil }
            return SplitRecord(left: left, right: right, ratio: split.ratio)
        }
    }

    // MARK: - Link preview

    /// The link preview (⌥-click): a page over the content area, its own `Tab` with `isPreview` set and never in `tabs`
    /// or `allTabs`, so no tab walk (strip, session, sleep policy, memory sampling, tab search, Reopen Closed Tab,
    /// extensions, the bridge's tab lists) sees it. One per window; nil when none shows.
    private(set) var preview: Tab?
    /// The tab under the preview, where its links and popups open and next to which it becomes a tab.
    @ObservationIgnored private(set) weak var previewSource: Tab?

    /// Open in Split View is offered: the tab underneath is in this space, not pinned and not split already. The new
    /// tab lands next to it in its group, so the split rules accept the pair.
    var canSplitPreview: Bool {
        guard preview != nil, let source = previewSource, tabs.contains(where: { $0 === source }) else { return false }
        return !source.isPinned && split(of: source) == nil
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
        controller?.focusWebView()
    }

    /// Closes the preview and drops its web view (delegate, observers and all), so its WebContent process can exit.
    /// It goes nowhere: not into Reopen Closed Tab, never into the session. The keyboard goes back to the tab.
    func closePreview() {
        guard let tab = preview else { return }
        preview = nil
        previewSource = nil
        tab.sleep()
        tab.opener = nil
        controller?.focusWebView()
    }

    /// Open as Tab (`split` false) or Open in Split View: the preview's own tab, web view and all (no reload; history,
    /// scroll and form input kept), goes into the strip after the tab underneath through the usual insert, so
    /// extensions hear of it and the session saves it, and is selected. With `split` and `canSplitPreview` it is split
    /// with that tab, on the right.
    func openPreviewAsTab(split: Bool) {
        guard let tab = preview else { return }
        let source = previewSource.flatMap { source in tabs.contains { $0 === source } ? source : nil } ?? selectedTab
        let partner = split && canSplitPreview ? source : nil
        preview = nil
        previewSource = nil
        tab.isPreview = false
        insert(tab, after: source, select: true)
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
    private func normalizeGroups() {
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
    /// Returns the tab's old index.
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
        // The preview isn't in the address field, the session or extensions' tabs.
        if tab.isPreview { return }
        if tab.id == selectedID { syncAddress() }
        extensionHost?.tabChanged(tab, .URL)
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
        func saved(_ tabs: [Tab], _ groups: [TabGroup], _ selectedID: UUID?, frame: String? = nil, space: SpaceRecord? = nil, others: [SpaceRecord] = [], spaceIndex: Int? = nil, splits: [SplitRecord] = []) -> WindowRecord {
            WindowRecord.saving(
                tabs, selected: { $0.id == selectedID }, isSaved: { $0.sourceHTML == nil }, record: \.record,
                frame: frame, groups: groups.map(\.record),
                profile: profileID == ProfileStore.defaultID ? nil : profileID, space: space, otherSpaces: others,
                spaceIndex: spaceIndex, splits: splits
            )
        }
        var others: [SpaceRecord] = []
        for space in spaces where space.id != activeSpaceID {
            let stash = stashes[space.id] ?? Stash()
            let part = saved(stash.tabs, stash.groups, stash.selectedID)
            others.append(space.record(
                tabs: part.tabs, selectedIndex: part.selectedIndex, groups: part.groups,
                splits: Self.records(of: stash.splits, in: stash.tabs)
            ))
        }
        return saved(
            tabs, groups, selectedID, frame: controller?.window.map { NSStringFromRect($0.frame) },
            space: activeSpace.record(), others: others,
            spaceIndex: spaces.count > 1 ? spaces.firstIndex { $0.id == activeSpaceID } : nil,
            splits: Self.records(of: splits, in: tabs)
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
