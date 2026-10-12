import Foundation

/// One thing wrong with a config value, in words someone can act on.
public struct ConfigIssue: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable {
        /// Paddle can't use the value: Settings refuses to save that key until it is fixed.
        case error
        /// Probably a mistake, but Paddle runs with it.
        case warning
    }

    /// The top-level `config.json` key the issue belongs to.
    public var key: PaddleConfig.CodingKeys
    /// Where inside the key, e.g. `["shortcuts", "nextTab"]`; just the key for a plain value.
    public var path: [String]
    public var severity: Severity
    public var message: String

    public var id: String { path.joined(separator: ".") + ": " + message }

    public init(key: PaddleConfig.CodingKeys, path: [String]? = nil, severity: Severity, message: String) {
        self.key = key
        self.path = path ?? [key.rawValue]
        self.severity = severity
        self.message = message
    }
}

/// Checks a decoded config for values that parse but can't work. The decoder already rejects wrong types.
public enum ConfigValidator {
    /// Every issue, in key order. `actionNames` are the menu action names `shortcuts` may bind; `defaults` are the
    /// keys each action has before `shortcuts` changes it (more than one for an action with a hidden alias), so a
    /// binding that takes a default's key is reported too.
    public static func issues(
        _ config: PaddleConfig, actionNames: Set<String>, defaults: [String: [Shortcut]] = [:]
    ) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        issues += pageIssues(config.homepage, key: .homepage)
        issues += pageIssues(config.newTabPage, key: .newTabPage)
        issues += templateIssues(config.searchTemplate, key: .searchTemplate, what: "The search URL")
        if !config.searchSuggestTemplate.isEmpty {
            issues += templateIssues(config.searchSuggestTemplate, key: .searchSuggestTemplate, what: "The suggestions URL")
        }

        for (key, value) in [
            (PaddleConfig.CodingKeys.historyDays, Double(config.historyDays)),
            (.tabSleepAfterMinutes, config.tabSleepAfterMinutes),
            (.maxAwakeTabs, Double(config.maxAwakeTabs)),
            (.sessionHistoryTabs, Double(config.sessionHistoryTabs)),
            (.filterUpdateDays, Double(config.filterUpdateDays)),
        ] where value < 0 {
            issues.append(ConfigIssue(key: key, severity: .error, message: "Can't be negative (0 turns it off)."))
        }

        for (index, list) in config.filterLists.enumerated() where FilterUpdatePolicy.fileName(forList: list) == nil {
            issues.append(ConfigIssue(
                key: .filterLists, path: ["filterLists", String(index)], severity: .warning,
                message: "\"\(list)\" is not an https URL, so it is never downloaded or used."
            ))
        }

        for host in config.siteUserAgents.keys.sorted() {
            issues += hostKeyIssues(host, key: .siteUserAgents)
            if config.siteUserAgents[host]?.isEmpty == true {
                issues.append(ConfigIssue(
                    key: .siteUserAgents, path: ["siteUserAgents", host], severity: .warning,
                    message: "The user agent for \(host) is empty; WebKit's own is used instead."
                ))
            }
        }

        for host in config.sites.keys.sorted() {
            issues += hostKeyIssues(host, key: .sites)
            if let zoom = config.sites[host]?.zoom, !(zoom > 0) {
                issues.append(ConfigIssue(
                    key: .sites, path: ["sites", host, "zoom"], severity: .error,
                    message: "Zoom must be above 0 (1 is 100 %)."
                ))
            }
        }

        issues += shortcutIssues(config.shortcuts, actionNames: actionNames, defaults: defaults)
        return issues
    }

    /// True when an error (not a warning) is open against `key`, so saving it must wait. With `path`, only errors
    /// on that entry or inside it count (`["sites", "example.com"]` ignores a bad zoom on another host), so one
    /// stale entry doesn't freeze the whole key.
    public static func blocks(_ key: PaddleConfig.CodingKeys, path: [String]? = nil, in issues: [ConfigIssue]) -> Bool {
        issues.contains { issue in
            guard issue.key == key, issue.severity == .error else { return false }
            guard let path else { return true }
            return issue.path.starts(with: path) || path.starts(with: issue.path)
        }
    }

    /// `sites` / `siteUserAgents` keys are host suffixes: anything with a scheme, port, path, wildcard or space
    /// can never equal a URL's host, so it silently applies to nothing.
    private static func hostKeyIssues(_ host: String, key: PaddleConfig.CodingKeys) -> [ConfigIssue] {
        let path = [key.rawValue, host]
        if host.isEmpty {
            return [ConfigIssue(key: key, path: path, severity: .warning, message: "An empty host matches no site.")]
        }
        guard host.contains(where: { ":/*".contains($0) || $0.isWhitespace }) else { return [] }
        return [ConfigIssue(
            key: key, path: path, severity: .warning,
            message: "\"\(host)\" is not a host, so it matches no site. Use just the host, like \"example.com\"."
        )]
    }

    private static let pageSchemes: Set<String> = ["http", "https", "file", "about"]

    /// `homepage` / `newTabPage`: the app loads them with `URL(string:)`, so anything else silently becomes blank.
    private static func pageIssues(_ value: String, key: PaddleConfig.CodingKeys) -> [ConfigIssue] {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return [ConfigIssue(key: key, severity: .error, message: "Not a URL. Use https://…, file://… or about:blank.")]
        }
        guard pageSchemes.contains(scheme) else {
            return [ConfigIssue(key: key, severity: .warning, message: "\(scheme): pages may not load. Expected http, https, file or about.")]
        }
        return []
    }

    /// Search templates: `%s` is required (`SearchSuggestions.requestURL` returns nil without it, and a search URL
    /// without it searches for nothing); a non-web scheme is suspicious but allowed.
    private static func templateIssues(_ template: String, key: PaddleConfig.CodingKeys, what: String) -> [ConfigIssue] {
        guard template.contains("%s") else {
            return [ConfigIssue(key: key, severity: .error, message: "\(what) needs %s where the search words go.")]
        }
        let scheme = URL(string: template.replacingOccurrences(of: "%s", with: "q"))?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return [ConfigIssue(key: key, severity: .warning, message: "\(what) should start with https:// (or http://).")]
        }
        return []
    }

    /// `shortcuts`: a name that is no menu action is a warning (`MainMenu.applyShortcuts` skips it, so Paddle runs;
    /// it is how an entry looks after an action is renamed), a value that doesn't parse is an error, and two
    /// actions on one key is a warning on each configured entry because only one of them can win. Defaults take
    /// part in the duplicate check unless `shortcuts` replaces them (`"none"` clears one).
    private static func shortcutIssues(
        _ shortcuts: [String: String], actionNames: Set<String>, defaults: [String: [Shortcut]]
    ) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        var bound: [Shortcut: [String]] = [:]
        for (name, keys) in defaults where shortcuts[name] == nil {
            for key in keys where !key.key.isEmpty { bound[key.canonical, default: []].append(name) }
        }
        for name in shortcuts.keys.sorted() {
            let text = shortcuts[name] ?? ""
            let path = ["shortcuts", name]
            if !actionNames.contains(name) {
                issues.append(ConfigIssue(
                    key: .shortcuts, path: path, severity: .warning,
                    message: "\"\(name)\" is not a menu action, so this entry binds nothing. See the README for action names."
                ))
            }
            guard let shortcut = Shortcut.parse(text) else {
                issues.append(ConfigIssue(
                    key: .shortcuts, path: path, severity: .error,
                    message: "\"\(text)\" is not a shortcut. Use modifiers and a key like \"cmd+shift+k\", or \"none\"."
                ))
                continue
            }
            if !shortcut.key.isEmpty { bound[shortcut, default: []].append(name) }
        }
        for (shortcut, names) in bound where names.count > 1 {
            let list = names.sorted().joined(separator: ", ")
            for name in names where shortcuts[name] != nil {
                issues.append(ConfigIssue(
                    key: .shortcuts, path: ["shortcuts", name], severity: .warning,
                    message: "\(shortcut.displayText) is bound to more than one action (\(list)); only one can respond."
                ))
            }
        }
        return issues.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }
}
