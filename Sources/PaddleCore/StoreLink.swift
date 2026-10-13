import Foundation

/// An extension's page in a store, from a link the user pasted or a page they're on.
///
/// - Chrome Web Store: `https://chromewebstore.google.com/detail/<slug>/<id>` (slug optional), the old
///   `https://chrome.google.com/webstore/detail/<slug>/<id>`, or a bare 32-letter a–p id. The id is lowercased.
/// - addons.mozilla.org: `https://addons.mozilla.org/<locale>/firefox/addon/<slug>/` (locale optional). Android
///   listings are refused.
///
/// Links must be https on the store's own host with no port or user; query and fragment are ignored.
public enum StoreLink: Sendable, Equatable, Hashable {
    case chromeWebStore(id: String)
    case mozillaAddons(slug: String)

    /// The install source this link records.
    public var source: Persona.Source {
        switch self {
        case .chromeWebStore: .chromeWebStore
        case .mozillaAddons: .mozillaAddons
        }
    }

    /// The Chrome id or AMO slug.
    public var storeID: String {
        switch self {
        case .chromeWebStore(let id): id
        case .mozillaAddons(let slug): slug
        }
    }

    /// A pasted link or bare id; nil when it's neither.
    public static func parse(_ text: String) -> StoreLink? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = chromeID(text) { return .chromeWebStore(id: id) }
        guard let url = URL(string: text) else { return nil }
        return parse(url)
    }

    /// A store detail page URL; nil for anything else.
    public static func parse(_ url: URL) -> StoreLink? {
        guard url.scheme?.lowercased() == "https", url.port == nil, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "chromewebstore.google.com":
            return chromeDetail(parts, prefix: ["detail"])
        case "chrome.google.com":
            return chromeDetail(parts, prefix: ["webstore", "detail"])
        case "addons.mozilla.org":
            var rest = parts[...]
            if let first = rest.first, first != "firefox", first != "android" {
                guard isLocale(first) else { return nil }
                rest = rest.dropFirst()
            }
            guard rest.count == 3, rest[rest.startIndex] == "firefox", rest[rest.startIndex + 1] == "addon" else { return nil }
            let slug = rest[rest.startIndex + 2]
            return isSlug(slug) ? .mozillaAddons(slug: slug) : nil
        default:
            return nil
        }
    }

    /// The link for a page the user is on, for the "Install in Paddle" bar. Same rules as `parse(_:)`.
    public static func isStoreDetailPage(_ url: URL) -> StoreLink? {
        parse(url)
    }

    /// Where Chrome downloads a store extension: Google's update service, answering with a redirect to the CRX3.
    /// Nil when `id` isn't a Chrome id or the version isn't dotted numbers.
    public static func chromeDownloadURL(id: String, versions: BrowserVersions = .current) -> URL? {
        guard let id = chromeID(id) else { return nil }
        let version = versions.chromeFullVersion
        guard !version.isEmpty, version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(version)&acceptformat=crx3&x=id%3D\(id)%26uc")
    }

    /// Whether the download may follow a redirect to `url`: https on the default port, no user, and a host that is
    /// or ends in `.google.com`, `.googleusercontent.com` or `.gvt1.com`.
    public static func isAllowedChromeDownloadRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return ["google.com", "googleusercontent.com", "gvt1.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Pieces

    /// `text` lowercased when it's 32 letters a–p.
    static func chromeID(_ text: String) -> String? {
        let id = text.lowercased()
        return ExtensionIdentity.isChromeID(id) ? id : nil
    }

    /// `<prefix>/<id>` or `<prefix>/<slug>/<id>`.
    private static func chromeDetail(_ parts: [String], prefix: [String]) -> StoreLink? {
        guard parts.starts(with: prefix) else { return nil }
        let rest = parts.dropFirst(prefix.count)
        guard rest.count == 1 || rest.count == 2, let last = rest.last, let id = chromeID(last) else { return nil }
        if rest.count == 2, rest.first?.isEmpty != false { return nil }
        return .chromeWebStore(id: id)
    }

    /// `en-US`, `de`, `zh-CN`, `es-ES` ...
    private static func isLocale(_ part: String) -> Bool {
        (2...10).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }
            && part.first?.isLetter == true
    }

    /// An AMO slug, numeric id or add-on guid (`name@example.com`, `{uuid}`).
    private static func isSlug(_ part: String) -> Bool {
        guard (1...200).contains(part.count), part != ".", part != ".." else { return false }
        return part.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-_.@{}".unicodeScalars.contains(scalar)
        }
    }
}
