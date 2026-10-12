import Foundation

/// The browser an extension is run as. It decides the extension's URL scheme, base URL and id
/// (`ExtensionIdentity.resolve`), which compatibility prelude it gets (`CompatPrelude`) and the user agent its own
/// views send.
///
/// - `chrome`: `chrome-extension://`, Chrome's user agent, no `browser` global.
/// - `firefox`: `moz-extension://`, Firefox's user agent, `browser` and `chrome`.
/// - `native`: a Safari build or an `.appex`: no overlay and no prelude, so it costs nothing.
/// - `none`: the wave 4b overlay with no persona (today's behaviour); the escape hatch.
public enum Persona: String, Codable, Sendable, CaseIterable {
    case chrome, firefox, native, none

    /// Where an extension came from, as recorded at install. `folder` is an unpacked folder dropped into
    /// `extensions/` by hand.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case chromeWebStore, mozillaAddons, appex, folder
    }

    /// The persona for an extension. The first rule that matches wins:
    /// 1. `override` (`config.json` `extensionCompat[folder].persona`);
    /// 2. the install source: Chrome Web Store → chrome, addons.mozilla.org → firefox, `.appex` → native;
    /// 3. `browser_specific_settings` (or the older `applications`) with only a `safari` key → native;
    /// 4. a gecko id, and a background that isn't service-worker-only → firefox;
    /// 5. otherwise chrome.
    public static func detect(manifest: [String: Any], source: Source?, override: Persona?) -> Persona {
        if let override { return override }
        switch source {
        case .chromeWebStore: return .chrome
        case .mozillaAddons: return .firefox
        case .appex: return .native
        case .folder, nil: break
        }
        for key in ["browser_specific_settings", "applications"] {
            if let settings = manifest[key] as? [String: Any], settings.keys.sorted() == ["safari"] { return .native }
        }
        if geckoID(manifest: manifest) != nil, !isServiceWorkerOnly(manifest: manifest) { return .firefox }
        return .chrome
    }

    /// `browser_specific_settings.gecko.id`, else `applications.gecko.id`.
    public static func geckoID(manifest: [String: Any]) -> String? {
        for key in ["browser_specific_settings", "applications"] {
            if let id = ((manifest[key] as? [String: Any])?["gecko"] as? [String: Any])?["id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    /// A background with a `service_worker` and neither `scripts` nor `page` (Firefox can't run it).
    static func isServiceWorkerOnly(manifest: [String: Any]) -> Bool {
        guard let background = manifest["background"] as? [String: Any], background["service_worker"] is String else { return false }
        let scripts = (background["scripts"] as? [Any]) ?? []
        return scripts.isEmpty && background["page"] == nil
    }

    /// The persona gets an overlay with the v2 prelude (chrome, firefox).
    public var runsPersonaPrelude: Bool { self == .chrome || self == .firefox }

    /// The exact user agent this persona sends and reports; nil for `native` and `none` (WebKit's own).
    public func userAgent(_ versions: BrowserVersions = .current) -> String? {
        switch self {
        case .chrome:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(versions.chromeMajor).0.0.0 Safari/537.36"
        case .firefox:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(versions.firefoxVersion)) Gecko/20100101 Firefox/\(versions.firefoxVersion)"
        case .native, .none:
            nil
        }
    }

    /// `navigator.vendor`: "Google Inc." for Chrome, "" for Firefox; nil (WebKit's own) otherwise.
    public var vendor: String? {
        switch self {
        case .chrome: "Google Inc."
        case .firefox: ""
        case .native, .none: nil
        }
    }

    /// One `navigator.userAgentData.brands` entry.
    public struct Brand: Codable, Sendable, Equatable {
        public var brand: String
        public var version: String

        public init(brand: String, version: String) {
            self.brand = brand
            self.version = version
        }
    }

    /// Chrome's `userAgentData.brands` (`full: false`) or `fullVersionList` (`full: true`): Google Chrome, Chromium
    /// and a GREASE brand, in Chromium's order for that major version (`GenerateBrandVersionList`, seeded with the
    /// major version, as in `components/embedder_support/user_agent_utils.cc`). Empty for other personas.
    public func brands(_ versions: BrowserVersions = .current, full: Bool = false) -> [Brand] {
        guard self == .chrome else { return [] }
        let seed = versions.chromeMajor
        let greaseChars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"]
        let greaseVersions = ["8", "99", "24"]
        let greaseBrand = "Not" + greaseChars[seed % greaseChars.count] + "A" + greaseChars[(seed + 1) % greaseChars.count] + "Brand"
        let greaseVersion = greaseVersions[seed % greaseVersions.count]
        let version = full ? versions.chromeFullVersion : String(versions.chromeMajor)
        let list = [
            Brand(brand: greaseBrand, version: full ? "\(greaseVersion).0.0.0" : greaseVersion),
            Brand(brand: "Chromium", version: version),
            Brand(brand: "Google Chrome", version: version),
        ]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let order = orders[seed % orders.count]
        var shuffled = list
        for (index, brand) in list.enumerated() { shuffled[order[index]] = brand }
        return shuffled
    }
}

/// The Chrome and Firefox versions the personas claim. One source of truth for the persona user agents, the
/// Settings > Sites presets (`UserAgentPreset`) and the Chrome Web Store `prodversion`.
public struct BrowserVersions: Codable, Sendable, Equatable {
    /// Chrome's major version, as in the reduced user agent (`Chrome/156.0.0.0`).
    public var chromeMajor: Int
    /// Chrome's full version, for `userAgentData.getHighEntropyValues` and `prodversion`.
    public var chromeFullVersion: String
    /// Firefox's version as its user agent writes it (`157.0`).
    public var firefoxVersion: String

    public init(chromeMajor: Int, chromeFullVersion: String, firefoxVersion: String) {
        self.chromeMajor = chromeMajor
        self.chromeFullVersion = chromeFullVersion
        self.firefoxVersion = firefoxVersion
    }

    /// Stable on macOS on 2026-10-12: Chrome 156.0.8078.12 (versionhistory.googleapis.com, mac stable) and
    /// Firefox 157.0.1 (product-details.mozilla.org `LATEST_FIREFOX_VERSION`). Bump by hand.
    public static let current = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0.8078.12", firefoxVersion: "157.0")

    /// These versions, raised to the manifest's `minimum_chrome_version` and `browser_specific_settings.gecko`
    /// (or `applications.gecko`) `strict_min_version` where those are higher, so an extension that checks its
    /// minimum doesn't refuse to run. Never lowered.
    public func raised(for manifest: [String: Any]) -> BrowserVersions {
        var result = self
        if let minimum = manifest["minimum_chrome_version"] as? String {
            let parts = Self.numbers(minimum)
            if let major = parts.first, major > chromeMajor {
                result.chromeMajor = major
                result.chromeFullVersion = parts.count == 4 ? parts.map(String.init).joined(separator: ".") : "\(major).0.0.0"
            }
        }
        for key in ["browser_specific_settings", "applications"] {
            guard let minimum = ((manifest[key] as? [String: Any])?["gecko"] as? [String: Any])?["strict_min_version"] as? String,
                  let major = Self.numbers(minimum).first,
                  let current = Self.numbers(result.firefoxVersion).first, major > current else { continue }
            result.firefoxVersion = "\(major).0"
        }
        return result
    }

    /// The leading dotted numbers of a version string: "128.0a1" → [128, 0], "*" → [].
    static func numbers(_ version: String) -> [Int] {
        var result: [Int] = []
        for part in version.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard let number = Int(digits) else { break }
            result.append(number)
            if digits.count != part.count { break }
        }
        return result
    }
}

/// Per-folder compatibility settings, from `config.json` `extensionCompat`:
/// `{"protonpass": {"persona": "firefox", "shims": true, "publicID": false}}`. Every field is optional.
public struct ExtensionCompatConfig: Codable, Sendable, Equatable {
    /// Forces the persona; nil lets `Persona.detect` choose.
    public var persona: Persona?
    /// The prelude's API stand-ins (enums, `permissions` filtering, inert events, ...). Off leaves only the persona
    /// itself. Default on.
    public var shims: Bool?
    /// A Chrome-persona extension uses its public id (the Web Store id, or a sideloaded manifest `key`) instead of
    /// the private one. Default off; store installs that need it for sign-in or website messaging get it anyway.
    public var publicID: Bool?

    public init(persona: Persona? = nil, shims: Bool? = nil, publicID: Bool? = nil) {
        self.persona = persona
        self.shims = shims
        self.publicID = publicID
    }

    public var shimsEnabled: Bool { shims ?? true }
    public var wantsPublicID: Bool { publicID ?? false }
    public var isEmpty: Bool { persona == nil && shims == nil && publicID == nil }
}
