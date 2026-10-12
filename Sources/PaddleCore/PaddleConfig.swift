import Foundation

/// Everything a user can change by editing `config.json`. Missing keys fall back to the defaults below,
/// so a config file only needs the keys it changes.
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

    /// Background tabs idle longer than this are put to sleep (their web process exits). 0 disables idle sleep.
    public var tabSleepAfterMinutes: Double
    /// At most this many tabs stay awake at once; the least recently used extra tabs sleep. 0 disables the cap.
    public var maxAwakeTabs: Int
    /// Pinned tabs never sleep unless this is true.
    public var sleepPinnedTabs: Bool
    /// Tabs whose back/forward history the saved session keeps: the most recently used ones, plus pinned tabs. The
    /// others come back on their page with no Back history.
    public var sessionHistoryTabs: Int

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
    /// Per-site zoom, JavaScript, autoplay, content blocking and location, keyed by host suffix like
    /// `siteUserAgents`. See `SiteSettings`.
    public var sites: [String: SiteSettings]

    /// Show per-tab memory in the toolbar and tab tooltips.
    public var showTabMemory: Bool
    /// Right-click > Inspect Element and the Web Inspector.
    public var developerTools: Bool

    /// Menu shortcut overrides: action name to a shortcut like `"cmd+shift+k"`. See README for action names.
    public var shortcuts: [String: String]

    /// Turn an extension off by its folder name in `extensions/`, e.g. `{"bitwarden": false}`. Folders not listed are on.
    public var extensions: [String: Bool]
    /// Run extensions in private windows too. Off by default: private windows and their tabs are hidden from
    /// extensions, and their web views don't carry the extension controller.
    public var extensionsInPrivate: Bool
    /// Per-folder compatibility settings: `{"protonpass": {"persona": "firefox", "shims": true, "publicID": false}}`.
    /// See `ExtensionCompatConfig`; folders not listed get the detected persona, shims on and a private id.
    public var extensionCompat: [String: ExtensionCompatConfig]
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
        case tabSleepAfterMinutes, maxAwakeTabs, sleepPinnedTabs, sessionHistoryTabs
        case contentBlocking, filterLists, filterUpdateDays, scriptlets, trustedLists
        case userAgentSuffix, siteUserAgents, sites, sitePersonas
        case showTabMemory, developerTools
        case shortcuts
        case extensions, extensionsInPrivate, extensionCompat, extensionUpdates
    }

    public init(
        homepage: String = "about:blank",
        newTabPage: String = "about:blank",
        searchTemplate: String = "https://duckduckgo.com/?q=%s",
        searchSuggestTemplate: String = "https://duckduckgo.com/ac/?q=%s&type=list",
        historyDays: Int = 365,
        tabSleepAfterMinutes: Double = 30,
        maxAwakeTabs: Int = 10,
        sleepPinnedTabs: Bool = false,
        sessionHistoryTabs: Int = 30,
        contentBlocking: Bool = true,
        filterLists: [String] = PaddleConfig.defaultFilterLists,
        filterUpdateDays: Int = 7,
        scriptlets: Bool = true,
        trustedLists: [String] = [],
        userAgentSuffix: String = "",
        siteUserAgents: [String: String] = [:],
        sites: [String: SiteSettings] = [:],
        showTabMemory: Bool = true,
        developerTools: Bool = true,
        shortcuts: [String: String] = [:],
        extensions: [String: Bool] = [:],
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
        self.tabSleepAfterMinutes = tabSleepAfterMinutes
        self.maxAwakeTabs = maxAwakeTabs
        self.sleepPinnedTabs = sleepPinnedTabs
        self.sessionHistoryTabs = sessionHistoryTabs
        self.contentBlocking = contentBlocking
        self.filterLists = filterLists
        self.filterUpdateDays = filterUpdateDays
        self.scriptlets = scriptlets
        self.trustedLists = trustedLists
        self.userAgentSuffix = userAgentSuffix
        self.siteUserAgents = siteUserAgents
        self.sites = sites
        self.showTabMemory = showTabMemory
        self.developerTools = developerTools
        self.shortcuts = shortcuts
        self.extensions = extensions
        self.extensionsInPrivate = extensionsInPrivate
        self.extensionCompat = extensionCompat
        self.extensionUpdates = extensionUpdates
        self.sitePersonas = sitePersonas
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PaddleConfig()
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage) ?? d.homepage
        newTabPage = try c.decodeIfPresent(String.self, forKey: .newTabPage) ?? d.newTabPage
        searchTemplate = try c.decodeIfPresent(String.self, forKey: .searchTemplate) ?? d.searchTemplate
        searchSuggestTemplate = try c.decodeIfPresent(String.self, forKey: .searchSuggestTemplate) ?? d.searchSuggestTemplate
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? d.historyDays
        tabSleepAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .tabSleepAfterMinutes) ?? d.tabSleepAfterMinutes
        maxAwakeTabs = try c.decodeIfPresent(Int.self, forKey: .maxAwakeTabs) ?? d.maxAwakeTabs
        sleepPinnedTabs = try c.decodeIfPresent(Bool.self, forKey: .sleepPinnedTabs) ?? d.sleepPinnedTabs
        sessionHistoryTabs = try c.decodeIfPresent(Int.self, forKey: .sessionHistoryTabs) ?? d.sessionHistoryTabs
        contentBlocking = try c.decodeIfPresent(Bool.self, forKey: .contentBlocking) ?? d.contentBlocking
        filterLists = try c.decodeIfPresent([String].self, forKey: .filterLists) ?? d.filterLists
        filterUpdateDays = try c.decodeIfPresent(Int.self, forKey: .filterUpdateDays) ?? d.filterUpdateDays
        scriptlets = try c.decodeIfPresent(Bool.self, forKey: .scriptlets) ?? d.scriptlets
        trustedLists = try c.decodeIfPresent([String].self, forKey: .trustedLists) ?? d.trustedLists
        userAgentSuffix = try c.decodeIfPresent(String.self, forKey: .userAgentSuffix) ?? d.userAgentSuffix
        siteUserAgents = try c.decodeIfPresent([String: String].self, forKey: .siteUserAgents) ?? d.siteUserAgents
        sites = try c.decodeIfPresent([String: SiteSettings].self, forKey: .sites) ?? d.sites
        showTabMemory = try c.decodeIfPresent(Bool.self, forKey: .showTabMemory) ?? d.showTabMemory
        developerTools = try c.decodeIfPresent(Bool.self, forKey: .developerTools) ?? d.developerTools
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? d.shortcuts
        extensions = try c.decodeIfPresent([String: Bool].self, forKey: .extensions) ?? d.extensions
        extensionsInPrivate = try c.decodeIfPresent(Bool.self, forKey: .extensionsInPrivate) ?? d.extensionsInPrivate
        extensionCompat = try c.decodeIfPresent([String: ExtensionCompatConfig].self, forKey: .extensionCompat) ?? d.extensionCompat
        extensionUpdates = try c.decodeIfPresent(Bool.self, forKey: .extensionUpdates) ?? d.extensionUpdates
        sitePersonas = try c.decodeIfPresent([String: Persona].self, forKey: .sitePersonas) ?? d.sitePersonas
    }

    public static func decode(_ data: Data) throws -> PaddleConfig {
        try JSONDecoder().decode(PaddleConfig.self, from: data)
    }

    /// Why config.json didn't load, in words someone can act on: which key had the wrong type, or where the JSON
    /// broke. `localizedDescription` only says the data "isn't in the correct format".
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
                // No underlying error: a value of the right type Paddle can't use, like an unknown `autoplay` word.
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

    /// Whether the extension in folder `folder` should load. Folders absent from `extensions` are on.
    public func isExtensionEnabled(_ folder: String) -> Bool { extensions[folder] ?? true }

    /// The `extensionCompat` entry for folder `folder`, or the defaults.
    public func compat(forFolder folder: String) -> ExtensionCompatConfig { extensionCompat[folder] ?? ExtensionCompatConfig() }

    /// The persona `sitePersonas` gives `host` (longest matching host suffix, as `userAgent(forHost:)`); nil when
    /// none, or when the entry is `native` / `none`, which don't apply to websites.
    public func sitePersona(forHost host: String) -> Persona? {
        let host = PaddleConfig.normalizedHost(host)
        let persona = sitePersonas
            .filter { key, _ in PaddleConfig.hostKey(key, matches: host) }
            .max { $0.key.count < $1.key.count }?
            .value
        return persona == .chrome || persona == .firefox ? persona : nil
    }

    /// The site-specific user agent for `host`, matching the longest configured host suffix (see `normalizedHost`).
    public func userAgent(forHost host: String) -> String? {
        let host = PaddleConfig.normalizedHost(host)
        return siteUserAgents
            .filter { key, _ in PaddleConfig.hostKey(key, matches: host) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
