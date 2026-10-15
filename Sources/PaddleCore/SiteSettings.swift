import Foundation

/// Per-site settings from the `sites` key of `config.json`, keyed by host suffix like `siteUserAgents`:
/// `"sites": {"example.com": {"zoom": 1.25, "javaScript": false, "autoplay": "muted", "contentBlocking": false,
/// "location": "deny", "notifications": "allow", "httpsOnly": false}}`. Every field is optional; a missing field means Paddle's default for
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

    public init(
        zoom: Double? = nil,
        javaScript: Bool? = nil,
        autoplay: Autoplay? = nil,
        contentBlocking: Bool? = nil,
        location: Permission? = nil,
        notifications: Permission? = nil,
        httpsOnly: Bool? = nil
    ) {
        self.zoom = zoom
        self.javaScript = javaScript
        self.autoplay = autoplay
        self.contentBlocking = contentBlocking
        self.location = location
        self.notifications = notifications
        self.httpsOnly = httpsOnly
    }

    /// True when no field is set, so the entry says nothing and can be dropped.
    public var isEmpty: Bool {
        zoom == nil && javaScript == nil && autoplay == nil && contentBlocking == nil && location == nil
            && notifications == nil && httpsOnly == nil
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
            httpsOnly: other.httpsOnly ?? httpsOnly
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
