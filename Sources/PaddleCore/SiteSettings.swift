import Foundation

/// Per-site settings from the `sites` key of `config.json`, keyed by host suffix like `siteUserAgents`:
/// `"sites": {"example.com": {"zoom": 1.25, "javaScript": false, "autoplay": "muted", "contentBlocking": false,
/// "location": "deny", "notifications": "allow", "httpsOnly": false, "freeze": "never"}}`. Every field is optional; a missing field means Paddle's default for
/// that host. User agents stay in `siteUserAgents`.
public struct SiteSettings: Codable, Sendable, Equatable {
    public enum Autoplay: String, Codable, Sendable, CaseIterable {
        case allow, muted, block
    }

    /// What a permission request (location, notifications) gets: `ask` prompts once per site per session, `allow` and
    /// `deny` answer without a prompt.
    public enum Permission: String, Codable, Sendable, CaseIterable {
        case ask, allow, deny
    }

    /// Whether this site's background tabs freeze. `auto` follows the global rules (a site allowed to notify stays
    /// live while `keepNotifyingSitesLive` is on); `never` keeps them running and out of idle sleep; `always` lets them
    /// freeze even when they may notify. Sound, the camera, the mic and uploads still keep a tab running either way.
    public enum Freeze: String, Codable, Sendable, CaseIterable {
        case auto, never, always
    }

    /// Per-site dark mode; unset (`nil`) means Auto (follow global rules).
    public enum SiteDarkMode: String, Sendable, Equatable, CaseIterable {
        case auto, light, dark, native
    }

    /// Page zoom as a factor; 1 is 100 %.
    public var zoom: Double?
    /// Whether pages on this site run JavaScript.
    public var javaScript: Bool?
    /// Whether media may start on its own, and with sound.
    public var autoplay: Autoplay?
    /// Whether the content blocker applies on this site.
    public var contentBlocking: Bool?
    /// What a geolocation request gets without a prompt.
    public var location: Permission?
    /// What a notification request gets without a prompt. Web Push (notifications while the site is closed) is not
    /// supported.
    public var notifications: Permission?
    /// False lets this site load over http:// without the HTTPS-only upgrade.
    public var httpsOnly: Bool?
    /// True lets pages on this site open windows without a click (pop-ups). Unset or false: a window a script opens
    /// on its own may still download a file, but a page in it is blocked, with a Pop-up blocked button to open it.
    public var popups: Bool?
    /// Per-site dark mode: `light`, `dark`, or `native`; unset follows the global setting (Auto).
    public var darkMode: SiteDarkMode?
    /// Whether background tabs on this site freeze (see `Freeze`).
    public var freeze: Freeze?

    public init(
        zoom: Double? = nil,
        javaScript: Bool? = nil,
        autoplay: Autoplay? = nil,
        contentBlocking: Bool? = nil,
        location: Permission? = nil,
        notifications: Permission? = nil,
        httpsOnly: Bool? = nil,
        popups: Bool? = nil,
        darkMode: SiteDarkMode? = nil,
        freeze: Freeze? = nil
    ) {
        self.zoom = zoom
        self.javaScript = javaScript
        self.autoplay = autoplay
        self.contentBlocking = contentBlocking
        self.location = location
        self.notifications = notifications
        self.httpsOnly = httpsOnly
        self.popups = popups
        self.darkMode = darkMode
        self.freeze = freeze
    }

    private enum CodingKeys: String, CodingKey {
        case zoom, javaScript, autoplay, contentBlocking, location, notifications, httpsOnly, popups, darkMode, freeze
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom)
        javaScript = try container.decodeIfPresent(Bool.self, forKey: .javaScript)
        autoplay = try container.decodeIfPresent(Autoplay.self, forKey: .autoplay)
        contentBlocking = try container.decodeIfPresent(Bool.self, forKey: .contentBlocking)
        location = try container.decodeIfPresent(Permission.self, forKey: .location)
        notifications = try container.decodeIfPresent(Permission.self, forKey: .notifications)
        httpsOnly = try container.decodeIfPresent(Bool.self, forKey: .httpsOnly)
        popups = try container.decodeIfPresent(Bool.self, forKey: .popups)
        freeze = try container.decodeIfPresent(Freeze.self, forKey: .freeze)
        darkMode = try Self.decodeDarkMode(from: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(zoom, forKey: .zoom)
        try container.encodeIfPresent(javaScript, forKey: .javaScript)
        try container.encodeIfPresent(autoplay, forKey: .autoplay)
        try container.encodeIfPresent(contentBlocking, forKey: .contentBlocking)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(notifications, forKey: .notifications)
        try container.encodeIfPresent(httpsOnly, forKey: .httpsOnly)
        try container.encodeIfPresent(popups, forKey: .popups)
        try container.encodeIfPresent(freeze, forKey: .freeze)
        if let darkMode { try container.encode(darkMode.rawValue, forKey: .darkMode) }
    }

    private static func decodeDarkMode(from container: KeyedDecodingContainer<CodingKeys>) throws -> SiteDarkMode? {
        guard container.contains(.darkMode) else { return nil }
        if try container.decodeNil(forKey: .darkMode) { return nil }
        if let bool = try? container.decode(Bool.self, forKey: .darkMode) {
            return bool ? .dark : .light
        }
        let raw = try container.decode(String.self, forKey: .darkMode)
        if raw == "auto" { return nil }
        guard let mode = SiteDarkMode(rawValue: raw), mode != .auto else {
            throw DecodingError.dataCorruptedError(forKey: .darkMode, in: container, debugDescription: "Unknown darkMode \"\(raw)\"")
        }
        return mode
    }

    /// True when no field is set, so the entry says nothing and can be dropped.
    public var isEmpty: Bool {
        zoom == nil && javaScript == nil && autoplay == nil && contentBlocking == nil && location == nil
            && notifications == nil && httpsOnly == nil && popups == nil && darkMode == nil && freeze == nil
    }

    /// `other` laid over self: every field `other` sets replaces the one here.
    func overlaid(with other: SiteSettings) -> SiteSettings {
        SiteSettings(
            zoom: other.zoom ?? zoom,
            javaScript: other.javaScript ?? javaScript,
            autoplay: other.autoplay ?? autoplay,
            contentBlocking: other.contentBlocking ?? contentBlocking,
            location: other.location ?? location,
            notifications: other.notifications ?? notifications,
            httpsOnly: other.httpsOnly ?? httpsOnly,
            popups: other.popups ?? popups,
            darkMode: other.darkMode ?? darkMode,
            freeze: other.freeze ?? freeze
        )
    }
}

extension PaddleConfig {
    /// A host or a `sites` / `siteUserAgents` key in the form `URL.host` gives: lowercase, no trailing dot, and
    /// an international name as punycode (`"bücher.de"` → `"xn--bcher-kva.de"`), so a key the user typed matches
    /// the host WebKit reports. Keys that can't form a URL (a port, a path, `*`) come back lowercased and match nothing
    /// but themselves; the validator warns about them.
    public static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard host.contains(where: { !$0.isASCII }), let encoded = URL(string: "https://\(host)/")?.host else {
            return host
        }
        return encoded
    }

    /// True when `key` (a `sites` / `siteUserAgents` key) covers `host`: the same host, or a parent domain of it.
    /// Both sides go through `normalizedHost`.
    static func hostKey(_ key: String, matches host: String) -> Bool {
        let key = normalizedHost(key)
        return host == key || host.hasSuffix("." + key)
    }

    /// Orders host keys that cover one host least specific first: by the length of the normalized host (so a
    /// punycode parent sorts before its Unicode-spelled child), then by the key as written, so two spellings of one
    /// host (`Example.com`, `example.COM`) always resolve the same way rather than in dictionary order.
    static func hostKeyPrecedes(_ a: String, _ b: String) -> Bool {
        let (lengthA, lengthB) = (normalizedHost(a).count, normalizedHost(b).count)
        return lengthA != lengthB ? lengthA < lengthB : a < b
    }

    /// The `sites` entry keys that cover `host`: the host itself and each parent domain that has an entry,
    /// shortest (least specific) first. Matching is the same as `userAgent(forHost:)`.
    public func siteSettingsKeys(forHost host: String) -> [String] {
        let host = PaddleConfig.normalizedHost(host)
        return sites.keys
            .filter { PaddleConfig.hostKey($0, matches: host) }
            .sorted(by: PaddleConfig.hostKeyPrecedes)
    }

    /// The settings that apply to `host`, merged per field: the entry for the longest matching host suffix wins a
    /// field, and fields it leaves unset come from the next parent domain. Empty when no entry matches.
    public func siteSettings(forHost host: String) -> SiteSettings {
        siteSettingsKeys(forHost: host).reduce(SiteSettings()) { merged, key in
            merged.overlaid(with: sites[key] ?? SiteSettings())
        }
    }
}

/// The user agents Settings > Sites offers for `siteUserAgents`, for sites that refuse Safari or serve it less.
/// Chrome and Firefox on a Mac at `BrowserVersions.current`, the same strings the extension personas send. The
/// whole string goes into config.json, so an entry keeps the version it was set with; anything else there
/// (including an older preset once the versions are bumped) shows as Custom.
public enum UserAgentPreset: String, CaseIterable, Sendable {
    case chrome, firefox

    public var title: String {
        switch self {
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }

    public var value: String {
        let persona: Persona = switch self {
        case .chrome: .chrome
        case .firefox: .firefox
        }
        return persona.userAgent(.current) ?? ""
    }

    /// The preset whose string is exactly `value`.
    public init?(value: String) {
        guard let match = Self.allCases.first(where: { $0.value == value }) else { return nil }
        self = match
    }
}
