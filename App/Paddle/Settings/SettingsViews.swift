import SwiftUI

/// Settings' panes, in sidebar order. Settings is a tab of a browser window (`SettingsTabView`), addressed as
/// `paddle://settings/<rawValue>`.
enum SettingsPane: String, CaseIterable {
    case general, appearance, profiles, tabsMemory, privacy, sites, extensions, shortcuts, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .profiles: "Profiles"
        case .tabsMemory: "Tabs & Memory"
        case .privacy: "Privacy & Blocking"
        case .sites: "Sites"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var summary: String {
        switch self {
        case .general: "Home page, search engine, start page, and download preferences."
        case .appearance: "Themes, custom theme builder, colors, text size, and accessibility options."
        case .profiles: "Manage separate container profiles, cookies, and browsing data."
        case .tabsMemory: "Tab freezing, automatic memory sleep, and background performance."
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
            "new window in profile", "symbol",
        ]
        case .tabsMemory: [
            "tabs", "memory", "sleep", "freeze", "frozen", "background tabs", "pinned tabs", "sleepPinnedTabs",
            "tabFreezeAfterMinutes", "tabSleepAfterMinutes",
            "maxAwakeTabs", "cpuSleepPercent", "cpu", "sessionHistoryTabs", "back history", "showTabMemory", "toolbar",
            "awake", "linkPreview", "link preview", "audio", "resumeMediaOnSelect", "play the tab",
            "upload", "uploads", "unsaved", "keepPageWorkRunning", "notifications", "live", "keepNotifyingSitesLive",
        ]
        case .privacy: [
            "blocking", "adblock", "ads", "trackers", "content blocking", "contentBlocking", "filter lists", "filterLists",
            "filterUpdateDays", "list updates", "scriptlets", "uBlock Origin", "EasyList", "my rules", "user-filters.txt",
            "https", "httpsOnly", "secure connection", "speculativeLoading", "preconnect", "preload", "warm", "http", "history", "historyDays", "clear history", "cookies", "website data", "site storage",
        ]
        case .sites: [
            "site", "zoom", "JavaScript", "autoplay", "location", "notifications", "camera", "microphone", "downloads", "blocking",
            "user agent", "siteUserAgents", "sitePersonas", "persona", "clear data", "permissions", "this session", "freeze", "keep live",
        ]
        case .extensions: [
            "addons", "extensionsInPrivate", "extensionCompat", "private windows", "permissions", "folder", "memory",
            "compatibility", "reload", "options", "extensionToolbar", "toolbar button", "pin", "pinned", "hide", "puzzle",
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

/// The form style every pane uses: grouped, scrolling inside the pane.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    /// From this width the sections flow into two columns. A grouped form never grows past about 700 pt, so a wide tab
    /// would otherwise be mostly margin.
    private var twoColumnWidth: CGFloat { 1100 }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= twoColumnWidth {
                HStack(alignment: .top, spacing: 0) {
                    column(.left)
                    column(.right)
                }
            } else {
                Form { content }
                    .formStyle(.grouped)
            }
        }
    }

    private enum Half { case left, right }

    /// One column: its own grouped form holding half of the sections, the first half on the left so reading order
    /// stays top to bottom, then left to right. The sections are picked inside the form, so they keep its styling
    /// (switches, trailing values); taken out first, they would lose it.
    private func column(_ half: Half) -> some View {
        Form {
            Group(sections: content) { sections in
                let split = (sections.count + 1) / 2
                ForEach(half == .left ? sections.prefix(split) : sections.dropFirst(split)) { section in
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
    }
}
