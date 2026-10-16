import Foundation

/// Which runtime access requests from a running extension become an alert.
///
/// WebKit asks for site access on its own, with no tab, when `tabs.query` would see ungranted sites
/// (and when a fetch from an extension page fails CORS). An extension polling tabs would alert on
/// every new site. Those are answered "no" at once unless the user just acted on that extension
/// (toolbar button, popup, menu item, or key command). Named permissions and match patterns always ask.
public enum ExtensionAccessPolicy {
    public enum Kind: Sendable {
        /// Specific URLs: `tabs.query` and CORS failures.
        case urls
        /// Named permissions such as `tabs` or `cookies`.
        case permissions
        /// Host match patterns, from `permissions.request({origins})`.
        case matchPatterns
    }

    public enum Decision: Sendable, Equatable {
        case prompt
        case autoDeny
    }

    /// How long the user's last action on an extension counts as asking for its requests.
    public static let gestureWindow: TimeInterval = 5

    /// `hasTab`: WebKit named the tab the request is for. `recentGesture`: the user acted on this extension
    /// within `gestureWindow`, or its popup is open.
    public static func classify(kind: Kind, hasTab: Bool, recentGesture: Bool) -> Decision {
        switch kind {
        case .permissions, .matchPatterns: .prompt
        case .urls: hasTab || recentGesture ? .prompt : .autoDeny
        }
    }

    /// The site a URL request is remembered under, so one answer covers every page on it: the host, lower-cased,
    /// without a trailing dot or a leading `www.` (kept when nothing with a dot would remain, as in `www.com`).
    /// A URL without a host is its own key.
    public static func denialKey(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return url.absoluteString }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        return host
    }

    /// Match patterns that grant a `denialKey` host: the host and, for a domain name, its `www.` form.
    /// An IPv6 address gets its brackets back.
    public static func grantPatterns(forKey key: String) -> [String] {
        if key.contains(":") { return ["*://[\(key)]/*"] }
        let isAddress = key.allSatisfy { $0.isNumber || $0 == "." }
        return isAddress || !key.contains(".") ? ["*://\(key)/*"] : ["*://\(key)/*", "*://www.\(key)/*"]
    }
}
