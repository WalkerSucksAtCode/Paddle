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

    /// Ad and tracker blocking with the lists below plus `user-filters.txt`.
    public var contentBlocking: Bool
    /// Adblock Plus-syntax filter lists, fetched with Paddle > Update Filter Lists.
    public var filterLists: [String]

    /// Appended to WebKit's user agent. Empty means "match the installed Safari", which most sites expect.
    public var userAgentSuffix: String
    /// Full user agent for specific sites, keyed by host suffix (e.g. `"example.com"` also covers `www.example.com`).
    public var siteUserAgents: [String: String]

    /// Show per-tab memory in the toolbar and tab tooltips.
    public var showTabMemory: Bool
    /// Right-click > Inspect Element and the Web Inspector.
    public var developerTools: Bool

    /// Menu shortcut overrides: action name to a shortcut like `"cmd+shift+k"`. See README for action names.
    public var shortcuts: [String: String]

    public static let defaultFilterLists = [
        "https://easylist.to/easylist/easylist.txt",
        "https://easylist.to/easylist/easyprivacy.txt",
    ]

    public init(
        homepage: String = "about:blank",
        newTabPage: String = "about:blank",
        searchTemplate: String = "https://duckduckgo.com/?q=%s",
        searchSuggestTemplate: String = "https://duckduckgo.com/ac/?q=%s&type=list",
        historyDays: Int = 365,
        tabSleepAfterMinutes: Double = 30,
        maxAwakeTabs: Int = 10,
        sleepPinnedTabs: Bool = false,
        contentBlocking: Bool = true,
        filterLists: [String] = PaddleConfig.defaultFilterLists,
        userAgentSuffix: String = "",
        siteUserAgents: [String: String] = [:],
        showTabMemory: Bool = true,
        developerTools: Bool = true,
        shortcuts: [String: String] = [:]
    ) {
        self.homepage = homepage
        self.newTabPage = newTabPage
        self.searchTemplate = searchTemplate
        self.searchSuggestTemplate = searchSuggestTemplate
        self.historyDays = historyDays
        self.tabSleepAfterMinutes = tabSleepAfterMinutes
        self.maxAwakeTabs = maxAwakeTabs
        self.sleepPinnedTabs = sleepPinnedTabs
        self.contentBlocking = contentBlocking
        self.filterLists = filterLists
        self.userAgentSuffix = userAgentSuffix
        self.siteUserAgents = siteUserAgents
        self.showTabMemory = showTabMemory
        self.developerTools = developerTools
        self.shortcuts = shortcuts
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
        contentBlocking = try c.decodeIfPresent(Bool.self, forKey: .contentBlocking) ?? d.contentBlocking
        filterLists = try c.decodeIfPresent([String].self, forKey: .filterLists) ?? d.filterLists
        userAgentSuffix = try c.decodeIfPresent(String.self, forKey: .userAgentSuffix) ?? d.userAgentSuffix
        siteUserAgents = try c.decodeIfPresent([String: String].self, forKey: .siteUserAgents) ?? d.siteUserAgents
        showTabMemory = try c.decodeIfPresent(Bool.self, forKey: .showTabMemory) ?? d.showTabMemory
        developerTools = try c.decodeIfPresent(Bool.self, forKey: .developerTools) ?? d.developerTools
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? d.shortcuts
    }

    public static func decode(_ data: Data) throws -> PaddleConfig {
        try JSONDecoder().decode(PaddleConfig.self, from: data)
    }

    /// Why config.json didn't load, in words someone can act on: which key had the wrong type, or where the JSON
    /// broke. `localizedDescription` only says the data "isn't in the correct format".
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .dataCorrupted(let context):
            guard let underlying = context.underlyingError as NSError? else { return context.debugDescription }
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

    /// The site-specific user agent for `host`, matching the longest configured host suffix.
    public func userAgent(forHost host: String) -> String? {
        let host = host.lowercased()
        return siteUserAgents
            .filter { key, _ in
                let key = key.lowercased()
                return host == key || host.hasSuffix("." + key)
            }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
