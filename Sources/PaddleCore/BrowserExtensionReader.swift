import Foundation

/// An extension another browser has installed, for the "reinstall these" list in the import sheet.
public struct ImportedExtension: Sendable, Equatable, Identifiable {
    /// The Chrome extension id or the Firefox add-on id.
    public var id: String
    /// As the browser stores it; the UI sanitizes it before showing.
    public var name: String
    public var enabled: Bool
    /// Where Paddle can reinstall it from; nil exactly when `notInstallable` is set.
    public var link: StoreLink?
    /// Why there is no `link`, in words for the sheet.
    public var notInstallable: String?

    public init(id: String, name: String, enabled: Bool, link: StoreLink? = nil, notInstallable: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.link = link
        self.notInstallable = notInstallable
    }
}

/// Lists a profile's installed extensions. Reads only the browser's own extension records and, for Chromium
/// names written as `__MSG_key__`, the extension's `messages.json`. Never follows or fetches a URL.
public enum BrowserExtensionReader {
    public static func read(_ source: ImportSource) throws -> [ImportedExtension] {
        let found: [ImportedExtension]
        switch source.browser.family {
        case .safari: return []  // Safari extensions ship inside Mac apps.
        case .chromium: found = try readChromium(source)
        case .firefox: found = try readFirefox(source)
        }
        return found.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func loadJSON(_ url: URL) throws -> [String: Any]? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if ImportSQLite.isPermissionDenied(error) { throw BrowserImportError.accessDenied(.chrome) }
            if (error as? CocoaError)?.code == .fileReadNoSuchFile || (error as? CocoaError)?.code == .fileNoSuchFile { return nil }
            throw BrowserImportError.unreadable("The extension list couldn't be read.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserImportError.unreadable("The extension list isn't in a format Paddle understands.")
        }
        return object
    }

    // MARK: - Chromium

    private static func readChromium(_ source: ImportSource) throws -> [ImportedExtension] {
        var settings: [String: Any]?
        for name in ["Secure Preferences", "Preferences"] {
            let json: [String: Any]?
            do { json = try loadJSON(source.directory.appending(path: name)) } catch BrowserImportError.accessDenied {
                throw BrowserImportError.accessDenied(source.browser)
            }
            if let found = (json?["extensions"] as? [String: Any])?["settings"] as? [String: Any], !found.isEmpty {
                settings = found
                break
            }
        }
        guard let settings else {
            if !FileManager.default.fileExists(atPath: source.directory.appending(path: "Secure Preferences").path),
               !FileManager.default.fileExists(atPath: source.directory.appending(path: "Preferences").path) {
                throw BrowserImportError.missing("\(source.browser.displayName)'s extension list")
            }
            return []
        }

        var result: [ImportedExtension] = []
        for (id, value) in settings {
            guard let entry = value as? [String: Any], let manifest = entry["manifest"] as? [String: Any],
                  let location = entry["location"] as? Int else { continue }
            if location == 5 || location == 10 || manifest["theme"] != nil { continue }
            guard [1, 4, 6, 8].contains(location) else { continue }

            let rawName = manifest["name"] as? String ?? ""
            let name = resolveName(rawName, id: id, manifest: manifest, profile: source.directory)

            let reasons = entry["disable_reasons"]
            var enabled = true
            if let list = reasons as? [Any], !list.isEmpty { enabled = false }
            if let bits = reasons as? Int, bits != 0 { enabled = false }
            if let state = entry["state"] as? Int, state == 0 { enabled = false }

            var item = ImportedExtension(id: id, name: name, enabled: enabled)
            let updateHost = (manifest["update_url"] as? String).flatMap { URL(string: $0)?.host?.lowercased() }
            let fromStore = entry["from_webstore"] as? Bool ?? false
            let handMade = "Added by hand, not from a store"
            if location == 4 {
                item.notInstallable = handMade
            } else if updateHost == "clients2.google.com" || (updateHost == nil && fromStore && source.browser != .edge) {
                if ExtensionIdentity.isChromeID(id) { item.link = .chromeWebStore(id: id) } else { item.notInstallable = handMade }
            } else if updateHost == "edge.microsoft.com" {
                item.notInstallable = "From Microsoft Edge Add-ons"
            } else {
                item.notInstallable = handMade
            }
            result.append(item)
        }
        return result
    }

    /// `__MSG_key__` looked up in the newest installed version's `_locales`; the id when that fails.
    private static func resolveName(_ raw: String, id: String, manifest: [String: Any], profile: URL) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw.isEmpty ? id : raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        let fm = FileManager.default
        let base = profile.appending(path: "Extensions/\(id)", directoryHint: .isDirectory)
        guard !id.contains("/"), let versions = try? fm.contentsOfDirectory(atPath: base.path) else { return id }
        let locale = (manifest["default_locale"] as? String) ?? "en"
        guard !locale.contains("/") else { return id }
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let file = base.appending(path: "\(version)/_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (name, value) in messages where name.lowercased() == key {
                if let message = (value as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
            }
            return id
        }
        return id
    }

    // MARK: - Firefox

    private static func readFirefox(_ source: ImportSource) throws -> [ImportedExtension] {
        let json: [String: Any]?
        do { json = try loadJSON(source.directory.appending(path: "extensions.json")) } catch BrowserImportError.accessDenied {
            throw BrowserImportError.accessDenied(.firefox)
        }
        guard let json else { throw BrowserImportError.missing("Firefox's extension list") }
        var result: [ImportedExtension] = []
        for case let addon as [String: Any] in json["addons"] as? [Any] ?? [] {
            guard addon["location"] as? String == "app-profile", addon["type"] as? String == "extension",
                  let id = addon["id"] as? String, !id.isEmpty else { continue }
            let rawName = (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? ""
            var item = ImportedExtension(id: id, name: rawName.isEmpty ? id : rawName, enabled: addon["active"] as? Bool ?? false)
            let host = (addon["sourceURI"] as? String).flatMap { URL(string: $0)?.host?.lowercased() }
            if let host, host == "addons.mozilla.org" || host.hasSuffix(".mozilla.net") {
                item.link = .mozillaAddons(slug: id)
            } else {
                item.notInstallable = "Added by hand, not from addons.mozilla.org"
            }
            result.append(item)
        }
        return result
    }
}
