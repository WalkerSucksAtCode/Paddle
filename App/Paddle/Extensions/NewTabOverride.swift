import AppKit
import PaddleCore
import WebKit

/// Extensions that bring their own New Tab page (`chrome_url_overrides.newtab`). `newTabExtension` in config.json
/// names the folder New Tab opens; the first New Tab while such an extension runs (and none is chosen) asks once
/// whether to use it. A choice that isn't running in the window's profile (off, removed, or not allowed in private
/// windows) leaves Paddle's own New Tab.
extension AppModel {
    /// UserDefaults: "<profile>/<folder>" of every extension already asked about, so each is asked once.
    private static let askedKey = "newTabOverrideAsked"

    /// The loaded extensions of `browser`'s profile that have a New Tab page it may show (private windows: only
    /// extensions allowed there).
    func newTabPageExtensions(for browser: BrowserModel) -> [LoadedExtension] {
        guard let host = existingExtensions(for: browser.profileID) else { return [] }
        return host.loaded.filter { ext in
            ext.webExtension.hasOverrideNewTabPage && ext.context.overrideNewTabPageURL != nil
                && (!browser.isPrivate || ext.allowedInPrivate)
        }
    }

    /// The page a New Tab in `browser` opens instead of Paddle's own, asking first about an extension not yet asked
    /// about; nil for Paddle's own New Tab.
    func newTabOverrideURL(for browser: BrowserModel) -> URL? {
        let candidates = newTabPageExtensions(for: browser)
        let chosen = browser.config.newTabExtension
        if !chosen.isEmpty {
            return candidates.first { $0.name == chosen }?.context.overrideNewTabPageURL
        }
        var asked = Set(UserDefaults.standard.stringArray(forKey: Self.askedKey) ?? [])
        guard let ext = candidates.first(where: { !asked.contains("\(browser.profileID)/\($0.name)") }) else { return nil }
        asked.insert("\(browser.profileID)/\(ext.name)")
        UserDefaults.standard.set(asked.sorted(), forKey: Self.askedKey)
        guard ExtensionPrompts.newTabPage(name: ext.displayName, icon: ext.icon(side: 64)) else { return nil }
        Task { await writeConfigKey(.newTabExtension, .string(ext.name)) }
        return ext.context.overrideNewTabPageURL
    }

    /// `url` is a running extension's New Tab page (any profile), so the address field shows it empty.
    func isNewTabOverridePage(_ url: URL) -> Bool {
        guard ExtensionIdentity.identifier(of: url) != nil else { return false }
        return extensionHosts.contains { host in
            host.loaded.contains { $0.webExtension.hasOverrideNewTabPage && $0.context.overrideNewTabPageURL == url }
        }
    }

    /// One key written from outside Settings (an alert's answer, a menu), based on config.json as it is on disk now.
    @discardableResult
    func writeConfigKey(_ key: PaddleConfig.CodingKeys, _ value: JSONValue?) async -> ConfigWriteResult {
        let base: Data
        do {
            base = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
        } catch {
            return .failed(error.localizedDescription)
        }
        return await writeConfig([ConfigChange(key.rawValue, value)], base: base)
    }
}
