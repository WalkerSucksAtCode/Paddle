import Foundation

/// A profile's own values for some config.json keys (`settings` of its profiles.json entry). Written like a partial
/// config.json: `{"searchTemplate": "…", "tabSleepAfterMinutes": 30, "sites": {"x.com": {"zoom": 1.2}}}`. A key the
/// profile doesn't set is config.json's value. Only the keys in `keys` (and the `sites` fields in `siteFields`) can be
/// set per profile: the others configure things all profiles share (the one WebKit content controller with its block
/// lists, scripts and personas; app-wide appearance; menus; the bridge) or a limit across every window.
public enum ProfileOverrides {
    /// What an override edits, so Settings shows the right control.
    public enum Kind: Sendable, Equatable {
        case toggle
        /// A number in `range`; `zero` names what 0 means ("Off", "No limit"), `unit` follows the number.
        case number(range: ClosedRange<Double>, step: Double, zero: String?, unit: String)
        /// Text, with named values a menu can fill in.
        case text(placeholder: String, presets: [Choice])
        case choice([Choice])
        /// A theme id; Settings lists the installed themes.
        case theme
        /// A color setting: `automatic` (its word), a `ColorPreset` name or `#rrggbb`.
        case color(automatic: String)
    }

    public struct Choice: Sendable, Equatable, Hashable {
        public var value: String
        public var label: String
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    /// One setting a profile can override: a top-level key (`path` one long) or a `sites` field
    /// (`["sites", "*", field]`, the host left open).
    public struct Setting: Sendable, Equatable, Identifiable {
        public var key: String
        public var title: String
        /// The Settings pane it lives in, for grouping.
        public var group: String
        public var kind: Kind
        public var id: String { key }
    }

    /// Top-level keys a profile can set, in the order Settings lists them.
    public static let settings: [Setting] = [
        Setting(key: "homepage", title: "Home page", group: "General", kind: .text(placeholder: "https://…", presets: [Choice("about:blank", "Blank page"), Choice("paddle://newtab", "New Tab page")])),
        Setting(key: "newTabPage", title: "New tabs open", group: "General", kind: .text(placeholder: "paddle://newtab", presets: [Choice("paddle://newtab", "New Tab page"), Choice("about:blank", "Blank page")])),
        Setting(key: "searchTemplate", title: "Search engine", group: "General", kind: .text(
            placeholder: "https://…?q=%s",
            presets: SearchEngine.presets.map { Choice($0.searchTemplate, $0.name) })),
        Setting(key: "searchSuggestTemplate", title: "Search suggestions", group: "General", kind: .text(
            placeholder: "Empty: off",
            presets: [Choice("", "Off")] + SearchEngine.presets.filter { !$0.suggestTemplate.isEmpty }.map { Choice($0.suggestTemplate, $0.name) })),
        Setting(key: "newTabFrequentSites", title: "Frequently visited on New Tab", group: "General", kind: .toggle),
        Setting(key: "historyDays", title: "Keep history for", group: "General", kind: .number(range: 0...3650, step: 1, zero: "Off", unit: "days")),
        Setting(key: "askWhereToDownload", title: "Ask where to save downloads", group: "General", kind: .toggle),
        Setting(key: "downloadFolder", title: "Download folder", group: "General", kind: .text(placeholder: "~/Downloads", presets: [])),
        Setting(key: "theme", title: "Theme", group: "Appearance", kind: .theme),
        Setting(key: "accentColor", title: "Accent color", group: "Appearance", kind: .color(automatic: "system")),
        Setting(key: "chromeTint", title: "Chrome tint", group: "Appearance", kind: .color(automatic: "none")),
        Setting(key: "chromeTintStrength", title: "Tint strength", group: "Appearance", kind: .number(range: 0...100, step: 5, zero: nil, unit: "%")),
        Setting(key: "tabFreezeAfterMinutes", title: "Freeze background tabs after", group: "Tabs & Memory", kind: .number(range: 0...1440, step: 1, zero: "Off", unit: "min")),
        Setting(key: "tabSleepAfterMinutes", title: "Sleep background tabs after", group: "Tabs & Memory", kind: .number(range: 0...1440, step: 1, zero: "Off", unit: "min")),
        Setting(key: "sleepPinnedTabs", title: "Let pinned tabs sleep", group: "Tabs & Memory", kind: .toggle),
        Setting(key: "cpuSleepPercent", title: "Sleep a tab using CPU", group: "Tabs & Memory", kind: .number(range: 0...100, step: 5, zero: "Off", unit: "% of a core")),
        Setting(key: "keepPageWorkRunning", title: "Keep uploads and unsaved changes running", group: "Tabs & Memory", kind: .toggle),
        Setting(key: "keepNotifyingSitesLive", title: "Keep sites that can notify you live", group: "Tabs & Memory", kind: .toggle),
        Setting(key: "linkPreview", title: "Preview links on ⌥-click", group: "Tabs & Memory", kind: .toggle),
        Setting(key: "resumeMediaOnSelect", title: "Play the tab you switch to", group: "Tabs & Memory", kind: .toggle),
    ]

    private static let permissionChoices = SiteSettings.Permission.allCases.map { Choice($0.rawValue, $0.rawValue.capitalized) }

    /// `sites` fields a profile can set. Not `contentBlocking` (compiled into the shared block lists) or `darkMode`
    /// (the dark mode script is shared by every profile).
    public static let siteSettings: [Setting] = [
        Setting(key: "zoom", title: "Zoom", group: "Sites", kind: .number(range: 0.3...3, step: 0.1, zero: nil, unit: "×")),
        Setting(key: "javaScript", title: "JavaScript", group: "Sites", kind: .toggle),
        Setting(key: "autoplay", title: "Autoplay", group: "Sites", kind: .choice(SiteSettings.Autoplay.allCases.map { Choice($0.rawValue, $0.rawValue.capitalized) })),
        Setting(key: "location", title: "Location", group: "Sites", kind: .choice(permissionChoices)),
        Setting(key: "notifications", title: "Notifications", group: "Sites", kind: .choice(permissionChoices)),
        Setting(key: "popups", title: "Pop-ups", group: "Sites", kind: .toggle),
        Setting(key: "httpsOnly", title: "HTTPS only", group: "Sites", kind: .toggle),
        Setting(key: "freeze", title: "Freeze", group: "Sites", kind: .choice(SiteSettings.Freeze.allCases.map { Choice($0.rawValue, $0.rawValue.capitalized) })),
    ]

    public static let sitesKey = PaddleConfig.CodingKeys.sites.rawValue
    public static let keys: Set<String> = Set(settings.map(\.key))
    public static let siteFields: Set<String> = Set(siteSettings.map(\.key))

    public static func setting(key: String) -> Setting? { settings.first { $0.key == key } }
    public static func siteSetting(field: String) -> Setting? { siteSettings.first { $0.key == field } }

    /// Whether `path` is something a profile can set: `[key]` for a key in `keys`, or `["sites", host, field]`.
    public static func isAllowed(_ path: [String]) -> Bool {
        switch path.count {
        case 1: keys.contains(path[0])
        case 3: path[0] == sitesKey && !path[1].isEmpty && siteFields.contains(path[2])
        default: false
        }
    }

    /// `settings` with only what a profile can set, and the paths dropped (unknown or shared keys, `sites` fields that
    /// can't be per profile, a `sites` that isn't an object), for a warning.
    public static func sanitized(_ settings: [String: JSONValue]) -> (kept: [String: JSONValue], dropped: [String]) {
        var kept: [String: JSONValue] = [:]
        var dropped: [String] = []
        for (key, value) in settings {
            if key == sitesKey {
                guard case .object(let hosts) = value else { dropped.append(key); continue }
                var keptHosts: [String: JSONValue] = [:]
                for (host, entry) in hosts {
                    guard case .object(let fields) = entry else { dropped.append("\(key).\(host)"); continue }
                    let allowed = fields.filter { siteFields.contains($0.key) }
                    dropped += fields.keys.filter { !siteFields.contains($0) }.map { "\(key).\(host).\($0)" }
                    if !allowed.isEmpty { keptHosts[host] = .object(allowed) }
                }
                if !keptHosts.isEmpty { kept[key] = .object(keptHosts) }
            } else if keys.contains(key) {
                kept[key] = value
            } else {
                dropped.append(key)
            }
        }
        return (kept, dropped.sorted())
    }

    /// config.json's object with the profile's settings laid over it: a top-level key replaces the global value, and
    /// `sites` merges per host and then per field, so a profile's zoom for a site keeps the global JavaScript setting.
    /// Only what `sanitized` keeps is applied.
    public static func merged(global: [String: JSONValue], overrides: [String: JSONValue]) -> [String: JSONValue] {
        var result = global
        for (key, value) in sanitized(overrides).kept {
            guard key == sitesKey, case .object(let hosts) = value else {
                result[key] = value
                continue
            }
            var sites = global[key]?.objectValue ?? [:]
            for (host, entry) in hosts {
                var fields = sites[host]?.objectValue ?? [:]
                for (field, fieldValue) in entry.objectValue ?? [:] { fields[field] = fieldValue }
                sites[host] = .object(fields)
            }
            result[key] = .object(sites)
        }
        return result
    }

    /// The config a profile runs with: `globalData` (config.json's bytes; empty reads as `{}`) merged with `overrides`
    /// and decoded leniently, as config.json is. `issues` are the problems the profile's values add (a wrong type falls
    /// back to config.json's default, as there), not ones config.json already has. Throws only when config.json isn't
    /// a JSON object.
    public static func effectiveConfig(globalData: Data, overrides: [String: JSONValue]) throws -> (config: PaddleConfig, issues: [ConfigIssue]) {
        let global = try object(from: globalData)
        let globalIssues = try PaddleConfig.decodeReportingIssues(render(global)).issues
        let decoded = try PaddleConfig.decodeReportingIssues(render(merged(global: global, overrides: overrides)))
        let known = Set(globalIssues.map(\.id))
        return (decoded.config, decoded.issues.filter { !known.contains($0.id) })
    }

    /// A JSON object's bytes as values; empty data (or a lone byte-order mark) is `{}`.
    public static func object(from data: Data) throws -> [String: JSONValue] {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data
        if body.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        guard case .object(let object) = JSONValue(try JSONSerialization.jsonObject(with: Data(body), options: [.fragmentsAllowed])) else {
            throw JSONSpans.ScanError.notAnObject
        }
        return object
    }

    static func render(_ object: [String: JSONValue]) -> Data {
        Data(JSONValue.object(object).render(unit: "").utf8)
    }

    /// Every value the profile sets, flattened for listing: `["searchTemplate"]` and `["sites", host, field]`, top-level
    /// keys in `settings` order, then sites by host and field.
    public static func entries(_ overrides: [String: JSONValue]) -> [(path: [String], value: JSONValue)] {
        let kept = sanitized(overrides).kept
        var list: [(path: [String], value: JSONValue)] = settings.compactMap { setting in
            kept[setting.key].map { ([setting.key], $0) }
        }
        for (host, entry) in (kept[sitesKey]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let fields = entry.objectValue ?? [:]
            for setting in siteSettings {
                if let value = fields[setting.key] { list.append(([sitesKey, host, setting.key], value)) }
            }
        }
        return list
    }

    /// `overrides` with `path` set to `value`, or removed for nil (a `sites` host left empty goes too). Nil when
    /// `path` isn't something a profile can set.
    public static func setting(_ overrides: [String: JSONValue], path: [String], to value: JSONValue?) -> [String: JSONValue]? {
        guard isAllowed(path) else { return nil }
        var result = overrides
        if path.count == 1 {
            result[path[0]] = value
            return result
        }
        let (host, field) = (path[1], path[2])
        var sites = result[sitesKey]?.objectValue ?? [:]
        var fields = sites[host]?.objectValue ?? [:]
        fields[field] = value
        sites[host] = fields.isEmpty ? nil : .object(fields)
        result[sitesKey] = sites.isEmpty ? nil : .object(sites)
        return result
    }
}

extension ProfileOverrides {
    /// The value `config` runs with at an override `path`, as config.json writes it: a top-level key's value, or a
    /// `sites` field as the site's policy has it (the field's default, or `defaultZoom`, when no entry sets it).
    public static func value(at path: [String], in config: PaddleConfig) -> JSONValue? {
        if path.count == 1 {
            guard let data = try? config.encoded(), let object = try? Self.object(from: data) else { return nil }
            return object[path[0]]
        }
        guard path.count == 3, path[0] == sitesKey else { return nil }
        let policy = config.sitePolicy(forHost: path[1])
        return switch path[2] {
        case "zoom": .number(policy.zoom)
        case "javaScript": .bool(policy.javaScript)
        case "autoplay": .string(policy.autoplay.rawValue)
        case "location": .string(policy.location.rawValue)
        case "notifications": .string(policy.notifications.rawValue)
        case "popups": .bool(policy.popups)
        case "httpsOnly": .bool(policy.httpsOnly)
        case "freeze": .string(policy.freeze.rawValue)
        default: nil
        }
    }

    /// `value` in words for `kind`: On/Off, "30 min", a choice's or preset's label, the text itself.
    public static func describe(_ value: JSONValue?, as kind: Kind) -> String {
        switch (kind, value) {
        case (_, nil), (_, .null?): return "Not set"
        case (.toggle, .bool(let on)?): return on ? "On" : "Off"
        case (.number(_, _, let zero, let unit), .number(let number)?):
            if number == 0, let zero { return zero }
            let text = number.formatted(.number.precision(.fractionLength(0...2)))
            return unit == "%" || unit == "×" ? "\(text)\(unit)" : "\(text) \(unit)"
        case (.text(_, let presets), .string(let text)?):
            if let preset = presets.first(where: { $0.value == text }) { return preset.label }
            return text.isEmpty ? "Empty" : text
        case (.choice(let choices), .string(let text)?):
            return choices.first { $0.value == text }?.label ?? text
        case (.color(let automatic), .string(let text)?):
            if text == automatic { return "Automatic" }
            return ColorPreset(rawValue: text)?.displayName ?? text
        case (_, .string(let text)?): return text
        case (_, let other?): return other.render(unit: "")
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let bool = try? c.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? c.decode(Double.self) { self = .number(number) }
        else if let string = try? c.decode(String.self) { self = .string(string) }
        else if let array = try? c.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let bool): try c.encode(bool)
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { try c.encode(Int64(number)) } else { try c.encode(number) }
        case .string(let string): try c.encode(string)
        case .array(let array): try c.encode(array)
        case .object(let object): try c.encode(object)
        }
    }
}
