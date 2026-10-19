import Foundation

/// A typed address that opens Settings instead of a page: `paddle://settings`, `paddle://settings/<pane>`, and the
/// addresses other browsers use (about:settings, about:preferences, chrome://settings, chrome://extensions, about:addons).
public struct SettingsLink: Sendable, Equatable {
    public enum Pane: String, Sendable, CaseIterable { case general, appearance, profiles, tabsMemory, mosaic, privacy, sites, extensions, shortcuts, advanced }
    /// nil: Settings opens on the pane it showed last.
    public var pane: Pane?

    public init(pane: Pane?) {
        self.pane = pane
    }

    /// The settings address `input` names, or nil for anything else. Only typed input may be parsed this way: a
    /// page or an extension must never reach Settings through it.
    public static func parse(_ input: String) -> SettingsLink? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only about:preferences reads its fragment (#privacy); a query or fragment is otherwise ignored.
        var fragment = ""
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[text.index(after: hash)...])
            text = String(text[..<hash])
        }
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        while text.hasSuffix("/") { text.removeLast() }

        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = String(text[..<colon])
        var target = text[text.index(after: colon)...]
        // The slashes are what make a bare pane name (paddle://tabs) a link; paddle:settings needs none.
        let slashed = target.hasPrefix("//")
        if slashed { target = target.dropFirst(2) }
        let parts = target.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts.first ?? "")
        let path = parts.count > 1 ? String(parts[1]) : ""

        switch (scheme, host) {
        case ("paddle", "settings"):
            return SettingsLink(pane: panesByName[path])
        case ("paddle", _) where slashed && path.isEmpty:
            return panesByName[host].map { SettingsLink(pane: $0) }
        case ("about", "settings"), ("chrome", "settings"):
            return SettingsLink(pane: settingsPagePanes[path])
        case ("about", "preferences"):
            // Chrome's search settings are part of General here.
            return SettingsLink(pane: fragment == "search" ? .general : panesByName[fragment])
        case ("about", "addons"), ("chrome", "extensions"):
            // Extension pages open Extensions whatever path follows.
            return SettingsLink(pane: .extensions)
        default:
            return nil
        }
    }

    /// Pane names and their aliases, as `paddle://` addresses and about:preferences fragments spell them.
    private static let panesByName: [String: Pane] = [
        "general": .general,
        "appearance": .appearance, "theme": .appearance, "accessibility": .appearance,
        "profiles": .profiles, "profile": .profiles, "containers": .profiles,
        "tabsmemory": .tabsMemory, "tabs": .tabsMemory, "memory": .tabsMemory,
        "mosaic": .mosaic, "multiview": .mosaic, "splitview": .mosaic,
        "privacy": .privacy, "blocking": .privacy, "contentblocking": .privacy, "adblock": .privacy,
        "sites": .sites, "site": .sites,
        "extensions": .extensions, "addons": .extensions,
        "shortcuts": .shortcuts, "keyboard": .shortcuts, "keys": .shortcuts,
        "advanced": .advanced,
    ]

    /// The only panes the other browsers' settings pages name by path: chrome://settings/privacy and /search.
    /// Any other path opens Settings at the last pane.
    private static let settingsPagePanes: [String: Pane] = ["privacy": .privacy, "search": .general]
}
