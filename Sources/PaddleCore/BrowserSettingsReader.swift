import Foundation

/// The few settings Paddle can take from another browser, as that browser stores them. `nil` means the browser's
/// file doesn't set it; `reasons` say why a setting can't be used when the file does carry something for it.
public struct BrowserSettings: Sendable, Equatable {
    /// The default engine's name or identifier, when the file gives one.
    public var searchEngineName: String?
    /// The default engine's search URL with the query as `{searchTerms}` or `%s`, when the file gives one.
    public var searchEngineURL: String?
    /// The page new windows open, when the browser has one set (an address, not "empty" or "start page").
    public var homepage: String?
    /// The page new tabs open (Safari can open the homepage in new tabs).
    public var newTabPage: String?
    public var showBookmarksBar: Bool?
    /// Why a setting wasn't read, keyed by `Setting`.
    public var reasons: [Setting: String] = [:]

    public enum Setting: String, Sendable, CaseIterable {
        case searchEngine, homepage, newTabPage, bookmarksBar

        public var title: String {
            switch self {
            case .searchEngine: "Search engine"
            case .homepage: "Home page"
            case .newTabPage: "New tab page"
            case .bookmarksBar: "Bookmarks bar"
            }
        }
    }

    public init() {}
}

/// Reads the settings files of Safari, Chromium-family browsers and Firefox into `BrowserSettings`, and maps those
/// onto Paddle's `config.json` keys.
///
/// Where each value is assumed to live:
/// - Safari `com.apple.Safari.plist` (binary or XML plist): `HomePage` (string), `NewWindowBehavior` and
///   `NewTabBehavior` (Int; `0` opens the homepage), `ShowFavoritesBar-v2` (Bool), and the default engine's name or
///   identifier under `SearchProviderIdentifier`, `SearchProviderShortName` or `SearchProviderIdentifierStorage`.
/// - Chrome `Preferences` (JSON): `homepage` (string) with `homepage_is_newtabpage` (Bool),
///   `session.restore_on_startup` (`4` = open `session.startup_urls`), `bookmark_bar.show_on_all_tabs` (Bool) and
///   `default_search_provider_data.template_url_data` (`short_name`, `url`; absent while Chrome uses its default).
/// - Firefox `prefs.js` (`user_pref("name", value);` lines): `browser.startup.homepage` (`|` separates several pages)
///   and `browser.toolbars.bookmarks.visibility` (`always`, `never`, `newtab`); `search.json.mozlz4` (`MozLZ4`, JSON)
///   with `metaData.defaultEngineId` (or the older `metaData.current`, a name) and `engines[]` (`id`, `_name`,
///   `_urls[].params`/`template`).
public enum BrowserSettingsReader {
    public static func read(_ source: ImportSource) throws -> BrowserSettings {
        switch source.browser.family {
        case .safari: try readSafari(source)
        case .chromium: try readChromium(source)
        case .firefox: try readFirefox(source)
        }
    }

    // MARK: - Reading files

    private static func fileData(_ url: URL, _ source: ImportSource) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            if BrowserHistoryReader.isPermissionDenied(error) { throw BrowserImportError.accessDenied(source.browser) }
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw BrowserImportError.missing("\(source.browser.displayName)'s \(url.lastPathComponent)")
            }
            throw BrowserImportError.unreadable("\(source.browser.displayName)'s \(url.lastPathComponent) couldn't be read: \(error.localizedDescription)")
        }
    }

    /// An address Paddle can open as a home or new tab page.
    private static func webAddress(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return text
    }

    // MARK: - Safari

    static func readSafari(_ source: ImportSource) throws -> BrowserSettings {
        let data = try fileData(source.settingsFile, source)
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw BrowserImportError.unreadable("Safari's settings file isn't a property list.")
        }
        return safariSettings(plist)
    }

    static func safariSettings(_ plist: [String: Any]) -> BrowserSettings {
        var settings = BrowserSettings()

        for key in ["SearchProviderIdentifier", "SearchProviderShortName", "SearchProviderIdentifierStorage"] {
            if let name = plist[key] as? String, !name.isEmpty {
                settings.searchEngineName = name
                break
            }
        }
        if settings.searchEngineName == nil { settings.reasons[.searchEngine] = "Safari's settings don't name a search engine, so it is using Safari's default." }

        let home = webAddress(plist["HomePage"] as? String)
        switch (plist["NewWindowBehavior"] as? Int, home) {
        case (0?, let home?): settings.homepage = home
        case (0?, nil): settings.reasons[.homepage] = "Safari's home page isn't a web address."
        default: settings.reasons[.homepage] = "Safari's new windows don't open a home page."
        }
        switch (plist["NewTabBehavior"] as? Int, home) {
        case (0?, let home?): settings.newTabPage = home
        default: settings.reasons[.newTabPage] = "Safari's new tabs don't open a home page."
        }

        if let bar = plist["ShowFavoritesBar-v2"] as? Bool ?? plist["ShowFavoritesBar"] as? Bool {
            settings.showBookmarksBar = bar
        } else {
            settings.reasons[.bookmarksBar] = "Safari's settings don't say whether its Favorites bar is shown."
        }
        return settings
    }

    // MARK: - Chromium family

    static func readChromium(_ source: ImportSource) throws -> BrowserSettings {
        let data = try fileData(source.settingsFile, source)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BrowserImportError.unreadable("\(source.browser.displayName)'s Preferences file isn't JSON.")
        }
        return chromiumSettings(root, browserName: source.browser.displayName)
    }

    static func chromiumSettings(_ root: [String: Any], browserName: String) -> BrowserSettings {
        var settings = BrowserSettings()

        let engine = (root["default_search_provider_data"] as? [String: Any])?["template_url_data"] as? [String: Any]
        settings.searchEngineName = engine?["short_name"] as? String
        settings.searchEngineURL = engine?["url"] as? String
        if engine == nil { settings.reasons[.searchEngine] = "\(browserName) doesn't record a search engine, so it is using its own default." }

        // The Home button's page when it isn't the new tab page, else the page "on startup" opens.
        let homepageIsNewTab = root["homepage_is_newtabpage"] as? Bool ?? true
        let session = root["session"] as? [String: Any]
        if !homepageIsNewTab, let home = webAddress(root["homepage"] as? String) {
            settings.homepage = home
        } else if session?["restore_on_startup"] as? Int == 4,
                  let first = webAddress((session?["startup_urls"] as? [Any])?.compactMap { $0 as? String }.first) {
            settings.homepage = first
        } else {
            settings.reasons[.homepage] = "\(browserName) opens its new tab page, not a web address."
        }
        settings.reasons[.newTabPage] = "\(browserName)'s new tab page is built in."

        if let bar = (root["bookmark_bar"] as? [String: Any])?["show_on_all_tabs"] as? Bool {
            settings.showBookmarksBar = bar
        } else {
            settings.reasons[.bookmarksBar] = "\(browserName)'s settings don't say whether its bookmarks bar is shown."
        }
        return settings
    }

    // MARK: - Firefox

    static func readFirefox(_ source: ImportSource) throws -> BrowserSettings {
        var settings = BrowserSettings()
        if FileManager.default.fileExists(atPath: source.settingsFile.path) {
            let text = String(decoding: try fileData(source.settingsFile, source), as: UTF8.self)
            settings = firefoxSettings(prefs: parseFirefoxPrefs(text))
        } else {
            settings = firefoxSettings(prefs: [:])
        }

        if let searchFile = source.searchFile, FileManager.default.fileExists(atPath: searchFile.path) {
            do {
                let json = try MozLZ4.decompress(try fileData(searchFile, source))
                if let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                   let engine = firefoxDefaultEngine(root) {
                    settings.searchEngineName = engine.name
                    settings.searchEngineURL = engine.url
                    settings.reasons[.searchEngine] = nil
                }
            } catch let error as MozLZ4.Error {
                settings.reasons[.searchEngine] = "Firefox's search.json.mozlz4 couldn't be decoded (\(error))."
            }
        }
        return settings
    }

    static func firefoxSettings(prefs: [String: Any]) -> BrowserSettings {
        var settings = BrowserSettings()
        settings.reasons[.searchEngine] = "Firefox's search engine list wasn't found, so it is using Firefox's default."

        if let pages = prefs["browser.startup.homepage"] as? String, let first = webAddress(pages.split(separator: "|").first.map(String.init)) {
            settings.homepage = first
        } else {
            settings.reasons[.homepage] = "Firefox opens its own Home page, not a web address."
        }
        settings.reasons[.newTabPage] = "Firefox's new tab page is built in."

        switch prefs["browser.toolbars.bookmarks.visibility"] as? String {
        case "always"?: settings.showBookmarksBar = true
        case "never"?: settings.showBookmarksBar = false
        case "newtab"?: settings.reasons[.bookmarksBar] = "Firefox shows its bookmarks bar only on the new tab page."
        default: settings.reasons[.bookmarksBar] = "Firefox's settings don't say whether its bookmarks bar is shown."
        }
        return settings
    }

    /// The default engine of a decoded `search.json.mozlz4`: its name and, when it has one, a GET search URL.
    static func firefoxDefaultEngine(_ root: [String: Any]) -> (name: String, url: String?)? {
        let meta = root["metaData"] as? [String: Any] ?? root["metadata"] as? [String: Any] ?? [:]
        let engines = root["engines"] as? [[String: Any]] ?? []
        let wanted = (meta["defaultEngineId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? meta["current"] as? String
        guard let wanted, !wanted.isEmpty else { return nil }
        let engine = engines.first { ($0["id"] as? String) == wanted } ?? engines.first { ($0["_name"] as? String) == wanted }
        guard let engine else { return (wanted, nil) }
        let name = engine["_name"] as? String ?? engine["id"] as? String ?? wanted
        // `_urls[0]` is the results page: `{template: "https://…/search", params: [{name: "q", value: "{searchTerms}"}]}`.
        var url: String?
        if let first = (engine["_urls"] as? [[String: Any]])?.first, let template = first["template"] as? String {
            let params = (first["params"] as? [[String: Any]] ?? []).compactMap { param -> String? in
                guard let key = param["name"] as? String, let value = param["value"] as? String else { return nil }
                return "\(key)=\(value)"
            }
            url = params.isEmpty ? template : template + (template.contains("?") ? "&" : "?") + params.joined(separator: "&")
        }
        return (name, url)
    }

    /// `user_pref("name", value);` lines: string, boolean and integer values; anything else is ignored.
    static func parseFirefoxPrefs(_ text: String) -> [String: Any] {
        var prefs: [String: Any] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("user_pref(") {
            var rest = line.dropFirst("user_pref(".count)
            guard let name = quotedString(&rest) else { continue }
            rest = rest.drop { $0 == " " || $0 == "," }
            if rest.hasPrefix("\"") {
                if let value = quotedString(&rest) { prefs[name] = value }
            } else {
                let word = rest.prefix { $0 != ")" && $0 != ";" }.trimmingCharacters(in: .whitespaces)
                if word == "true" { prefs[name] = true } else if word == "false" { prefs[name] = false } else if let number = Int(word) { prefs[name] = number }
            }
        }
        return prefs
    }

    /// Reads a JavaScript string literal at the start of `text` and advances past it.
    private static func quotedString(_ text: inout Substring) -> String? {
        guard text.first == "\"" else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                text = text[text.index(after: index)...]
                return result
            }
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                switch text[index] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "u":
                    let digits = text[text.index(after: index)...].prefix(4)
                    guard digits.count == 4, let scalar = UInt32(digits, radix: 16).flatMap(Unicode.Scalar.init) else { return nil }
                    result.unicodeScalars.append(scalar)
                    index = text.index(index, offsetBy: 4)
                default: result.append(text[index])
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Mapping onto config.json

/// What importing one browser's settings would do, item by item.
public struct SettingsImport: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Will change this value.
        case imported(String)
        /// The browser's value is already Paddle's.
        case unchanged(String)
        case skipped(String)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var setting: BrowserSettings.Setting
        public var status: Status
        public var id: String { setting.rawValue }
        public var title: String { setting.title }
    }

    public var items: [Item]
    /// The `config.json` edits, for the same write path as Settings (`AppModel.writeConfig`).
    public var changes: [ConfigChange]
    /// Bookmarks bar visibility is window state in Paddle, not a `config.json` key: the app applies it itself.
    public var showBookmarksBar: Bool?

    public var importedCount: Int {
        items.filter { if case .imported = $0.status { true } else { false } }.count
    }
}

public enum SettingsMapper {
    /// Maps `settings` onto `ConfigChange`s against `current`. A search engine Paddle doesn't offer is reported and
    /// left alone: nothing is invented from it. `currentShowBookmarksBar` is Paddle's present window state.
    public static func map(_ settings: BrowserSettings, current: PaddleConfig, currentShowBookmarksBar: Bool) -> SettingsImport {
        var items: [SettingsImport.Item] = []
        var changes: [ConfigChange] = []

        func skipped(_ setting: BrowserSettings.Setting, _ fallback: String) {
            items.append(.init(setting: setting, status: .skipped(settings.reasons[setting] ?? fallback)))
        }

        // Search engine.
        let preset = settings.searchEngineURL.flatMap(SearchEngine.preset(forSearchURL:))
            ?? settings.searchEngineName.flatMap(SearchEngine.preset(named:))
        if let preset, let engine = SearchEngine.engine(for: preset) {
            let already = current.searchTemplate == engine.searchTemplate && current.searchSuggestTemplate == engine.suggestTemplate
            if already {
                items.append(.init(setting: .searchEngine, status: .unchanged("\(engine.name), as in Paddle")))
            } else {
                changes.append(ConfigChange("searchTemplate", .string(engine.searchTemplate)))
                changes.append(ConfigChange("searchSuggestTemplate", .string(engine.suggestTemplate)))
                items.append(.init(setting: .searchEngine, status: .imported("\(engine.name) (search and address-bar suggestions)")))
            }
        } else if let name = settings.searchEngineName ?? settings.searchEngineURL {
            let offered = SearchEngine.presets.map(\.name).joined(separator: ", ")
            items.append(.init(setting: .searchEngine, status: .skipped(
                "\"\(name)\" isn't one of Paddle's engines (\(offered)), so your search engine stays. Set searchTemplate in config.json to use it.")))
        } else {
            skipped(.searchEngine, "No search engine found.")
        }

        // Pages.
        func page(_ setting: BrowserSettings.Setting, key: String, value: String?, now: String) {
            guard let value else { return skipped(setting, "Not set.") }
            if value == now {
                items.append(.init(setting: setting, status: .unchanged(value)))
            } else {
                changes.append(ConfigChange(key, .string(value)))
                items.append(.init(setting: setting, status: .imported(value)))
            }
        }
        page(.homepage, key: "homepage", value: settings.homepage, now: current.homepage)
        page(.newTabPage, key: "newTabPage", value: settings.newTabPage, now: current.newTabPage)

        // Bookmarks bar.
        var bar: Bool?
        if let shown = settings.showBookmarksBar {
            let word = shown ? "shown" : "hidden"
            if shown == currentShowBookmarksBar {
                items.append(.init(setting: .bookmarksBar, status: .unchanged("\(word), as in Paddle")))
            } else {
                bar = shown
                items.append(.init(setting: .bookmarksBar, status: .imported(word)))
            }
        } else {
            skipped(.bookmarksBar, "Not set.")
        }

        return SettingsImport(items: items, changes: changes, showBookmarksBar: bar)
    }
}
