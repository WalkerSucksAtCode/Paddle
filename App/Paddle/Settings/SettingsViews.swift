import PaddleCore
import SwiftUI

/// Settings' panes, in sidebar order. Settings is a tab of a browser window (`SettingsTabView`), addressed as
/// `paddle://settings/<rawValue>`.
enum SettingsPane: String, CaseIterable {
    case general, appearance, profiles, tabsMemory, mosaic, privacy, sites, extensions, shortcuts, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .profiles: "Profiles"
        case .tabsMemory: "Tabs & Memory"
        case .mosaic: "Mosaic"
        case .privacy: "Privacy & Blocking"
        case .sites: "Sites"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var summary: String {
        switch self {
        case .general: "Startup, tabs, pages, search engine, trackpad, and download preferences."
        case .appearance: "Themes, custom theme builder, colors, text size, and accessibility options."
        case .profiles: "Separate cookies, history and extensions per profile, and each profile's own settings."
        case .tabsMemory: "Tab freezing, automatic memory sleep, and background performance."
        case .mosaic: "Several tabs at once: layout, pane toolbars, and how a Mosaic behaves in the background."
        case .privacy: "Ad and tracker blocking, filter lists, HTTPS upgrades, and browsing history."
        case .sites: "Per-site permissions for zoom, JavaScript, autoplay, location, and camera."
        case .extensions: "WebExtensions management, permissions, and private window access."
        case .shortcuts: "Custom keyboard shortcuts for menu items and browser actions."
        case .advanced: "Developer tools, configuration editor, and control bridge automation."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .profiles: "person.2"
        case .tabsMemory: "memorychip"
        case .mosaic: "rectangle.split.2x2"
        case .privacy: "hand.raised"
        case .sites: "globe"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "command"
        case .advanced: "gearshape.2"
        }
    }

    var url: URL { URL(string: "paddle://settings/\(rawValue)")! }

    /// The pane Settings opens on when none is named: the one shown last, General before any.
    static var remembered: SettingsPane {
        get { UserDefaults.standard.string(forKey: "settingsPane").flatMap(SettingsPane.init(rawValue:)) ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "settingsPane") }
    }

    /// What the search matches besides the title: the labels and config.json keys each pane shows, and the words
    /// `SettingsLink` takes as aliases.
    var keywords: [String] {
        switch self {
        case .general: [
            "homepage", "newTabPage", "new tab page", "start page", "new windows", "new tabs", "search engine",
            "searchTemplate", "searchSuggestTemplate", "search suggestions", "address", "showFullAddress",
            "bookmarks bar", "default browser", "downloads", "download", "askWhereToDownload", "ask where to download",
            "pinned sites", "speed dial", "frequently visited", "newTabFrequentSites",
            "customize new tab", "feeds", "news", "rss", "atom", "newTabFeeds", "website notifications",
            "newTabNotifications", "newTabHiddenNotifications", "new tab extension", "newTabExtension", "section order", "newTabSections", "reorder",
            "startup", "launch", "onLaunch", "restore", "session", "quit", "askBeforeQuitting", "close window",
            "askBeforeClosingWindow", "other apps", "externalLinks", "links", "new tab position", "newTabPosition",
            "after closing", "afterClosingTab", "background", "cmd-click", "command-click", "openLinksInBackground",
            "trackpad", "swipe", "swipeNavigation", "pinch", "pinchZoom", "keyboard", "tab key", "tabKeyHighlightsLinks",
        ]
        case .appearance: [
            "theme", "dark mode", "light mode", "text size", "font size", "zoom", "contrast", "high contrast",
            "motion", "transparency", "accessibility", "tab layout", "vertical tabs", "sidebar", "tabLayout",
            "highContrastTabs", "themes", "color", "colour", "accent", "accent color", "tint", "chrome tint", "tint strength", "palette",
            "open themes folder", "accentColor", "chromeTint", "chromeTintStrength", "interfaceTextSize", "defaultZoom", "minimumFontSize", "reduceMotion",
            "reduceTransparency", "default zoom", "minimum font size", "reduce motion", "reduce transparency",
            "theme builder", "custom theme", "preset", "create theme", "underline", "links", "underlineLinks", "close button",
            "always show close buttons", "alwaysShowTabCloseButtons", "home button", "showHomeButton", "downloads button", "alwaysShowDownloadsButton",
            "colorblind",
        ]
        case .profiles: [
            "profile", "work", "personal", "container", "containers", "accounts", "separate cookies", "logins",
            "new window in profile", "symbol", "rename", "override", "overrides", "per profile", "profile settings", "global",
        ]
        case .tabsMemory: [
            "tabs", "memory", "sleep", "freeze", "frozen", "background tabs", "pinned tabs", "sleepPinnedTabs",
            "tabFreezeAfterMinutes", "tabSleepAfterMinutes",
            "maxAwakeTabs", "cpuSleepPercent", "cpu", "sessionHistoryTabs", "back history", "showTabMemory", "toolbar",
            "awake", "linkPreview", "link preview", "audio", "resumeMediaOnSelect", "play the tab",
            "upload", "uploads", "unsaved", "keepPageWorkRunning", "notifications", "live", "keepNotifyingSitesLive",
        ]
        case .mosaic: [
            "mosaic", "multi view", "split view", "panes", "tiles", "side by side", "mosaicMaxPanes", "mosaicPaneBars",
            "pane toolbars", "mosaicGap", "gap", "space between", "mosaicMinimumPaneWidth", "mosaicMinimumPaneHeight",
            "smallest pane", "mosaicStaysReady", "stays ready", "instant", "mosaicFreezeAfterMinutes", "mosaicSleepAfterMinutes",
            "freeze", "sleep", "background", "icon", "animation", "motion", "reduce motion", "mosaicAnimation", "speed",
            "mosaicAnimationSpeed", "drag preview", "mosaicLiveDragPreview", "divider", "grip", "mosaicDividerGrips", "snap",
            "mosaicDividerSnapping", "double-click", "mosaicDividerDoubleClick", "corners", "square", "mosaicPaneCorners",
            "focus", "dim", "mosaicFocusMarker", "mosaicDimAmount", "compact", "mosaicToolbarSize", "buttons", "mosaicToolbarButtons",
            "drag", "grip", "handle", "mosaicPaneGrab", "mosaicModifierDrag", "move window", "mosaicWindowDrag", "new tab",
            "mosaicNewTab", "links", "mosaicLinks", "placement", "mosaicNewPanePlacement", "default layout", "mosaicDefaultLayout",
            "re-tile", "arrange", "mosaicAutoArrange",
        ]
        case .privacy: [
            "blocking", "adblock", "ads", "trackers", "content blocking", "contentBlocking", "filter lists", "filterLists",
            "filterUpdateDays", "list updates", "scriptlets", "uBlock Origin", "EasyList", "my rules", "user-filters.txt",
            "https", "httpsOnly", "secure connection", "security", "fraud", "phishing", "malware", "safe browsing", "fraudWarnings", "speculativeLoading", "preconnect", "preload", "warm", "http", "history", "historyDays", "clear history", "cookies", "website data", "site storage",
        ]
        case .sites: [
            "site", "zoom", "JavaScript", "autoplay", "location", "notifications", "camera", "microphone", "downloads", "blocking",
            "user agent", "siteUserAgents", "sitePersonas", "persona", "clear data", "permissions", "this session", "freeze", "keep live",
        ]
        case .extensions: [
            "addons", "extensionsInPrivate", "extensionCompat", "private windows", "permissions", "folder", "memory",
            "compatibility", "reload", "options", "extensionToolbar", "toolbar button", "pin", "pinned", "hide", "puzzle",
            "updates", "update", "extensionUpdates",
        ]
        case .shortcuts: [
            "keyboard", "keys", "key bindings", "shortcut", "command", "menu", "defaults",
        ]
        case .advanced: [
            "developer", "developerTools", "user agent", "userAgentSuffix", "config.json", "problems", "unknown keys",
            "tidy", "user.css", "userscripts", "reveal in finder",
            "bridge", "control bridge", "controlBridge", "controlBridgeScripts", "page scripts", "run_js", "mcp", "claude",
            "automation", "control",
        ]
        }
    }

    /// The panes a search for `query` lists, in sidebar order: those whose title or one keyword contains each
    /// whitespace-separated word of it, ignoring case. An empty query lists them all.
    static func matching(_ query: String) -> [SettingsPane] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return allCases }
        return allCases.filter { pane in
            let fields = [pane.title] + pane.keywords
            return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
    }
}

/// One pane: the banner above the pane, filling the window; forms scroll inside it, tables scroll themselves.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                SettingsBanner(banner: banner, model: model)
            }
            paneHeader
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.title2.weight(.bold))
                Text(pane.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane(model: model)
        case .appearance: AppearancePane(model: model)
        case .profiles: ProfilesPane(model: model)
        case .tabsMemory: TabsMemoryPane(model: model)
        case .mosaic: MosaicPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .sites: SitesPane(model: model)
        case .extensions: ExtensionsPane(model: model)
        case .shortcuts: ShortcutsPane(model: model)
        case .advanced: AdvancedPane(model: model)
        }
    }
}

/// A collapsed group (collapsed until opened) whose whole label opens it, not only the chevron: a plain
/// `DisclosureGroup` in a grouped form answers clicks on its chevron alone. `isExpanded` nil keeps the state here.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    var accessibilityLabel: String?
    @ViewBuilder var content: Content
    @State private var expandedHere = false

    var body: some View {
        let expanded = isExpanded ?? $expandedHere
        DisclosureGroup(isExpanded: expanded) {
            content
        } label: {
            Button(title) { withAnimation { expanded.wrappedValue.toggle() } }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

/// The form style every pane uses: one scroll view across the whole pane (so the wheel scrolls it anywhere), each
/// `Section` a card of its own, the cards flowing into as many columns as the width holds. Each card is its own
/// grouped form, so its rows keep a form's styling (switches, trailing values); the outer scroll view does the
/// scrolling.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            MasonryLayout(minColumnWidth: 380, maxColumns: 4, spacing: 0) {
                Group(sections: content) { sections in
                    ForEach(sections.indices, id: \.self) { index in
                        card(index, hasHeader: !sections[index].header.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    /// The card for the section at `index`. The sections are picked inside the card's form, so they keep its
    /// styling; picked outside it, toggles turn to checkboxes and values lose their trailing place.
    private func card(_ index: Int, hasHeader: Bool) -> some View {
        Form {
            Group(sections: content) { sections in
                if sections.indices.contains(index) {
                    let section = sections[index]
                    Section {
                        section.content
                    } header: {
                        section.header
                    } footer: {
                        section.footer
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        // A grouped form keeps a clear inset above and below its section, more above when the section has no
        // header; trimmed from the layout so the gap between cards is the same either way.
        .padding(.top, hasHeader ? -10 : -24)
        .padding(.bottom, -10)
    }
}

/// Cards in columns, each stacked under the one above it in its column with no row alignment, so cards of different
/// heights leave no holes. Card i goes in column i mod n, in reading order: placing by height instead would move
/// every card below one that grows (a Details opening) to another column. The column count is as many
/// `minColumnWidth` columns as the width holds, up to `maxColumns`.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat
    var maxColumns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for (index, subview) in subviews.enumerated() {
            let column = index % count
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            heights[column] = y + height
        }
        return (frames, heights.max() ?? 0)
    }
}

/// A switch for one true/false key of config.json; its help names the key, then says what it does.
struct ConfigToggle: View {
    let title: String
    let key: PaddleConfig.CodingKeys
    let value: KeyPath<PaddleConfig, Bool>
    let model: SettingsModel
    let help: String

    init(_ title: String, _ key: PaddleConfig.CodingKeys, _ value: KeyPath<PaddleConfig, Bool>, model: SettingsModel, help: String) {
        self.title = title
        self.key = key
        self.value = value
        self.model = model
        self.help = help
    }

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { model.file[keyPath: value] },
            set: { on in Task { await model.saveKey(key, .bool(on)) } }
        ))
        .help("\(key.rawValue) in config.json. \(help)")
        .disabled(model.controlsDisabled)
    }
}
