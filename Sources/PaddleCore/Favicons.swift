import CryptoKit
import Foundation

/// One `<link rel=icon ...>` read from the page by `FaviconPicker.collectScript`.
public struct IconCandidate: Sendable, Equatable, Codable {
    public var href: String
    public var rel: String
    public var sizes: String
    public var type: String

    public init(href: String, rel: String, sizes: String = "", type: String = "") {
        self.href = href
        self.rel = rel
        self.sizes = sizes
        self.type = type
    }
}

/// Favicon selection and cache rules: which declared icon to fetch, where to cache it, when to refetch.
public enum FaviconPicker {
    /// Smallest edge, in pixels, that still looks sharp at 16 pt on a 2x screen.
    static let targetPixels = 32
    /// Data URLs longer than this are skipped rather than carried around.
    static let maxDataURLLength = 100_000
    /// Icons are refetched after this long.
    static let maxAge: TimeInterval = 7 * 86_400

    /// Best icon URL for showing at 16 pt on a 2x screen (32 px). Order: a declared square size of at least 32
    /// on an icon or shortcut icon link (the smallest such size wins, so 32 or 48 beat 192); then a `rel` of icon
    /// or shortcut icon without sizes; then the largest apple-touch-icon; then the first usable candidate. SVG
    /// icons are skipped (WebKit's image loader, which Paddle fetches icons with, decodes bitmaps only). Relative
    /// hrefs resolve against `pageURL` (a `<base>` element is the caller's problem). Only http(s) and `data:image/`
    /// hrefs are usable. With no usable candidate, falls back to `/favicon.ico` on the page's host (nil without an
    /// http(s) host).
    public static func bestIcon(_ candidates: [IconCandidate], pageURL: URL) -> URL? {
        let usable: [(candidate: IconCandidate, url: URL, sizes: [Int])] = candidates.compactMap { candidate in
            guard let url = resolve(candidate.href, against: pageURL), withoutFragment(url) != withoutFragment(pageURL),
                  !isSVG(candidate, url: url) else { return nil }
            return (candidate, url, parseSizes(candidate.sizes))
        }

        // Smallest declared size that is still sharp enough (plain icon links only); ties keep page order.
        var bestSized: (url: URL, size: Int)?
        for item in usable where relTokens(item.candidate.rel).contains("icon") {
            guard let size = item.sizes.filter({ $0 >= targetPixels }).min() else { continue }
            if let current = bestSized, current.size <= size { continue }
            bestSized = (item.url, size)
        }
        if let bestSized { return bestSized.url }

        if let plain = usable.first(where: { $0.sizes.isEmpty && relTokens($0.candidate.rel).contains("icon") }) {
            return plain.url
        }

        var largestTouch: (url: URL, size: Int)?
        for item in usable where relTokens(item.candidate.rel).contains("apple-touch-icon") {
            let size = item.sizes.max() ?? 0
            if let current = largestTouch, current.size >= size { continue }
            largestTouch = (item.url, size)
        }
        if let largestTouch { return largestTouch.url }

        if let first = usable.first { return first.url }
        return fallbackIcon(for: pageURL)
    }

    /// Cache key per site: lowercased host without a leading "www.", plus ":port" when the URL names one
    /// explicitly (so `localhost:3000` and `localhost:8080` differ); nil without a host.
    public static func cacheKey(for pageURL: URL) -> String? {
        guard var host = pageURL.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        if let port = pageURL.port { host += ":\(port)" }
        return host
    }

    /// File name for a cache key: first 16 hex characters of its SHA-256, plus ".png".
    public static func fileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16)) + ".png"
    }

    /// Icons are refetched after 7 days.
    public static func isStale(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge
    }

    /// JavaScript the app runs in the page (in an isolated content world) to list icon links. Returns a JSON
    /// array of `{href, rel, sizes, type}` for link elements whose rel contains "icon", except mask-icon, and
    /// that have a non-empty href attribute (an empty one would resolve to the page itself). The returned
    /// href is already absolute (`link.href`).
    public static let collectScript = """
    JSON.stringify(Array.from(document.querySelectorAll('link[rel]')).filter(function (link) {
        var rel = (link.getAttribute('rel') || '').toLowerCase();
        return rel.indexOf('icon') !== -1 && rel.indexOf('mask-icon') === -1 && (link.getAttribute('href') || '').trim();
    }).map(function (link) {
        return {
            href: link.href,
            rel: link.getAttribute('rel') || '',
            sizes: link.getAttribute('sizes') || '',
            type: link.getAttribute('type') || ''
        };
    }))
    """

    // MARK: - Helpers

    /// Square edge lengths from a `sizes` attribute such as "16x16 32x32"; "any" and malformed tokens are ignored,
    /// and a non-square size counts as its smaller side.
    static func parseSizes(_ sizes: String) -> [Int] {
        sizes.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let parts = token.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
            return min(width, height)
        }
    }

    private static func relTokens(_ rel: String) -> [String] {
        rel.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func isSVG(_ candidate: IconCandidate, url: URL) -> Bool {
        if candidate.type.lowercased().hasPrefix("image/svg+xml") { return true }
        if url.scheme == "data" { return url.absoluteString.lowercased().hasPrefix("data:image/svg+xml") }
        return url.path.lowercased().hasSuffix(".svg")
    }

    private static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("data:") {
            guard trimmed.lowercased().hasPrefix("data:image/"), trimmed.count <= maxDataURLLength else { return nil }
            return URL(string: trimmed)
        }
        guard let url = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    private static func fallbackIcon(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = pageURL.host(percentEncoded: true), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = pageURL.port
        components.path = "/favicon.ico"
        return components.url
    }
}
