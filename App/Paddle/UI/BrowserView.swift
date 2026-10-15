import AppKit
import PaddleCore
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    let app: AppModel

    /// The strip under the toolbar for config.json: a file that doesn't parse, else the values that fell back to
    /// their defaults (at most three paths named).
    private var configNotice: String? {
        if let error = app.configError { return error }
        let warnings = app.configWarnings
        guard !warnings.isEmpty else { return nil }
        let paths = warnings.prefix(3).map { $0.path.joined(separator: ".") }.joined(separator: ", ")
        let more = warnings.count > 3 ? ", …" : ""
        return "config.json: \(app.configWarningPhrase) (\(paths)\(more)). Settings > Advanced lists them."
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
                .frame(height: 38)
            NavigationBar(model: model, app: app)
                // The suggestion dropdown hangs below the bar, over the page and the bookmarks bar.
                .zIndex(1)
            // An empty bar takes a row for nothing; ⌘D fills it and it appears.
            if app.showBookmarksBar, !app.bookmarks.tree.bar.isEmpty {
                BookmarksBar(app: app)
            }
            if let notice = configNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if let banner = app.extensions.bannerText {
                HStack(alignment: .top, spacing: 8) {
                    Label(banner, systemImage: "puzzlepiece.extension")
                        .font(.system(size: 11))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        app.extensions.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            // A Chrome Web Store or addons.mozilla.org detail page: offer to install it. Paddle's own bar; nothing runs in the page.
            if let tab = model.selectedTab, let url = tab.url, let link = StoreLink.isStoreDetailPage(url) {
                StoreInstallBar(link: link, pageTitle: tab.title, model: model)
            }
            if model.findVisible, model.selectedTab?.settingsPane == nil {
                FindBar(model: model)
            }
            Divider()
            content
        }
        .background(.bar)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.windowTitle, initial: true) { _, title in model.controller?.window?.title = title }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = model.selectedTab, tab.settingsPane != nil {
            SettingsTabView(tab: tab, browser: model)
                .id(tab.id)
        } else if let tab = model.selectedTab, let blocked = tab.httpsOnlyBlocked {
            HTTPSOnlyNotice(tab: tab, url: blocked)
                .id(blocked)
        } else if let tab = model.selectedTab, tab.url != nil {
            WebContainer(tab: tab, generation: tab.generation)
                .overlay(alignment: .bottomLeading) { LinkStatusBubble(tab: tab) }
        } else {
            StartPage()
        }
    }
}

// MARK: - Link status

/// The address of the link under the pointer. A separate view so hovering redraws only this.
private struct LinkStatusBubble: View {
    let tab: Tab

    var body: some View {
        if let link = tab.hoveredLink {
            GeometryReader { geometry in
                Text(link.absoluteString)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    // Background before the width cap, so the bubble fits a short address instead of spanning 60 %.
                    .background(.regularMaterial, in: UnevenRoundedRectangle(topTrailingRadius: 6))
                    .overlay(UnevenRoundedRectangle(topTrailingRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(maxWidth: geometry.size.width * 0.6, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @Bindable var model: BrowserModel
    @Namespace private var rotor

    /// Room for the traffic lights.
    private let leadingInset: CGFloat = 78
    private let pinnedWidth: CGFloat = 40

    /// One thing in the strip: a group's label or a tab. The tabs of a collapsed group are left out.
    private struct StripItem: Identifiable {
        var group: TabGroup?
        var tab: Tab?
        var id: UUID { group?.id ?? tab?.id ?? UUID() }
    }

    /// The strip in order: a label before each group's first tab, and no tabs of collapsed groups.
    private var stripItems: [StripItem] {
        var items: [StripItem] = []
        var lastGroup: UUID?
        for tab in model.tabs {
            if let group = model.group(of: tab) {
                if group.id != lastGroup { items.append(StripItem(group: group)) }
                if !group.isCollapsed { items.append(StripItem(tab: tab)) }
            } else {
                items.append(StripItem(tab: tab))
            }
            lastGroup = tab.groupID
        }
        return items
    }

    private func labelWidth(_ group: TabGroup) -> CGFloat {
        TabGroupLabel.width(for: group, count: model.tabs(in: group).count, renaming: model.renamingGroupID == group.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let items = stripItems
            let pinnedCount = CGFloat(model.tabs.filter(\.isPinned).count)
            let shownUnpinned = CGFloat(items.filter { $0.tab.map { !$0.isPinned } ?? false }.count)
            let labelsWidth = items.reduce(CGFloat(0)) { $0 + ($1.group.map(labelWidth) ?? 0) }
            let available = geometry.size.width - leadingInset - 44 - pinnedCount * (pinnedWidth + 2) - labelsWidth - 2 * CGFloat(items.filter { $0.tab == nil }.count)
            let width = shownUnpinned == 0 ? 0 : min(240, max(110, available / shownUnpinned - 2))
            let tabsWidth = pinnedCount * pinnedWidth + shownUnpinned * width + labelsWidth + 2 * max(0, CGFloat(items.count) - 1)

            HStack(spacing: 0) {
                Color.clear.frame(width: leadingInset)
                    .popover(isPresented: $model.tabSearchVisible, arrowEdge: .bottom) { TabSearchView(model: model) }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(items) { item in
                                if let group = item.group {
                                    TabGroupLabel(group: group, model: model)
                                } else if let tab = item.tab {
                                    TabButton(tab: tab, model: model, group: model.group(of: tab), isRenaming: model.renamingTabID == tab.id,
                                              width: tab.isPinned ? pinnedWidth : width)
                                        .accessibilityRotorEntry(id: tab.id, in: rotor)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        .background(WindowDragArea())
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The tabs take their own width, so New Tab follows the last tab; the scroll view gets the rest.
                    .frame(width: min(tabsWidth, max(0, geometry.size.width - leadingInset - 44)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tabs")
                    // VoiceOver's rotor lists the tabs with their state ("selected", "asleep", "muted").
                    .accessibilityRotor("Tabs") {
                        ForEach(items.compactMap(\.tab)) { tab in
                            AccessibilityRotorEntry(Text(TabButton.spokenEntry(tab, selected: model.selectedID == tab.id, group: model.group(of: tab))), id: tab.id, in: rotor)
                        }
                    }
                    // With more tabs than fit, keep the selected one on screen (Ctrl-Tab, Cmd-9, new tabs).
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
                Button {
                    model.openNewTabPage()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Tab")
                .accessibilityLabel("New Tab")
                .padding(.leading, 4)
                Spacer(minLength: 12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .background(WindowDragArea())
        }
    }
}

/// Empty tab-strip space acts as the title bar: drag to move the window, double-click to zoom or minimize
/// (whichever System Settings > Desktop & Dock chooses). Browser windows are not movable by the window server
/// (see `BrowserWindowController.init`), so this is the only place a window drag starts.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// `.draggable` only while the tab is not being renamed, so a drag inside the title field selects text.
private struct TabDrag: ViewModifier {
    let id: String
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}

/// The text field for renaming a tab, in the tab itself or (pinned tabs) in a popover. Return or focus loss keeps
/// the edited name (the page's title back when it is empty or unchanged from what was shown); Escape cancels.
private struct TabRenameField: View {
    let tab: Tab
    let model: BrowserModel
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tab name", text: $draft, selection: $selection)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) {
                model.renamingTabID = nil
                return .handled
            }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
            }
            .onAppear {
                draft = tab.displayTitle
                // Next turn, so the click that started the rename can't take the focus straight back.
                DispatchQueue.main.async {
                    focused = true
                    selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                }
            }
    }

    /// Escape clears `renamingTabID` first, so it never lands here.
    private func commit() {
        guard model.renamingTabID == tab.id else { return }
        if draft != tab.displayTitle { model.rename(tab, to: draft) }
        model.renamingTabID = nil
    }
}

private struct TabButton: View {
    let tab: Tab
    let model: BrowserModel
    /// The tab's group and whether its title is being edited, read once by the strip so an unrelated change to
    /// `groups` or `renamingTabID` doesn't redraw every tab.
    let group: TabGroup?
    let isRenaming: Bool
    let width: CGFloat
    @State private var hovering = false
    /// The tab's memory when the pointer arrived, for the tooltip. Read in the hover handler rather than in
    /// `body`, so a new sample doesn't redraw every tab button.
    @State private var hoverMemory: (bytes: UInt64, shared: Bool)?
    @Environment(\.colorScheme) private var scheme

    private var isSelected: Bool { model.selectedID == tab.id }
    /// From this width every tab shows its close button.
    private static let alwaysCloseWidth: CGFloat = 110
    private var audio: AudioIndicator { AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted) }

    var body: some View {
        HStack(spacing: 6) {
            icon
            if !tab.isPinned {
                if isRenaming {
                    TabRenameField(tab: tab, model: model)
                } else {
                    Text(tab.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(!tab.isAsleep || isSelected ? .primary : .secondary)
                        // Alongside the tab's own click, so a single click still selects at once.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.renamingTabID = tab.id })
                }
                Spacer(minLength: 0)
                if audio != .none {
                    Button {
                        model.toggleMute(tab)
                    } label: {
                        Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!Tab.supportsMuting)
                    .help(audio == .muted ? "Unmute Tab" : "Mute Tab")
                    .accessibilityLabel(audio == .muted ? "Unmute Tab" : "Mute Tab")
                }
                // Every tab wide enough for one shows its close button, not only the hovered one; a narrow tab keeps the
                // room for its title and shows it on hover or when selected.
                if hovering || isSelected || width >= Self.alwaysCloseWidth {
                    Button {
                        model.close(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab")
                    .accessibilityLabel("Close Tab")
                }
            }
        }
        .padding(.horizontal, tab.isPinned ? 0 : 8)
        .frame(width: width, height: 28)
        // A pinned tab has no room for a field: its name is edited in a popover.
        .popover(isPresented: Binding(
            get: { tab.isPinned && isRenaming },
            set: { if !$0, model.renamingTabID == tab.id { model.renamingTabID = nil } }
        ), arrowEdge: .bottom) {
            TabRenameField(tab: tab, model: model)
                .padding(8)
                .frame(width: 220)
        }
        .background {
            // The selected tab is lighter than the strip in dark mode and darker in light mode, with an edge, so it
            // stands out by brightness alone: the window background colour it used before matched the strip.
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(isSelected ? 0.14 : hovering ? 0.06 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.primary.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
                }
        }
        // A grouped tab carries its group's colour along the bottom edge, so the group's extent shows.
        .overlay(alignment: .bottom) {
            if let group {
                // 3 pt with a faint edge: the lightest fills (yellow, pink, cyan) alone are under 3:1 against the strip.
                Rectangle().fill(group.color.fill(scheme)).frame(height: 3)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                    .padding(.horizontal, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        // A middle click closes the tab, as in other browsers.
        .overlay(MiddleClickCatcher { model.close(tab) })
        // With keyboard navigation on (System Settings > Keyboard), Tab reaches each tab; Space or Return selects it.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            if isRenaming { return .ignored }
            model.select(tab)
            return .handled
        }
        // One element for VoiceOver: the title, its state as the value, and the tab's actions.
        // While the title is a text field in the tab, VoiceOver reaches the field instead.
        .accessibilityElement(children: isRenaming && !tab.isPinned ? .contain : .ignore)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isRenaming && !tab.isPinned ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(tab) }
        .accessibilityAction(named: "Close Tab") { model.close(tab) }
        .accessibilityAction(named: tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
        .accessibilityAction(named: tab.isMuted ? "Unmute Tab" : "Mute Tab") {
            if Tab.supportsMuting { model.toggleMute(tab) }
        }
        .onHover { inside in
            hovering = inside
            if inside { hoverMemory = tab.memoryBytes.map { ($0, tab.sharesProcess) } }
        }
        .help(tooltip)
        .modifier(TabDrag(id: tab.id.uuidString, enabled: !isRenaming))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)),
                  let dragged = model.tabs.first(where: { $0.id == id }) else { return false }
            return model.move(dragged, onto: tab)
        }
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab) }
            Button("Rename Tab…") { model.renamingTabID = tab.id }
            Button("Duplicate Tab") { model.duplicate(tab) }
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { model.toggleMute(tab) }
                .disabled(!Tab.supportsMuting)
            Button("Put Tab to Sleep") { model.sleep(tab) }
                .disabled(!tab.isAwake || isSelected)
            if !tab.isPinned {
                Divider()
                Button("Add Tab to New Group") { model.addToNewGroup(tab) }
                let others = model.groups.filter { $0.id != tab.groupID }
                if !others.isEmpty {
                    Menu("Add Tab to Group") {
                        ForEach(others) { group in
                            Button(group.name.isEmpty ? "Unnamed (\(group.color.title))" : group.name) { model.add(tab, to: group) }
                        }
                    }
                }
                if tab.groupID != nil { Button("Remove from Group") { model.removeFromGroup(tab) } }
            }
            Divider()
            Button("Close Tab") { model.close(tab) }
            Button("Close Other Tabs") { model.closeOthers(tab) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isCapturing {
                Image(systemName: "video.fill")
            } else if tab.settingsPane != nil {
                Image(systemName: "gearshape")
            } else if !tab.isAwake {
                Glyph(name: "surf-tab-sleep")
            } else {
                FaviconView(url: tab.url, fallback: tab.isPinned ? "pin.fill" : "globe")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
        // Pinned tabs have no room for a button: a small speaker on the icon; mute from the context menu.
        .overlay(alignment: .bottomTrailing) {
            if tab.isPinned, audio != .none {
                Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(1)
                    .background(Circle().fill(.background))
                    .offset(x: 5, y: 4)
                    .accessibilityLabel(audio == .muted ? "Muted" : "Playing audio")
            }
        }
    }

    /// "Pinned, asleep, muted": the tab's state as VoiceOver's value. Selection is the trait, not part of it.
    static func spokenState(_ tab: Tab, audio: AudioIndicator) -> String {
        var parts: [String] = []
        if tab.isPinned { parts.append("pinned") }
        if tab.isAsleep { parts.append("asleep") }
        if tab.isFrozen { parts.append("frozen") }
        if tab.isLoading { parts.append("loading") }
        if tab.isCapturing { parts.append("using camera or microphone") }
        switch audio {
        case .playing: parts.append("playing audio")
        case .muted: parts.append("muted")
        case .none: break
        }
        return parts.joined(separator: ", ")
    }

    /// A rotor entry: the title, then "selected" and the state.
    static func spokenEntry(_ tab: Tab, selected: Bool, group: TabGroup? = nil) -> String {
        let audio = AudioIndicator(isPlayingAudio: tab.isPlayingAudio, isMuted: tab.isMuted)
        let grouped = group.map { "in group \($0.name.isEmpty ? "Unnamed" : $0.name)" } ?? ""
        let state = [selected ? "selected" : "", spokenState(tab, audio: audio), grouped].filter { !$0.isEmpty }
        return ([tab.displayTitle] + state).joined(separator: ", ")
    }

    /// The state, plus the group the tab is in.
    private var spokenValue: String {
        let state = Self.spokenState(tab, audio: audio)
        guard let group else { return state }
        let name = group.name.isEmpty ? "Unnamed" : group.name
        return state.isEmpty ? "in group \(name)" : "\(state), in group \(name)"
    }

    private var tooltip: String {
        var lines = [tab.displayTitle]
        if let custom = tab.customTitle, !custom.isEmpty { lines.append("Page: \(tab.title.isEmpty ? (tab.url?.host() ?? "") : tab.title)") }
        if let url = tab.url { lines.append(url.absoluteString) }
        switch audio {
        case .playing: lines.append("Playing audio")
        case .muted: lines.append("Muted")
        case .none: break
        }
        if tab.isAsleep {
            lines.append("Asleep: no memory used. Click to wake.")
        } else if let hoverMemory {
            lines.append("Memory: \(ProcessMemory.format(hoverMemory.bytes))\(hoverMemory.shared ? " (shared with other tabs from this site)" : "")")
        }
        if tab.isFrozen { lines.append("Frozen: paused, shows again without a reload.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Memory readout

/// The toolbar's memory readout: all of Paddle (this tab's share in the tooltip), and the Activity popover. Its own view so a new
/// sample redraws only this label, not the address field and the rest of the toolbar.
private struct MemoryButton: View {
    let app: AppModel
    let model: BrowserModel
    @State private var showActivity = false

    var body: some View {
        Button {
            showActivity.toggle()
        } label: {
            HStack(spacing: 4) {
                Glyph(name: "surf-memory")
                // The widest label, hidden, holds the width: the readout neither truncates nor shifts as it changes.
                ZStack(alignment: .trailing) {
                    Text("8888 MB").hidden().accessibilityHidden(true)
                    Text(label)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .accessibilityLabel("Memory")
        .accessibilityValue(spokenLabel)
        .accessibilityHint("Shows memory and activity details.")
        .popover(isPresented: $showActivity, arrowEdge: .bottom) {
            ActivityView(app: app, browser: model)
        }
    }

    private var label: String { ProcessMemory.format(app.totalWebMemory) }

    private var tooltip: String {
        let total = "Paddle is using \(ProcessMemory.format(app.totalWebMemory))"
        guard let current = model.selectedTab?.memoryBytes.map(ProcessMemory.format) else { return total + ". Click for details." }
        return total + ", this tab \(current). Click for details."
    }

    private var spokenLabel: String {
        let total = "all of Paddle \(ProcessMemory.format(app.totalWebMemory))"
        guard let current = model.selectedTab?.memoryBytes.map(ProcessMemory.format) else { return total }
        return "this tab \(current), \(total)"
    }
}

// MARK: - Navigation bar

private struct NavigationBar: View {
    @Bindable var model: BrowserModel
    let app: AppModel
    @FocusState private var addressFocused: Bool
    @State private var addressSelection: TextSelection?
    /// Set while Paddle itself writes an inline completion, so that edit isn't treated as typing.
    @State private var applyingCompletion = false

    private var tab: Tab? { model.selectedTab }

    var body: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", help: "Back", enabled: tab?.canGoBack == true) { tab?.webView?.goBack() }
            iconButton("chevron.right", help: "Forward", enabled: tab?.canGoForward == true) { tab?.webView?.goForward() }
            iconButton(tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: tab?.isLoading == true ? "Stop" : "Reload", enabled: tab?.url != nil && tab?.settingsPane == nil) {
                if tab?.isLoading == true { tab?.webView?.stopLoading() } else { tab?.reload() }
            }
            if model.isPrivate {
                Label("Private", systemImage: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .help("Private window: no history, no saved session, and cookies and site data are forgotten when the last private window closes.")
            }
            addressField
                .padding(.horizontal, 4)
                .frame(minWidth: 140)
            HStack(spacing: 2) {
                if model.extensionsAllowed {
                    ExtensionToolbar(host: app.extensions, model: model, tab: tab, isPrivate: model.isPrivate, placements: app.config.extensionToolbar)
                }
                if !app.downloads.items.isEmpty {
                    downloadsButton
                }
            }
            .fixedSize()
            if app.config.showTabMemory {
                MemoryButton(app: app, model: model)
                    .fixedSize()
                    .padding(.leading, 4)
            }
            ToolbarMenuButton(model: model)
            .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) { progressBar }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: addressIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityLabel("Connection")
                .accessibilityValue(securityDescription ?? "")
                .accessibilityHidden(securityDescription == nil)
                .help(securityDescription ?? "")
            TextField("Search or enter address", text: $model.addressText, selection: $addressSelection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                // Clear text, not removed, behind the site name: a click still lands in the field and edits the whole
                // address. Not opacity 0, which also drops the field from accessibility.
                .foregroundStyle(siteOnly == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                .overlay(alignment: .leading) {
                    if let siteOnly {
                        Text(siteOnly)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($addressFocused)
                .onSubmit { model.submitAddress() }
                .onChange(of: model.addressText) { old, new in
                    if applyingCompletion {
                        applyingCompletion = false
                        return
                    }
                    guard let completed = model.addressEdited(from: old, to: new) else { return }
                    // Show the completed host with the added part selected, so typing on replaces it.
                    applyingCompletion = true
                    model.addressText = completed.text
                    addressSelection = TextSelection(range: completed.typedEnd..<completed.text.endIndex)
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onExitCommand {
                    // First Escape closes the suggestions, the next one gives up editing.
                    if model.suggestions.isVisible {
                        model.suggestions.dismiss()
                        return
                    }
                    // Really leave the field (also with no page showing); onChange(addressFocused) resyncs.
                    addressFocused = false
                    model.controller?.focusWebView()
                }
            if let url = tab?.url, HistoryStore.isRecordable(url), !addressFocused {
                let bookmarked = app.bookmarks.isBookmarked(url)
                Button {
                    app.bookmarks.toggle(url: url, title: tab?.title ?? "")
                } label: {
                    Glyph(name: "surf-star", active: bookmarked)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(bookmarked ? "Remove Bookmark" : "Bookmark This Page (⌘D)")
                .accessibilityLabel(bookmarked ? "Remove Bookmark" : "Bookmark This Page")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        // Private windows: a faint indigo field (with the "Private" label beside it, not color alone).
        .background(RoundedRectangle(cornerRadius: 8).fill(model.isPrivate ? Color.indigo.opacity(0.16) : Color.primary.opacity(0.07)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.addressFieldFrame = $0 }
        .overlay(alignment: .topLeading) {
            if model.suggestions.isVisible {
                SuggestionList(suggestions: model.suggestions) { model.open($0) }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.suggestionsFrame = $0 }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .offset(y: 32)
            }
        }
        .onChange(of: addressFocused) { _, focused in
            model.isEditingAddress = focused
            if !focused {
                model.suggestions.dismiss()
                model.syncAddress()
            }
        }
        .onChange(of: model.focusAddressRequest) {
            addressFocused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
    }

    /// The site shown in place of the address while the field isn't being edited (`showFullAddress` off): a web
    /// page's host without "www.". Nil shows the whole address: other schemes, or the setting on.
    private var siteOnly: String? {
        guard !addressFocused, !app.config.showFullAddress, let url = tab?.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard model.suggestions.isVisible else { return .ignored }
        model.suggestions.moveHighlight(by: delta)
        return .handled
    }

    /// What the address icon means, for VoiceOver and the tooltip; nil while it is only the search glass.
    private var securityDescription: String? {
        guard let url = tab?.url, !addressFocused else { return nil }
        switch url.scheme {
        case "https": return tab?.isSecure == true ? "Secure" : "Not fully secure: some of this page isn't encrypted"
        case "http": return "Not secure: this page isn't encrypted"
        default: return nil
        }
    }

    private var addressIcon: String {
        guard let url = tab?.url, !addressFocused else { return "magnifyingglass" }
        switch url.scheme {
        case "https": return tab?.isSecure == true ? "lock.fill" : "lock.open"
        case "http": return "exclamationmark.triangle"
        default: return "magnifyingglass"
        }
    }

    private var downloadsButton: some View {
        Button {
            model.downloadsVisible.toggle()
        } label: {
            Glyph(name: "surf-download", size: 16, active: app.downloads.activeCount > 0)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $model.downloadsVisible, arrowEdge: .bottom) {
            DownloadsView(store: app.downloads)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let tab, tab.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * max(0.05, tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.2), value: tab.progress)
            }
            .frame(height: 2)
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Find

private struct FindBar: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find on page", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit { model.find() }
                .onExitCommand { model.hideFind() }
            if model.findNoMatch {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
                .accessibilityLabel("Previous Match")
            Button { model.find() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
                .accessibilityLabel("Next Match")
            Spacer()
            Button("Done") { model.hideFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .onChange(of: model.findText) { model.find() }
        // Each search that finds nothing is announced, not only the first.
        .onChange(of: model.findNoMatch) { _, noMatch in
            if noMatch { AccessibilityNotification.Announcement("Not found").post() }
        }
    }
}

// MARK: - Start page

private struct StartPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Paddle")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Type an address or search in the bar above.")
                .foregroundStyle(.secondary)
            Button("Customize Paddle…") {
                NSWorkspace.shared.open(Paths.support)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Calls `action` on a middle click (button 3) inside it and lets every other click through to the views around it:
/// SwiftUI has no middle-click gesture.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Only middle-button events land here; left and right clicks fall through to the tab.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp: super.hitTest(point)
            default: nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                return super.otherMouseUp(with: event)
            }
            action()
        }
    }
}
