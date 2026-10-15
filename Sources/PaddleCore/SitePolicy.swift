import Foundation

/// What Paddle does on one host: its `sites` settings (longest matching host suffix first, per field, as
/// `PaddleConfig.siteSettings(forHost:)` merges them) with Paddle's default filled in for every field left unset.
public struct SitePolicy: Sendable, Equatable {
    /// Page zoom as a factor; 1 is 100 %.
    public var zoom: Double
    public var javaScript: Bool
    public var autoplay: SiteSettings.Autoplay
    /// False takes the host out of every block list (a site-wide exception compiled into each list).
    public var contentBlocking: Bool
    public var location: SiteSettings.Permission
    public var notifications: SiteSettings.Permission
    /// False lets the host load over http:// in HTTPS-only mode.
    public var httpsOnly: Bool

    /// Paddle's defaults: 100 %, JavaScript on, media may autoplay muted (Safari's "Stop media with sound"),
    /// blocking on, location and notifications asked once per site per session.
    public static let defaults = SitePolicy(SiteSettings())

    /// `defaultZoom` is the zoom of a site with no `zoom` of its own (`PaddleConfig.defaultZoom`).
    public init(_ settings: SiteSettings, defaultZoom: Double = 1) {
        zoom = settings.zoom.map(Self.normalizedZoom) ?? Self.normalizedZoom(defaultZoom)
        javaScript = settings.javaScript ?? true
        autoplay = settings.autoplay ?? .muted
        contentBlocking = settings.contentBlocking ?? true
        location = settings.location ?? .ask
        notifications = settings.notifications ?? .ask
        httpsOnly = settings.httpsOnly ?? true
    }

    /// The smallest and largest zoom Zoom In / Zoom Out reach, and their step.
    public static let zoomRange: ClosedRange<Double> = 0.3...3
    public static let zoomStep = 0.1

    /// `zoom` clamped to `zoomRange` and rounded to whole percent, so repeated steps write `1.1`, not
    /// `1.1000000000000001`.
    public static func normalizedZoom(_ zoom: Double) -> Double {
        (min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound) * 100).rounded() / 100
    }

    /// True when the website data record WebKit names `displayName` (a registrable domain such as `example.com`;
    /// WebKit groups `www.` and every other subdomain under it) holds data of `host`.
    public static func dataRecord(_ displayName: String, covers host: String) -> Bool {
        let name = PaddleConfig.normalizedHost(displayName)
        let host = PaddleConfig.normalizedHost(host)
        guard !name.isEmpty, !host.isEmpty else { return false }
        return host == name || host.hasSuffix("." + name)
    }
}

extension PaddleConfig {
    /// The effective settings for `host` (see `SitePolicy`).
    public func sitePolicy(forHost host: String) -> SitePolicy {
        SitePolicy(siteSettings(forHost: host), defaultZoom: defaultZoom)
    }

    /// Hosts of `sites` keys with `contentBlocking: false`, for the block lists' site exceptions
    /// (`SharedExceptions`) and the scriptlets' excludes: normalized (`normalizedHost`), deduplicated, and only
    /// keys that are plain hosts, so both see the same hosts and a key like `host:8080` or `*` is left out rather than
    /// matching nothing or everything. An exception covers the host's subdomains too, so a subdomain entry setting
    /// `contentBlocking: true` under such a key can't turn blocking back on there.
    public var blockingOffHosts: [String] {
        let hosts = sites.filter { $0.value.contentBlocking == false }.keys.map(PaddleConfig.normalizedHost)
        return Set(hosts).filter(PaddleConfig.isPlainHost).sorted()
    }

    /// Notification answers the `sites` settings fix in advance, for WebKit's permission lookup on page load
    /// (`_WKWebsiteDataStoreDelegate`'s `notificationPermissionsForWebsiteDataStore:`): `true` for `allow`, `false` for
    /// `deny`, keyed by origin (`https://example.com` and `http://example.com`, for each plain host with an entry). A
    /// host's value is its own effective `notifications`, so a subdomain entry wins over its parent's. `ask` gives no
    /// key: WebKit then reports the permission as default and asks through the UI delegate. Subdomains that only a
    /// parent entry covers are not listed; WebKit looks up exact origins.
    public var notificationPermissions: [String: Bool] {
        let hosts = Set(sites.keys.map(PaddleConfig.normalizedHost)).filter(PaddleConfig.isPlainHost)
        var answers: [String: Bool] = [:]
        for host in hosts {
            let answer: Bool
            switch sitePolicy(forHost: host).notifications {
            case .allow: answer = true
            case .deny: answer = false
            case .ask: continue
            }
            answers["https://\(host)"] = answer
            answers["http://\(host)"] = answer
        }
        return answers
    }

    /// Letters, digits, dots and hyphens, not starting or ending with a dot: a host a match pattern or rule can name.
    public static func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            && host.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    /// The `sites` key a zoom change on `host` is remembered under: the most specific entry that already sets a zoom
    /// (so a zoom set for `example.com` is changed for the whole domain), else an entry for the host itself, else the
    /// host without a leading `www.` (so `www.example.com` and `example.com` share it). Keys come back as written
    /// in the file, so the edit replaces that entry rather than adding a second spelling of it.
    public func zoomKey(forHost host: String) -> String {
        let normalized = PaddleConfig.normalizedHost(host)
        let keys = siteSettingsKeys(forHost: normalized)
        if let key = keys.last(where: { sites[$0]?.zoom != nil }) { return key }
        if let key = ownKey(normalized) { return key }
        if normalized.hasPrefix("www."), normalized.split(separator: ".").count > 2 { return String(normalized.dropFirst(4)) }
        return normalized
    }

    /// The `sites` key for `host` itself: its entry's key as written in the file, else the normalized host. Where an
    /// answer about this host alone is remembered (a location prompt's "Remember").
    public func siteKey(forHost host: String) -> String {
        let normalized = PaddleConfig.normalizedHost(host)
        return ownKey(normalized) ?? normalized
    }

    private func ownKey(_ normalizedHost: String) -> String? {
        sites.keys.filter { PaddleConfig.normalizedHost($0) == normalizedHost }.min()
    }
}

extension SiteSettings {
    /// The field names as config.json writes them.
    public enum Field: String, Sendable, CaseIterable {
        case zoom, javaScript, autoplay, contentBlocking, location, notifications, httpsOnly
    }

    /// A `sites` entry as it is in the file (`existing`, nil when there is none) with one field set to `value`, or
    /// removed when `value` is nil or Paddle's default for it. Other members, unknown ones included, are kept. Nil
    /// when nothing is left, so the entry is removed.
    public static func entry(_ existing: JSONValue?, setting field: Field, to value: JSONValue?) -> JSONValue? {
        var object = existing?.objectValue ?? [:]
        // A zoom equal to 1 is kept: with a `defaultZoom` other than 1 it is a real choice (callers pass nil to remove).
        object[field.rawValue] = value == defaultValue(field) && field != .zoom ? nil : value
        return object.isEmpty ? nil : .object(object)
    }

    /// Paddle's default for `field` as JSON (`SitePolicy.defaults`).
    static func defaultValue(_ field: Field) -> JSONValue {
        let d = SitePolicy.defaults
        switch field {
        case .zoom: return .number(d.zoom)
        case .javaScript: return .bool(d.javaScript)
        case .autoplay: return .string(d.autoplay.rawValue)
        case .contentBlocking: return .bool(d.contentBlocking)
        case .location: return .string(d.location.rawValue)
        case .notifications: return .string(d.notifications.rawValue)
        case .httpsOnly: return .bool(d.httpsOnly)
        }
    }
}

/// Answers to permission prompts for this run of Paddle only (camera, microphone, location, notifications, downloads
/// from another site's frame), keyed by site: an origin (`https://example.com:443`) for capture, location and
/// notifications, a host for downloads. Never written to disk. Settings lists them under "This session" with a Forget
/// button.
public struct SessionPermissions: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Comparable {
        case camera, microphone, location, notifications, downloads

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public struct Answer: Sendable, Hashable {
        public var site: String
        public var kind: Kind
        public var allowed: Bool

        public init(site: String, kind: Kind, allowed: Bool) {
            self.site = site
            self.kind = kind
            self.allowed = allowed
        }

        /// The site's host: the origin's host, or the site itself when it is already a host.
        public var host: String { URL(string: site)?.host() ?? site }
    }

    private struct Key: Hashable {
        var site: String
        var kind: Kind
    }

    private var answers: [Key: Bool] = [:]

    public init() {}

    /// The answer given for `kind` on `site` this session, if any.
    public func answer(site: String, kind: Kind) -> Bool? {
        answers[Key(site: site, kind: kind)]
    }

    /// True when every one of `kinds` was allowed for `site`.
    public func allows(site: String, kinds: [Kind]) -> Bool {
        !kinds.isEmpty && kinds.allSatisfy { answer(site: site, kind: $0) == true }
    }

    public mutating func record(_ allowed: Bool, site: String, kinds: [Kind]) {
        for kind in kinds { answers[Key(site: site, kind: kind)] = allowed }
    }

    /// Every answer, by host, then site, then kind.
    public var all: [Answer] {
        answers.map { Answer(site: $0.key.site, kind: $0.key.kind, allowed: $0.value) }
            .sorted { ($0.host, $0.site, $0.kind) < ($1.host, $1.site, $1.kind) }
    }

    /// The answers whose site is on `host` (any scheme or port).
    public func answers(forHost host: String) -> [Answer] {
        let host = PaddleConfig.normalizedHost(host)
        return all.filter { PaddleConfig.normalizedHost($0.host) == host }
    }

    public mutating func forget(_ answer: Answer) {
        answers[Key(site: answer.site, kind: answer.kind)] = nil
    }

    /// Forgets every answer for `host`, so its next request asks again.
    public mutating func forget(host: String) {
        for answer in answers(forHost: host) { forget(answer) }
    }

    public var isEmpty: Bool { answers.isEmpty }
}
