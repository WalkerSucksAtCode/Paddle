import Foundation

/// Which extension files a web page is allowed to load. Firefox and Chrome expose only
/// `web_accessible_resources`; everything else (the background, the content scripts) stays inside the extension.
public enum ExtensionWebAccess {
    /// `path` is relative to the extension root (`resources/a.js`). True when the manifest exposes it to `pageURL`.
    /// MV2 patterns are exposed to every page. An MV3 entry also has to `matches` the page; `pageURL` nil never matches one.
    public static func isReachable(path: String, manifest: [String: Any], pageURL: URL?) -> Bool {
        guard let path = relativePath(path) else { return false }
        guard let resources = manifest["web_accessible_resources"] else { return false }
        if let patterns = resources as? [String] {
            return patterns.contains { glob($0, path) }
        }
        guard let entries = resources as? [[String: Any]] else { return false }
        for entry in entries {
            let patterns = entry["resources"] as? [String] ?? []
            guard patterns.contains(where: { glob($0, path) }) else { continue }
            let matches = entry["matches"] as? [String] ?? []
            guard let pageURL, !matches.isEmpty else { continue }
            let page = pageURL.absoluteString
            if matches.contains(where: { urlMatches($0, page) }) { return true }
        }
        return false
    }

    /// `url`'s path when it is an extension-scheme `.js` file that stays inside an extension root. Nil otherwise.
    public static func scriptPath(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ExtensionIdentity.schemes.contains(scheme),
              let path = relativePath(url.path), path.lowercased().hasSuffix(".js") else { return nil }
        return path
    }

    /// A manifest or URL path that stays inside the extension root: no empty result, no `.` or `..` segment.
    static func relativePath(_ path: String) -> String? {
        var path = path
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        if let decoded = path.removingPercentEncoding { path = decoded }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }

    /// `*` matches any string, including `/`, the same way Chrome's web-accessible path patterns do.
    private static func glob(_ pattern: String, _ path: String) -> Bool {
        guard let pattern = relativePath(pattern) else { return false }
        let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*") + "$"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        return expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static func urlMatches(_ pattern: String, _ url: String) -> Bool {
        guard let regex = UserScript.regex(forMatchPattern: pattern),
              let expression = try? NSRegularExpression(pattern: regex) else { return false }
        return expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
