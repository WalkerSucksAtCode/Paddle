import Foundation

/// Which extensions only work on certain sites, so they can run only while one of those sites is open
/// (`extensionsOnDemand`). An extension qualifies when it has content scripts, every site its content scripts and
/// required permissions name is a specific site (not every site), and nothing it asks for works away from those
/// sites: no request blocking or interception, navigation watching, menu items, alarms, notifications, New Tab or
/// address-bar takeovers. Optional permissions don't count: they are only granted when it asks later.
public enum OnDemandExtension {
    /// Permissions that do work beyond the extension's own sites, or in the background while none is open.
    static let alwaysRunning: Set<String> = [
        "webRequest", "webRequestBlocking", "webRequestAuthProvider", "declarativeNetRequest",
        "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback", "proxy", "webNavigation",
        "contextMenus", "menus", "alarms", "notifications", "downloads", "nativeMessaging", "idle", "tabGroups",
    ]
    /// Manifest keys that put the extension somewhere other than its sites' pages.
    static let alwaysRunningKeys = ["chrome_url_overrides", "omnibox", "devtools_page", "sidebar_action", "side_panel"]

    /// The match patterns of the sites `manifest` works on, or nil when it doesn't qualify.
    public static func sitePatterns(manifest: [String: Any]) -> [String]? {
        if alwaysRunningKeys.contains(where: { manifest[$0] != nil }) { return nil }
        let contentScripts = (manifest["content_scripts"] as? [[String: Any]]) ?? []
        let scriptPatterns = contentScripts.flatMap { ($0["matches"] as? [String]) ?? [] }
        guard !scriptPatterns.isEmpty else { return nil }
        let requested = ((manifest["permissions"] as? [String]) ?? []) + ((manifest["host_permissions"] as? [String]) ?? [])
        // Manifest V2 lists host patterns among its permissions; anything else there is a permission name.
        let hostPatterns = requested.filter(isPattern)
        let permissions = Set(requested.filter { !isPattern($0) })
        guard permissions.isDisjoint(with: alwaysRunning) else { return nil }
        let patterns = scriptPatterns + hostPatterns
        guard patterns.allSatisfy(namesSpecificSite) else { return nil }
        var seen: Set<String> = []
        return patterns.filter { seen.insert($0).inserted }
    }

    static func isPattern(_ value: String) -> Bool {
        value == "<all_urls>" || value.contains("://")
    }

    /// `pattern` names a site (`*://*.youtube.com/*`), not every site (`<all_urls>`, `*://*/*`) or a scheme like `file`.
    static func namesSpecificSite(_ pattern: String) -> Bool {
        guard pattern != "<all_urls>", let schemeEnd = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<schemeEnd.lowerBound]
        guard ["http", "https", "*"].contains(scheme) else { return false }
        let rest = pattern[schemeEnd.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let bare = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return !bare.isEmpty && !bare.contains("*") && bare.contains(".")
    }
}
