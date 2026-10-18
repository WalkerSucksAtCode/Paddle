import Foundation

/// Where an extension's toolbar button goes (`extensionToolbar` in config.json).
public enum ExtensionToolbarPlacement: String, Codable, Sendable, CaseIterable {
    case pinned, menu, hidden
}

/// Everything a user can change by editing `config.json`. Missing keys fall back to the defaults below,
/// so a config file only needs the keys it changes. Each key decodes on its own: a value of the wrong type falls back
/// to its default, an object key skips only the entry that is wrong and a list only the item, and
/// `decodeReportingIssues` says which. Only invalid JSON, or a top level that isn't an object, refuses the whole file.
/// Where the tabs show: a strip above the toolbar, or a sidebar.
public enum TabLayout: String, Codable, Sendable, CaseIterable {
    case horizontal, vertical
}

/// Whether the windows are light or dark: follow macOS, or always one.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// Whether websites are forced into dark mode: follow Paddle's appearance, always dark, or off.
public enum DarkModePreference: String, Codable, Sendable, CaseIterable {
    case off, system, always
}

/// How large Paddle's own text (tabs, toolbar, bars) is.
public enum InterfaceTextSize: String, Codable, Sendable, CaseIterable {
    case small, `default`, large, larger

    /// The factor Paddle's chrome text and spacing are multiplied by.
    public var scale: Double {
        switch self {
        case .small: 0.9
        case .default: 1.0
        case .large: 1.15
        case .larger: 1.3
        }
    }
}

/// An accessibility option that follows the macOS setting unless forced on.
public enum AccessibilityPreference: String, Codable, Sendable, CaseIterable {
    case system, always
}

public struct PaddleConfig: Codable, Sendable, Equatable {
    /// Page loaded in a new window. `about:blank` gives an empty page with the address field focused.
    public var homepage: String
    /// Page loaded in a new tab.
    public var newTabPage: String
    /// Search URL; `%s` is replaced by the query.
    public var searchTemplate: String
    /// Search-suggestion endpoint for the address bar (OpenSearch or DuckDuckGo JSON); `%s` is the typed text.
    /// Empty turns search suggestions off, so nothing you type is sent anywhere before you press Return.
    public var searchSuggestTemplate: String
    /// Days of browsing history kept in history.sqlite. 0 turns history off.
    public var historyDays: Int

    /// Background tabs idle longer than this are frozen: the page is kept and stops running, and shows again without a
    /// reload. A frozen tab is still awake, so it can later sleep as usual. 0 turns freezing off.
    public var tabFreezeAfterMinutes: Double
    /// Background tabs idle longer than this are put to sleep (their web process exits). 0 disables idle sleep.
    public var tabSleepAfterMinutes: Double
    /// At most this many tabs stay awake at once, across windows. The most recently used stay; further background
    /// tabs sleep, least recently used first. 0 disables the cap.
    public var maxAwakeTabs: Int
    /// Pinned tabs never sleep unless this is true.
    public var sleepPinnedTabs: Bool
    /// A background tab whose web process keeps at least this percent of one CPU core busy for 3 minutes in a row
    /// sleeps, as an idle one does, so a page that spins in the background doesn't run all day. 0 turns it off.
    public var cpuSleepPercent: Int
    /// A background tab that is uploading a file never freezes or sleeps (memory pressure aside), and one whose page
    /// asks before you leave it (unsaved changes) never sleeps on the idle or CPU rules. Off, page work doesn't count.
    public var keepPageWorkRunning: Bool
    /// A site allowed to show notifications never freezes and never sleeps on the idle rule, so its messages keep
    /// arriving. A `sites` entry's `freeze` overrides it either way. Off, those sites freeze like any other.
    public var keepNotifyingSitesLive: Bool
    /// Tabs whose back/forward history the saved session keeps: the most recently used ones, plus pinned tabs. The
    /// others come back on their page with no Back history.
    public var sessionHistoryTabs: Int
    /// A real ⌥-click on a link opens it in a preview over the page (one per window), which can become a tab. Off,
    /// ⌥-click follows the link.
    public var linkPreview: Bool
    /// Switching to a tab resumes its media and pauses the one you left. Off, a switch leaves whatever is playing alone.
    public var resumeMediaOnSelect: Bool
    /// Warm a site's connection before it is opened: the address bar's top suggestion as you type, a link after the
    /// pointer rests on it, and DNS for a page's links. Never in private windows. Off, nothing connects before you
    /// press Return or click.
    public var speculativeLoading: Bool

    /// Ad and tracker blocking with the lists below plus `user-filters.txt`.
    public var contentBlocking: Bool
    /// Adblock Plus-syntax filter lists, fetched with Paddle > Update Filter Lists.
    public var filterLists: [String]
    /// Days between automatic filter-list downloads, checked at launch and hourly, per list. 0 = only by hand
    /// (a list whose file in filters/ is missing is still fetched once).
    public var filterUpdateDays: Int
    /// Run the scriptlets (`##+js(…)` lines) of those lists and `user-filters.txt`: Paddle's own small scripts for
    /// an allowlisted set of names, given the line's arguments as strings. See `ScriptletParser`.
    public var scriptlets: Bool
    /// Lists (by URL, as in `filterLists`) whose `trusted-*` scriptlets may run. Paddle implements none of those
    /// yet, so this only stops them being counted as refused once it does.
    public var trustedLists: [String]

    /// Appended to WebKit's user agent. Empty means "match the installed Safari", which most sites expect.
    public var userAgentSuffix: String
    /// Full user agent for specific sites, keyed by host suffix (e.g. `"example.com"` also covers `www.example.com`).
    public var siteUserAgents: [String: String]
    /// Per-site zoom, JavaScript, autoplay, content blocking, location and notifications, keyed by host suffix like
    /// `siteUserAgents`. See `SiteSettings`.
    public var sites: [String: SiteSettings]

    /// Show per-tab memory in the toolbar and tab tooltips.
    public var showTabMemory: Bool
    /// The address field shows a web page's whole address while you aren't editing it; off shows only its site.
    public var showFullAddress: Bool
    /// Where the tabs go: `horizontal` in a strip above the toolbar, `vertical` in a sidebar. View > Vertical Tabs.
    public var tabLayout: TabLayout
    /// Light, dark, or follow macOS. Pages follow through their color scheme.
    public var appearance: AppearanceMode
    /// Website dark mode: `off`, `system` (follows appearance), or `always`.
    public var darkMode: DarkModePreference
    /// Draw the selected tab with a stronger outline and contrast (differs in brightness, not hue).
    public var highContrastTabs: Bool
    /// `default` (today's look), a built-in theme id (graphite, ocean, forest, dusk, sand, high-contrast) or the base
    /// name of a `themes/<name>.json` file.
    public var theme: String
    /// `system`, a preset name or `#rrggbb`: overrides the theme's accent.
    public var accentColor: String
    /// `none`, a preset name or `#rrggbb`: blended over the tab strip and toolbar.
    public var chromeTint: String
    /// How much of `chromeTint` is blended in, 0...100 (capped further so text stays readable).
    public var chromeTintStrength: Double
    /// Size of Paddle's own text: tabs, toolbar, bars.
    public var interfaceTextSize: InterfaceTextSize
    /// Zoom of a page whose site has no `sites.<host>.zoom`, as a factor (1 is 100 %); clamped to 0.3...3.
    public var defaultZoom: Double
    /// Smallest text size pages may use, in points. 0 is off; otherwise clamped to 9...24.
    public var minimumFontSize: Double
    /// `always` reduces motion even when macOS doesn't; `system` follows System Settings > Accessibility > Display.
    public var reduceMotion: AccessibilityPreference
    /// Same for transparency and blur.
    public var reduceTransparency: AccessibilityPreference
    /// Lets Claude sessions read and drive Paddle through a local MCP server on an owner-only socket. Off by default.
    public var controlBridge: Bool
    /// The bridge's `run_js` (scripts in pages). Off by default, separately from `controlBridge`: a script reaches what
    /// the page's own scripts can, typed passwords included.
    public var controlBridgeScripts: Bool
    /// Right-click > Inspect Element and the Web Inspector.
    public var developerTools: Bool
    /// Load http:// pages over https:// instead. A site that doesn't answer securely gets a notice with Continue to
    /// HTTP and Always Allow; local addresses are exempt, and `sites.<host>.httpsOnly: false` exempts one site.
    public var httpsOnly: Bool
    /// Show a Frequently visited row on the New Tab page, from history (never in private windows).
    public var newTabFrequentSites: Bool
    /// Prompt for a destination folder for each download instead of saving directly to ~/Downloads.
    public var askWhereToDownload: Bool
    /// Folder downloads are saved to (`~` allowed). Empty: ~/Downloads.
    public var downloadFolder: String
    /// Underline website links for readability and colorblind accessibility.
    public var underlineLinks: Bool
    /// Keep the close button visible on all tabs without needing to hover.
    public var alwaysShowTabCloseButtons: Bool
    /// Show a Home button on the toolbar that navigates to `homepage`.
    public var showHomeButton: Bool
    /// Keep the Downloads button visible on the toolbar even when no downloads are active.
    public var alwaysShowDownloadsButton: Bool

    /// Menu shortcut overrides: action name to a shortcut like `"cmd+shift+k"`. See README for action names.
    public var shortcuts: [String: String]

    /// Turn an extension off by its folder name in `extensions/`, e.g. `{"bitwarden": false}`. Folders not listed are on.
    public var extensions: [String: Bool]
    /// Run extensions in private windows too (the default for every extension; `extensionCompat.<folder>.private`
    /// overrides it per folder, see `extensionAllowedInPrivate`). A private window carries the extension controller
    /// only when any extension may run there (`anyExtensionInPrivate`), decided when it opens; an extension not
    /// allowed there can't see private windows or tabs.
    public var extensionsInPrivate: Bool
    /// Per-folder compatibility settings: `{"protonpass": {"persona": "firefox", "shims": true, "publicID": false, "private": true}}`.
    /// See `ExtensionCompatConfig`; folders not listed get the detected persona, shims on and a private id.
    public var extensionCompat: [String: ExtensionCompatConfig]
    /// Where each extension's toolbar button goes, by folder name: `pinned` on the toolbar (the default for folders not listed), `menu` only in the Extensions (puzzle) menu, `hidden` nowhere; the extension still runs.
    public var extensionToolbar: [String: ExtensionToolbarPlacement]
    /// Check store-installed extensions for updates daily (and from Check for Extension Updates).
    public var extensionUpdates: Bool
    /// Present Paddle to a site as Chrome or Firefox (user agent and the JavaScript browser identity), keyed by
    /// host suffix like `siteUserAgents`: `{"example.com": "chrome"}`. Only `chrome` and `firefox` apply.
    public var sitePersonas: [String: Persona]

    public static let defaultFilterLists = [
        "https://easylist.to/easylist/easylist.txt",
        "https://easylist.to/easylist/easyprivacy.txt",
    ]

    /// The `config.json` keys, one per property above. Explicit so `ConfigFile` can tell a known key from an unknown
    /// one; the raw values are the property names, as the synthesized keys were.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case homepage, newTabPage, searchTemplate, searchSuggestTemplate, historyDays
        case tabFreezeAfterMinutes, tabSleepAfterMinutes, maxAwakeTabs, sleepPinnedTabs, cpuSleepPercent, keepPageWorkRunning, keepNotifyingSitesLive, sessionHistoryTabs, linkPreview, resumeMediaOnSelect, speculativeLoading
        case contentBlocking, filterLists, filterUpdateDays, scriptlets, trustedLists
        case userAgentSuffix, siteUserAgents, sites, sitePersonas
        case showTabMemory, showFullAddress, tabLayout, developerTools, httpsOnly, newTabFrequentSites, askWhereToDownload, downloadFolder
        case underlineLinks, alwaysShowTabCloseButtons, showHomeButton, alwaysShowDownloadsButton
        case appearance, darkMode, highContrastTabs, theme, accentColor, chromeTint, chromeTintStrength, interfaceTextSize, defaultZoom, minimumFontSize, reduceMotion, reduceTransparency
        case controlBridge, controlBridgeScripts
        case shortcuts
        case extensions, extensionToolbar, extensionsInPrivate, extensionCompat, extensionUpdates
    }

    public init(
        homepage: String = "about:blank",
        newTabPage: String = "about:blank",
        searchTemplate: String = "https://duckduckgo.com/?q=%s",
        searchSuggestTemplate: String = "https://duckduckgo.com/ac/?q=%s&type=list",
        historyDays: Int = 365,
        tabFreezeAfterMinutes: Double = 2,
        tabSleepAfterMinutes: Double = 5,
        maxAwakeTabs: Int = 8,
        sleepPinnedTabs: Bool = false,
        cpuSleepPercent: Int = 30,
        keepPageWorkRunning: Bool = true,
        keepNotifyingSitesLive: Bool = true,
        sessionHistoryTabs: Int = 30,
        linkPreview: Bool = true,
        resumeMediaOnSelect: Bool = false,
        speculativeLoading: Bool = true,
        contentBlocking: Bool = true,
        filterLists: [String] = PaddleConfig.defaultFilterLists,
        filterUpdateDays: Int = 7,
        scriptlets: Bool = true,
        trustedLists: [String] = [],
        userAgentSuffix: String = "",
        siteUserAgents: [String: String] = [:],
        sites: [String: SiteSettings] = [:],
        showTabMemory: Bool = true,
        showFullAddress: Bool = false,
        tabLayout: TabLayout = .horizontal,
        developerTools: Bool = true,
        httpsOnly: Bool = true,
        newTabFrequentSites: Bool = true,
        askWhereToDownload: Bool = false,
        downloadFolder: String = "",
        underlineLinks: Bool = false,
        alwaysShowTabCloseButtons: Bool = false,
        showHomeButton: Bool = false,
        alwaysShowDownloadsButton: Bool = false,
        appearance: AppearanceMode = .system,
        darkMode: DarkModePreference = .off,
        highContrastTabs: Bool = false,
        theme: String = "default",
        accentColor: String = "system",
        chromeTint: String = "none",
        chromeTintStrength: Double = 25,
        interfaceTextSize: InterfaceTextSize = .default,
        defaultZoom: Double = 1,
        minimumFontSize: Double = 0,
        reduceMotion: AccessibilityPreference = .system,
        reduceTransparency: AccessibilityPreference = .system,
        controlBridge: Bool = false,
        controlBridgeScripts: Bool = false,
        shortcuts: [String: String] = [:],
        extensions: [String: Bool] = [:],
        extensionToolbar: [String: ExtensionToolbarPlacement] = [:],
        extensionsInPrivate: Bool = false,
        extensionCompat: [String: ExtensionCompatConfig] = [:],
        extensionUpdates: Bool = true,
        sitePersonas: [String: Persona] = [:]
    ) {
        self.homepage = homepage
        self.newTabPage = newTabPage
        self.searchTemplate = searchTemplate
        self.searchSuggestTemplate = searchSuggestTemplate
        self.historyDays = historyDays
        self.tabFreezeAfterMinutes = tabFreezeAfterMinutes
        self.tabSleepAfterMinutes = tabSleepAfterMinutes
        self.maxAwakeTabs = maxAwakeTabs
        self.sleepPinnedTabs = sleepPinnedTabs
        self.cpuSleepPercent = cpuSleepPercent
        self.keepPageWorkRunning = keepPageWorkRunning
        self.keepNotifyingSitesLive = keepNotifyingSitesLive
        self.sessionHistoryTabs = sessionHistoryTabs
        self.linkPreview = linkPreview
        self.resumeMediaOnSelect = resumeMediaOnSelect
        self.speculativeLoading = speculativeLoading
        self.contentBlocking = contentBlocking
        self.filterLists = filterLists
        self.filterUpdateDays = filterUpdateDays
        self.scriptlets = scriptlets
        self.trustedLists = trustedLists
        self.userAgentSuffix = userAgentSuffix
        self.siteUserAgents = siteUserAgents
        self.sites = sites
        self.showTabMemory = showTabMemory
        self.showFullAddress = showFullAddress
        self.tabLayout = tabLayout
        self.developerTools = developerTools
        self.httpsOnly = httpsOnly
        self.newTabFrequentSites = newTabFrequentSites
        self.askWhereToDownload = askWhereToDownload
        self.downloadFolder = downloadFolder
        self.underlineLinks = underlineLinks
        self.alwaysShowTabCloseButtons = alwaysShowTabCloseButtons
        self.showHomeButton = showHomeButton
        self.alwaysShowDownloadsButton = alwaysShowDownloadsButton
        self.appearance = appearance
        self.darkMode = darkMode
        self.highContrastTabs = highContrastTabs
        self.theme = theme
        self.accentColor = accentColor
        self.chromeTint = chromeTint
        self.chromeTintStrength = PaddleConfig.normalizedTintStrength(chromeTintStrength)
        self.interfaceTextSize = interfaceTextSize
        self.defaultZoom = SitePolicy.normalizedZoom(defaultZoom)
        self.minimumFontSize = PaddleConfig.normalizedMinimumFontSize(minimumFontSize)
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.controlBridge = controlBridge
        self.controlBridgeScripts = controlBridgeScripts
        self.shortcuts = shortcuts
        self.extensions = extensions
        self.extensionToolbar = extensionToolbar
        self.extensionsInPrivate = extensionsInPrivate
        self.extensionCompat = extensionCompat
        self.extensionUpdates = extensionUpdates
        self.sitePersonas = sitePersonas
    }

    /// Where `decodeReportingIssues` leaves its ``ConfigIssueCollector`` in the decoder's `userInfo`.
    static let issueCollectorKey = CodingUserInfoKey(rawValue: "paddleConfigIssues")!

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issues = decoder.userInfo[PaddleConfig.issueCollectorKey] as? ConfigIssueCollector
        let d = PaddleConfig()
        homepage = c.decodeValue(.homepage, d.homepage, issues)
        newTabPage = c.decodeValue(.newTabPage, d.newTabPage, issues)
        searchTemplate = c.decodeValue(.searchTemplate, d.searchTemplate, issues)
        searchSuggestTemplate = c.decodeValue(.searchSuggestTemplate, d.searchSuggestTemplate, issues)
        historyDays = c.decodeValue(.historyDays, d.historyDays, issues)
        tabFreezeAfterMinutes = c.decodeValue(.tabFreezeAfterMinutes, d.tabFreezeAfterMinutes, issues)
        tabSleepAfterMinutes = c.decodeValue(.tabSleepAfterMinutes, d.tabSleepAfterMinutes, issues)
        maxAwakeTabs = c.decodeValue(.maxAwakeTabs, d.maxAwakeTabs, issues)
        sleepPinnedTabs = c.decodeValue(.sleepPinnedTabs, d.sleepPinnedTabs, issues)
        cpuSleepPercent = c.decodeValue(.cpuSleepPercent, d.cpuSleepPercent, issues)
        keepPageWorkRunning = c.decodeValue(.keepPageWorkRunning, d.keepPageWorkRunning, issues)
        keepNotifyingSitesLive = c.decodeValue(.keepNotifyingSitesLive, d.keepNotifyingSitesLive, issues)
        sessionHistoryTabs = c.decodeValue(.sessionHistoryTabs, d.sessionHistoryTabs, issues)
        linkPreview = c.decodeValue(.linkPreview, d.linkPreview, issues)
        resumeMediaOnSelect = c.decodeValue(.resumeMediaOnSelect, d.resumeMediaOnSelect, issues)
        speculativeLoading = c.decodeValue(.speculativeLoading, d.speculativeLoading, issues)
        contentBlocking = c.decodeValue(.contentBlocking, d.contentBlocking, issues)
        filterLists = c.decodeStrings(.filterLists, d.filterLists, issues)
        filterUpdateDays = c.decodeValue(.filterUpdateDays, d.filterUpdateDays, issues)
        scriptlets = c.decodeValue(.scriptlets, d.scriptlets, issues)
        trustedLists = c.decodeStrings(.trustedLists, d.trustedLists, issues)
        userAgentSuffix = c.decodeValue(.userAgentSuffix, d.userAgentSuffix, issues)
        siteUserAgents = c.decodeEntries(.siteUserAgents, d.siteUserAgents, issues)
        sites = c.decodeEntries(.sites, d.sites, issues)
        showTabMemory = c.decodeValue(.showTabMemory, d.showTabMemory, issues)
        showFullAddress = c.decodeValue(.showFullAddress, d.showFullAddress, issues)
        tabLayout = c.decodeValue(.tabLayout, d.tabLayout, issues)
        developerTools = c.decodeValue(.developerTools, d.developerTools, issues)
        httpsOnly = c.decodeValue(.httpsOnly, d.httpsOnly, issues)
        newTabFrequentSites = c.decodeValue(.newTabFrequentSites, d.newTabFrequentSites, issues)
        askWhereToDownload = c.decodeValue(.askWhereToDownload, d.askWhereToDownload, issues)
        downloadFolder = c.decodeValue(.downloadFolder, d.downloadFolder, issues)
        underlineLinks = c.decodeValue(.underlineLinks, d.underlineLinks, issues)
        alwaysShowTabCloseButtons = c.decodeValue(.alwaysShowTabCloseButtons, d.alwaysShowTabCloseButtons, issues)
        showHomeButton = c.decodeValue(.showHomeButton, d.showHomeButton, issues)
        alwaysShowDownloadsButton = c.decodeValue(.alwaysShowDownloadsButton, d.alwaysShowDownloadsButton, issues)
        appearance = c.decodeValue(.appearance, d.appearance, issues)
        darkMode = c.decodeValue(.darkMode, d.darkMode, issues)
        highContrastTabs = c.decodeValue(.highContrastTabs, d.highContrastTabs, issues)
        theme = c.decodeValue(.theme, d.theme, issues)
        accentColor = c.decodeColor(.accentColor, d.accentColor, automatic: "system", issues)
        chromeTint = c.decodeColor(.chromeTint, d.chromeTint, automatic: "none", issues)
        let tintStrength: Double = c.decodeValue(.chromeTintStrength, d.chromeTintStrength, issues)
        if !tintStrength.isFinite {
            issues?.issues.append(ConfigIssue(
                key: .chromeTintStrength, path: ["chromeTintStrength"], severity: .warning,
                message: "Expected a number from 0 to 100. Paddle uses the default, 25, until this is fixed."))
        }
        chromeTintStrength = PaddleConfig.normalizedTintStrength(tintStrength.isFinite ? tintStrength : d.chromeTintStrength)
        interfaceTextSize = c.decodeValue(.interfaceTextSize, d.interfaceTextSize, issues)
        defaultZoom = SitePolicy.normalizedZoom(c.decodeValue(.defaultZoom, d.defaultZoom, issues))
        let fontSize: Double = c.decodeValue(.minimumFontSize, d.minimumFontSize, issues)
        if fontSize < 0 || !fontSize.isFinite {
            issues?.issues.append(ConfigIssue(
                key: .minimumFontSize, path: ["minimumFontSize"], severity: .warning,
                message: "Expected 0 (off) or a size from 9 to 24. Paddle uses the default, 0, until this is fixed."))
        }
        minimumFontSize = PaddleConfig.normalizedMinimumFontSize(fontSize)
        reduceMotion = c.decodeValue(.reduceMotion, d.reduceMotion, issues)
        reduceTransparency = c.decodeValue(.reduceTransparency, d.reduceTransparency, issues)
        controlBridge = c.decodeValue(.controlBridge, d.controlBridge, issues)
        controlBridgeScripts = c.decodeValue(.controlBridgeScripts, d.controlBridgeScripts, issues)
        shortcuts = c.decodeEntries(.shortcuts, d.shortcuts, issues)
        extensions = c.decodeEntries(.extensions, d.extensions, issues)
        extensionToolbar = c.decodeEntries(.extensionToolbar, d.extensionToolbar, issues)
        extensionsInPrivate = c.decodeValue(.extensionsInPrivate, d.extensionsInPrivate, issues)
        extensionCompat = c.decodeEntries(.extensionCompat, d.extensionCompat, issues)
        extensionUpdates = c.decodeValue(.extensionUpdates, d.extensionUpdates, issues)
        sitePersonas = c.decodeEntries(.sitePersonas, d.sitePersonas, issues)
    }

    /// Decodes `config.json`, dropping the issues. Throws only when the data isn't JSON or its top level isn't an
    /// object; see `decodeReportingIssues`.
    public static func decode(_ data: Data) throws -> PaddleConfig {
        try decodeReportingIssues(data).config
    }

    /// Decodes `config.json` and lists what didn't apply: a value of the wrong type is replaced by its default, and an
    /// object entry or list item of the wrong type is skipped, each with an issue at its path. A `null` or missing key
    /// is the default with no issue, and unknown keys are ignored. Throws only when the data isn't JSON or its top
    /// level isn't an object.
    public static func decodeReportingIssues(_ data: Data) throws -> (config: PaddleConfig, issues: [ConfigIssue]) {
        let collector = ConfigIssueCollector()
        let decoder = JSONDecoder()
        decoder.userInfo[PaddleConfig.issueCollectorKey] = collector
        let config = try decoder.decode(PaddleConfig.self, from: data)
        return (config, collector.issues)
    }

    /// Why config.json can't be read at all: the JSON syntax error (with its line and column) or a top level that isn't
    /// an object. A wrong-typed value isn't an error here; `decodeReportingIssues` reports it. `localizedDescription`
    /// only says the data "isn't in the correct format".
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else {
            // A bare `JSONSerialization` error keeps its line and column only in the debug description.
            return ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .dataCorrupted(let context):
            guard let underlying = context.underlyingError as NSError? else {
                // No underlying error: a value of the right type that the type itself rejects, like an unknown enum word.
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            }
            return (underlying.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "\(context.debugDescription) \(underlying)"
        @unknown default:
            return error.localizedDescription
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `strength` kept in 0...100; 25 for a non-number.
    static func normalizedTintStrength(_ strength: Double) -> Double {
        strength.isFinite ? min(max(strength, 0), 100) : 25
    }

    /// `size` as `minimumFontSize` keeps it: 0 (off) for a negative or non-number, 9...24 otherwise (a value between 0 and 9 becomes 9).
    static func normalizedMinimumFontSize(_ size: Double) -> Double {
        guard size.isFinite, size > 0 else { return 0 }
        return min(max(size.rounded(), 9), 24)
    }

    /// Whether websites without a per-site dark mode setting should be dark.
    public func defaultDarkMode(systemIsDark: Bool = false) -> Bool {
        switch darkMode {
        case .off: return false
        case .always: return true
        case .system:
            switch appearance {
            case .system: return systemIsDark
            case .light: return false
            case .dark: return true
            }
        }
    }

    /// Whether the extension in folder `folder` should load. Folders absent from `extensions` are on.
    public func isExtensionEnabled(_ folder: String) -> Bool { extensions[folder] ?? true }

    /// Where folder `folder`'s toolbar button goes; `pinned` unless `extensionToolbar` says otherwise.
    public func toolbarPlacement(folder: String) -> ExtensionToolbarPlacement { extensionToolbar[folder] ?? .pinned }

    /// The `extensionCompat` entry for folder `folder`, or the defaults.
    public func compat(forFolder folder: String) -> ExtensionCompatConfig { extensionCompat[folder] ?? ExtensionCompatConfig() }

    /// Whether the extension in folder `folder` may run in private windows: its `private` setting, else `extensionsInPrivate`.
    public func extensionAllowedInPrivate(folder: String) -> Bool { compat(forFolder: folder).inPrivate ?? extensionsInPrivate }

    /// Whether any extension may run in private windows. A private window carries extensions (decided when it opens)
    /// when this is true.
    public var anyExtensionInPrivate: Bool { extensionsInPrivate || extensionCompat.values.contains { $0.inPrivate == true } }

    /// The persona `sitePersonas` gives `host` (longest matching host suffix, as `userAgent(forHost:)`); nil when
    /// none, or when the entry is `native` / `none`, which don't apply to websites.
    public func sitePersona(forHost host: String) -> Persona? {
        let host = PaddleConfig.normalizedHost(host)
        let persona = sitePersonas
            .filter { key, _ in PaddleConfig.hostKey(key, matches: host) }
            .max { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }?
            .value
        return persona == .chrome || persona == .firefox ? persona : nil
    }

    /// The site-specific user agent for `host`, matching the longest configured host suffix (see `normalizedHost`).
    public func userAgent(forHost host: String) -> String? {
        let host = PaddleConfig.normalizedHost(host)
        return siteUserAgents
            .filter { key, _ in PaddleConfig.hostKey(key, matches: host) }
            .max { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }?
            .value
    }

    /// The user agent a page on `host` is sent: the `siteUserAgents` string when one covers the host and isn't empty,
    /// else the `sitePersonas` persona's (Chrome or Firefox at `BrowserVersions.current`), else Paddle's built-in fix
    /// (`SiteCompat`) when neither key has any entry covering the host, else nil (WebKit's own).
    public func pageUserAgent(forHost host: String) -> String? {
        let configured = userAgent(forHost: host)
        if let configured, !configured.isEmpty { return configured }
        if let persona = sitePersona(forHost: host) { return persona.userAgent(.current) }
        guard configured == nil, !hasSitePersonaEntry(forHost: host) else { return nil }
        return SiteCompat.entry(forHost: host)?.persona.userAgent(.current)
    }

    /// Whether any `sitePersonas` entry covers `host`, `none` and `native` included.
    func hasSitePersonaEntry(forHost host: String) -> Bool {
        let host = PaddleConfig.normalizedHost(host)
        return sitePersonas.keys.contains { PaddleConfig.hostKey($0, matches: host) }
    }
}

/// Receives the issues a lenient decode finds. `decodeReportingIssues` puts one in the decoder's `userInfo`; a plain
/// `JSONDecoder().decode` has none, so its issues are dropped. Only ever used inside one synchronous decode, so the
/// unchecked `Sendable` (for `userInfo`) is safe.
final class ConfigIssueCollector: @unchecked Sendable {
    var issues: [ConfigIssue] = []
}

/// One value decoded on its own. A failure is kept rather than thrown, so one bad entry or list item can't reject the
/// rest of its object or list.
private struct Lenient<Value: Decodable>: Decodable {
    let result: Result<Value, any Error>

    init(from decoder: any Decoder) throws {
        result = Result { try Value(from: decoder) }
    }
}

/// Each `config.json` key decodes on its own. A missing or `null` value gives the default with no issue.
private extension KeyedDecodingContainer where Key == PaddleConfig.CodingKeys {
    /// A color setting: a string that is `automatic`, a preset name or `#rrggbb`. Anything else gives `fallback`
    /// with a warning.
    func decodeColor(_ key: Key, _ fallback: String, automatic: String, _ issues: ConfigIssueCollector?) -> String {
        let value: String = decodeValue(key, fallback, issues)
        guard ColorChoice(configValue: value, automaticValue: automatic) == nil else { return value }
        issues?.issues.append(ConfigIssue(
            key: key, path: [key.stringValue], severity: .warning,
            message: "\"\(value)\" isn't \"\(automatic)\", a color name or #rrggbb. Paddle uses the default, \"\(fallback)\", until this is fixed."))
        return fallback
    }

    /// A plain value. A wrong type gives `fallback` with an issue at `[key]`.
    func decodeValue<T: Codable>(_ key: Key, _ fallback: T, _ issues: ConfigIssueCollector?) -> T {
        do {
            return try decodeIfPresent(T.self, forKey: key) ?? fallback
        } catch {
            issues?.issues.append(configIssue(key, error: error, fallback: defaultText(fallback)))
            return fallback
        }
    }

    /// An object whose entries decode on their own. A value that isn't an object gives `fallback` with an issue at
    /// `[key]`; an entry of the wrong type is skipped with an issue at `[key, name]`.
    func decodeEntries<V: Codable>(_ key: Key, _ fallback: [String: V], _ issues: ConfigIssueCollector?) -> [String: V] {
        let raw: [String: Lenient<V>]
        do {
            guard let decoded = try decodeIfPresent([String: Lenient<V>].self, forKey: key) else { return fallback }
            raw = decoded
        } catch {
            issues?.issues.append(configIssue(key, error: error, fallback: defaultText(fallback)))
            return fallback
        }
        var entries: [String: V] = [:]
        for (name, entry) in raw.sorted(by: { $0.key < $1.key }) {
            switch entry.result {
            case .success(let value): entries[name] = value
            case .failure(let error): issues?.issues.append(configIssue(key, entry: name, error: error, fallback: nil))
            }
        }
        return entries
    }

    /// A list of text. A value that isn't a list gives `fallback` with an issue at `[key]`; an item that isn't text is
    /// skipped with an issue at `[key, index]`, the index in the file's list.
    func decodeStrings(_ key: Key, _ fallback: [String], _ issues: ConfigIssueCollector?) -> [String] {
        let raw: [Lenient<String>]
        do {
            guard let decoded = try decodeIfPresent([Lenient<String>].self, forKey: key) else { return fallback }
            raw = decoded
        } catch {
            issues?.issues.append(configIssue(key, error: error, fallback: defaultText(fallback)))
            return fallback
        }
        var items: [String] = []
        for (index, item) in raw.enumerated() {
            switch item.result {
            case .success(let text): items.append(text)
            case .failure(let error):
                issues?.issues.append(configIssue(key, entry: String(index), error: error, fallback: nil, unit: "item"))
            }
        }
        return items
    }
}

/// The issue for one value that fell back to its default (`fallback` is that default as text) or one entry or list item
/// that was skipped (`fallback` is nil, `entry` names it, and `unit` says which in the message).
private func configIssue(
    _ key: PaddleConfig.CodingKeys, entry: String? = nil, error: any Error, fallback: String?, unit: String = "entry"
) -> ConfigIssue {
    let path = [key.rawValue] + (entry.map { [$0] } ?? [])
    let kind = expectedKind(error)
    // The error's coding path starts at the key and the entry (or list index); what is left names the field that was wrong.
    let field = codingPath(of: error).dropFirst(path.count)
    let message: String
    if let fallback {
        message = "Expected \(kind). Paddle uses the default, \(fallback), until this is fixed."
    } else if field.isEmpty {
        message = "Expected \(kind) for this \(unit). Paddle ignores this \(unit) until it is fixed."
    } else {
        message = "Expected \(kind) for \(field.joined(separator: ".")) in this \(unit). Paddle ignores this \(unit) until it is fixed."
    }
    return ConfigIssue(key: key, path: path, severity: .warning, message: message)
}

/// What a failed decode wanted, in words for someone editing config.json.
private func expectedKind(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return "a different value" }
    switch error {
    case .typeMismatch(let type, _), .valueNotFound(let type, _):
        if type == Int.self { return "a whole number" }
        if type == Double.self || type == Float.self { return "a number" }
        if type == Bool.self { return "true or false" }
        if type == String.self { return "text" }
        // Lists and objects: arrays are named `Array<…>`; anything else that decodes from a JSON object is an object.
        return String(describing: type).hasPrefix("Array<") ? "a list" : "an object"
    case .dataCorrupted: return "one of the allowed words"
    default: return "a different value"
    }
}

private func codingPath(of error: any Error) -> [String] {
    guard let error = error as? DecodingError else { return [] }
    switch error {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
        return context.codingPath.map(\.stringValue)
    default: return []
    }
}

/// A default as compact JSON, cut to 60 characters with "…" so a long one (a list of URLs) stays readable in a message.
private func defaultText<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    return text.count > 60 ? String(text.prefix(60)) + "…" : text
}
