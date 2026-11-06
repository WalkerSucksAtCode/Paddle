import CryptoKit
import Foundation

/// Stable per-install extension ids. `runtime.id` is this id; the page host is the same, except Firefox
/// (`moz-extension://<uuid>/`). A per-install salt keeps sites from guessing either from a folder name.
public enum ExtensionIdentity {
    /// WebKit's own scheme (personas `none` and `native`).
    public static let scheme = "webkit-extension"
    public static let chromeScheme = "chrome-extension"
    public static let firefoxScheme = "moz-extension"
    public static let safariScheme = "safari-web-extension"
    /// Every scheme an extension page can have, lowercase.
    public static let schemes: Set<String> = [scheme, chromeScheme, firefoxScheme, safariScheme]

    /// 32 random lowercase hex characters, stored once (in `extension-id-salt`).
    public static func makeSalt() -> String {
        hex(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }

    /// What to do with `extension-id-salt` at launch, given whether the file exists and its bytes (nil when it
    /// exists but couldn't be read).
    public enum SaltFile: Equatable, Sendable {
        /// The stored salt, lowercased.
        case use(String)
        /// No usable salt: make one and write it (no file yet, or its contents aren't a salt).
        case make
        /// The file is there but couldn't be read: keep it, and load no extension, since a new salt would give every
        /// extension a new id and leave its storage behind.
        case refuse
    }

    public static func saltFile(exists: Bool, data: Data?) -> SaltFile {
        guard exists else { return .make }
        guard let data else { return .refuse }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 32, trimmed.allSatisfy(\.isHexDigit) else { return .make }
        return .use(trimmed.lowercased())
    }

    /// 32 lowercase hex characters: the first 16 bytes of SHA256(`salt` + ":" + `name`).
    public static func identifier(forFolder name: String, salt: String) -> String {
        hex(Array(SHA256.hash(data: Data("\(salt):\(name)".utf8)).prefix(16)))
    }

    /// `webkit-extension://<identifier>/`
    public static func baseURL(for identifier: String) -> URL {
        baseURL(scheme: scheme, host: identifier)
    }

    /// `<scheme>://<host>/`
    public static func baseURL(scheme: String, host: String) -> URL {
        URL(string: "\(scheme)://\(host)/") ?? URL(fileURLWithPath: "/")
    }

    /// The host of an extension page's URL (any of `schemes`); nil for any other URL or nil. For the Firefox
    /// persona this is the UUID host, not `runtime.id`.
    public static func identifier(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Whether an extension (or one of its pages) may put `url` in a tab: web pages, about:blank and its own pages.
    /// Not file:, another extension's pages or other schemes; Paddle starts those loads itself, past WebKit's
    /// checks on the extension's origin. `baseURL` is the extension context's base URL: its own pages are the ones
    /// with the same scheme and host.
    public static func extensionMayOpen(_ url: URL, baseURL: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return true
        case "about": return url.absoluteString.lowercased() == "about:blank"
        default:
            guard schemes.contains(scheme), let baseURL, let host = identifier(of: url) else { return false }
            return baseURL.scheme?.lowercased() == scheme && baseURL.host?.lowercased() == host.lowercased()
        }
    }

    /// The `webkit-extension` form of `extensionMayOpen(_:baseURL:)`, for a context whose host is its id.
    public static func extensionMayOpen(_ url: URL, extensionID: String?) -> Bool {
        extensionMayOpen(url, baseURL: extensionID.map { baseURL(for: $0) })
    }

    // MARK: - Chrome ids

    /// Chrome's id alphabet: each hex digit 0–f becomes a letter a–p. Nil when `hex` has a non-hex character.
    public static func chromeID(hex: String) -> String? {
        var letters = ""
        for character in hex.lowercased() {
            guard let value = character.hexDigitValue else { return nil }
            letters.append(Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(value))))
        }
        return letters
    }

    /// Chrome's id for a public key (the DER `SubjectPublicKeyInfo`, as base64 in a manifest `key` or a CRX
    /// proof): the first 16 bytes of its SHA-256, in the a–p alphabet (`crx_file::id_util::GenerateId`).
    public static func chromeID(publicKeyDER: Data) -> String {
        chromeID(hex: hex(Array(SHA256.hash(data: publicKeyDER).prefix(16)))) ?? ""
    }

    /// The id a manifest `key` (base64 DER, whitespace allowed) stands for; nil when it isn't base64.
    public static func chromeID(manifestKey: String) -> String? {
        let cleaned = manifestKey.filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: cleaned), !der.isEmpty else { return nil }
        return chromeID(publicKeyDER: der)
    }

    /// `id` (from `extension-sources.json`) when the manifest doesn't contradict it, else nil: a Web Store id must be
    /// the id of the manifest `key` when there is one, and an add-on guid must be the manifest's gecko id when there is
    /// one. Slugs and manifests that name nothing can't be compared and pass.
    public static func verifiedStoreID(_ id: String?, store: Persona.Source?, manifest: [String: Any]) -> String? {
        guard let id, let store else { return nil }
        switch store {
        case .chromeWebStore:
            if let key = manifest["key"] as? String, let keyID = chromeID(manifestKey: key), keyID != id.lowercased() { return nil }
        case .mozillaAddons:
            let isGUID = id.contains("@") || id.hasPrefix("{")
            if isGUID, let gecko = geckoID(manifest: manifest), gecko.lowercased() != id.lowercased() { return nil }
        case .appex, .folder:
            break
        }
        return id
    }

    /// `browser_specific_settings.gecko.id` (or the older `applications.gecko.id`).
    public static func geckoID(manifest: [String: Any]) -> String? {
        for key in ["browser_specific_settings", "applications"] {
            if let settings = manifest[key] as? [String: Any], let gecko = settings["gecko"] as? [String: Any],
               let id = gecko["id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Who an extension is, for the permissions file: its gecko id, else the id of its manifest `key`, else its
    /// verified store id (`verifiedStoreID`), else a hash of the manifest's own content. That last fallback is for
    /// hand-dropped folders that declare nothing: without it their records keep `identity: nil` forever and any
    /// same-named folder inherits their grants; with it, a different manifest is a different extension. nil only
    /// when even the manifest can't be hashed (it wasn't JSON to begin with).
    public static func permissionIdentity(manifest: [String: Any], verifiedStoreID: String?) -> String? {
        if let gecko = geckoID(manifest: manifest) { return "gecko:" + gecko.lowercased() }
        if let key = manifest["key"] as? String, let id = chromeID(manifestKey: key) { return "chrome:" + id }
        if let verifiedStoreID { return "store:" + verifiedStoreID.lowercased() }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else { return nil }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "content:" + digest
    }

    /// Where an extension folder's storage may have been filed under an earlier id (`priorStorageIDs`), keeping only
    /// ids that are safe to take: the public id comes from the folder's own install record (`ownStoreID`), never from
    /// the folder's manifest, and an id that another folder's install record or a loaded extension holds is refused.
    public static func storageMoveCandidates(
        saltedID: String, ownStoreID: String?, current: String, heldByOthers: Set<String>
    ) -> [String] {
        let publicIDs = [ownStoreID?.lowercased()].compactMap { $0 }
        return priorStorageIDs(saltedID: saltedID, publicIDs: publicIDs, current: current)
            .filter { !heldByOthers.contains($0) }
    }

    /// `https://<id>.chromiumapp.org/<path>`: Chrome's `identity.getRedirectURL`.
    ///
    /// Groundwork for the compat prelude's `identity` API (`launchWebAuthFlow`), not wired to it yet — no production
    /// caller at the moment, kept with its tests like `trustedLists` is.
    public static func chromeRedirectURL(id: String, path: String = "") -> URL? {
        URL(string: "https://\(id).chromiumapp.org/" + path.drop { $0 == "/" })
    }

    // MARK: - Firefox ids

    /// 32 hex characters as a lowercase UUID, 8-4-4-4-12; nil unless `hex` is exactly 32 hex characters.
    public static func mozHost(hex: String) -> String? {
        let hex = hex.lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let characters = Array(hex)
        var parts: [String] = []
        var start = 0
        for length in [8, 4, 4, 4, 12] {
            parts.append(String(characters[start..<(start + length)]))
            start += length
        }
        return parts.joined(separator: "-")
    }

    /// The lowercase hex SHA-1 of an add-on id, as Firefox's `identity` API computes it.
    public static func firefoxRedirectHash(addonID: String) -> String {
        hex(Array(Insecure.SHA1.hash(data: Data(addonID.utf8))))
    }

    /// `https://<sha1 of the add-on id>.extensions.allizom.org/<path>`: Firefox's `identity.getRedirectURL`.
    /// `addonID` is the gecko id (`browser_specific_settings.gecko.id`), so OAuth redirects registered for the
    /// extension in Firefox match.
    public static func firefoxRedirectURL(addonID: String, path: String = "") -> URL? {
        URL(string: "https://\(firefoxRedirectHash(addonID: addonID)).extensions.allizom.org/" + path.drop { $0 == "/" })
    }

    /// `http://127.0.0.1/mozoauth2/<sha1 of the add-on id>`: the loopback form Firefox also accepts as a
    /// `launchWebAuthFlow` redirect (any port).
    public static func firefoxLoopbackRedirect(addonID: String) -> String {
        "http://127.0.0.1/mozoauth2/\(firefoxRedirectHash(addonID: addonID))"
    }

    /// Whether `redirect` is a `redirect_uri` Firefox lets this add-on's `launchWebAuthFlow` finish on: the
    /// `getRedirectURL` host over https, or the loopback form over http on any port.
    public static func firefoxRedirectAllowed(_ redirect: URL, addonID: String) -> Bool {
        let hash = firefoxRedirectHash(addonID: addonID)
        switch redirect.scheme?.lowercased() {
        case "https":
            return redirect.host?.lowercased() == "\(hash).extensions.allizom.org"
        case "http":
            guard redirect.host == "127.0.0.1" else { return false }
            let path = redirect.path
            return path == "/mozoauth2/\(hash)" || path.hasPrefix("/mozoauth2/\(hash)/")
        default:
            return false
        }
    }

    // MARK: - Resolution

    /// What an extension context is given: `runtimeID` goes to `uniqueIdentifier` (set first), `baseURL` to
    /// `baseURL` (after the scheme is registered).
    public struct Resolved: Sendable, Equatable {
        /// `runtime.id`.
        public let runtimeID: String
        public let scheme: String
        /// The URL host of the extension's pages (the UUID for Firefox, else `runtimeID`).
        public let urlHost: String
        /// The public Chrome id (Web Store or manifest `key`) is in use; storage then lives under that id.
        public let isPublic: Bool

        public var baseURL: URL { ExtensionIdentity.baseURL(scheme: scheme, host: urlHost) }
    }

    /// The manifest asks for something that only works under the extension's real Chrome id: `identity` (OAuth
    /// redirects registered for `<id>.chromiumapp.org`), `oauth2`, or `externally_connectable` (websites address
    /// it by id).
    public static func needsPublicID(manifest: [String: Any]) -> Bool {
        if manifest["oauth2"] != nil || manifest["externally_connectable"] != nil { return true }
        for key in ["permissions", "optional_permissions"] {
            if ((manifest[key] as? [Any]) ?? []).contains(where: { $0 as? String == "identity" }) { return true }
        }
        return false
    }

    /// The id and URL for an extension.
    /// - `saltedID`: `identifier(forFolder:salt:)`, the private id every persona starts from (Firefox keeps it as
    ///   `runtime.id`, so storage made under it survives the scheme change).
    /// - `storeID`: the Chrome Web Store id (the CRX `crx_id`) when the extension was installed from the store.
    /// - Chrome uses the public id when it came from the store and needs it (`needsPublicID`) or `publicID` is set;
    ///   a sideloaded manifest `key` counts only with `publicID`, so a dropped-in folder can't claim another
    ///   extension's id. Otherwise the private id in Chrome's a–p alphabet.
    public static func resolve(
        persona: Persona, saltedID: String, manifest: [String: Any], storeID: String? = nil, publicID: Bool = false
    ) -> Resolved {
        switch persona {
        case .chrome:
            if let storeID, isChromeID(storeID), publicID || needsPublicID(manifest: manifest) {
                return Resolved(runtimeID: storeID, scheme: chromeScheme, urlHost: storeID, isPublic: true)
            }
            if storeID == nil, publicID, let key = manifest["key"] as? String, let id = chromeID(manifestKey: key) {
                return Resolved(runtimeID: id, scheme: chromeScheme, urlHost: id, isPublic: true)
            }
            let id = chromeID(hex: saltedID) ?? saltedID
            return Resolved(runtimeID: id, scheme: chromeScheme, urlHost: id, isPublic: false)
        case .firefox:
            return Resolved(runtimeID: saltedID, scheme: firefoxScheme, urlHost: mozHost(hex: saltedID) ?? saltedID, isPublic: false)
        case .native, .none:
            return Resolved(runtimeID: saltedID, scheme: scheme, urlHost: saltedID, isPublic: false)
        }
    }

    /// The URL hosts an extension with private id `saltedID` has had under any persona: the hex itself
    /// (`webkit-extension`), its Chrome a–p form, and its Firefox UUID form. A saved tab on one of these belongs to
    /// that folder whatever its persona is now. Lowercase.
    public static func privateHosts(saltedID: String) -> Set<String> {
        let hex = saltedID.lowercased()
        return Set([hex, chromeID(hex: hex), mozHost(hex: hex)].compactMap { $0 })
    }

    /// The ids an extension folder's storage may be filed under from an earlier run, apart from `current`: its private
    /// hex id (firefox, native, none), that id's a–p Chrome form (chrome persona), and its public id if it had one.
    /// WebKit keys an extension's storage by `uniqueIdentifier`, so when a persona or `publicID` change gives the
    /// folder a new id, its storage is moved from the one of these that exists (`ExtensionHost`), not left behind.
    public static func priorStorageIDs(saltedID: String, publicIDs: [String] = [], current: String) -> [String] {
        let hex = saltedID.lowercased()
        var ids = [hex] + [chromeID(hex: hex)].compactMap { $0 } + publicIDs
        ids.removeAll { $0 == current }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// `url` moved to `base` (scheme and host), path, query and fragment kept; nil when it can't be rebuilt.
    public static func rebased(_ url: URL, onto base: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = base.scheme
        components.host = base.host
        components.port = nil
        return components.url
    }

    /// A name that looks like an extension id or URL host: 32 lowercase hex characters, 32 letters a–p, or a
    /// lowercase UUID. No web domain looks like any of these.
    public static func looksLikeExtensionHost(_ name: String) -> Bool {
        (name.count == 32 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            || isChromeID(name)
            || (name.count == 36 && mozHost(hex: name.replacingOccurrences(of: "-", with: "")) == name)
    }

    /// 32 letters a–p.
    public static func isChromeID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension ExtensionVersion {
    /// True when `new` is lower than `installed` under the store's version rules (Chrome's for the Web Store, the
    /// toolkit's for add-ons). False when either is missing or unreadable, or when they are equal or `new` is higher.
    public static func isDowngrade(from installed: String?, to new: String?, store: Persona.Source) -> Bool {
        guard let installed, let new else { return false }
        let result = store == .mozillaAddons ? compareToolkit(new, installed) : compareChrome(new, installed)
        return result == .orderedAscending
    }
}
