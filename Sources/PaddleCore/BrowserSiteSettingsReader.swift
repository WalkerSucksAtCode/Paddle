import Foundation

/// Per-site zoom and permissions read from another browser, keyed by host (see `BrowserSiteSettingsReader.host(from:)`).
/// Only `zoom`, `javaScript`, `autoplay`, `location` and `notifications` are ever set.
public struct ImportedSiteSettings: Sendable {
    public var sites: [String: SiteSettings]
    /// Entries left out because their pattern wasn't a plain web host: other wildcards, ports, non-web schemes.
    public var skippedPatterns: Int

    public init(sites: [String: SiteSettings] = [:], skippedPatterns: Int = 0) {
        self.sites = sites
        self.skippedPatterns = skippedPatterns
    }
}

/// Reads the per-site zoom and permissions of Chromium-family browsers (`Preferences`) and Firefox
/// (`permissions.sqlite`, `content-prefs.sqlite`). Reads the files only; hosts are never logged.
public enum BrowserSiteSettingsReader {
    public static func read(_ source: ImportSource) throws -> ImportedSiteSettings {
        switch source.browser.family {
        case .safari:
            throw BrowserImportError.unreadable("Safari keeps no per-site zoom or permissions Paddle can import.")
        case .chromium: return try readChromium(source)
        case .firefox: return try readFirefox(source)
        }
    }

    // MARK: - Hosts

    /// The host a Chromium content-setting pattern or a Firefox origin stands for, or nil when it isn't a plain web
    /// host. Accepts `http` / `https` origins and bare hosts, a leading `[*.]` or `*.`, a default port, and a
    /// Chromium `"<primary>,<secondary>"` pair whose secondary is `*` or empty. The result is lowercase, without
    /// scheme, port or a leading `www.`.
    static func host(from pattern: String) -> String? {
        var parts = pattern.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 { return nil }
        if parts.count == 2 {
            guard parts[1] == "*" || parts[1].isEmpty else { return nil }
        }
        var rest = parts.removeFirst().trimmingCharacters(in: .whitespaces)
        var defaultPorts: Set<String> = ["80", "443"]
        if let range = rest.range(of: "://") {
            let scheme = rest[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            defaultPorts = [scheme == "https" ? "443" : "80"]
            rest = String(rest[range.upperBound...])
        } else if rest.contains(":"), !rest.hasPrefix("[") {
            // `about:blank`, `data:...`: a scheme without slashes. A bare host:port falls through to the port check.
            let afterColon = rest[rest.index(after: rest.lastIndex(of: ":")!)...]
            if afterColon.isEmpty || !afterColon.allSatisfy(\.isNumber) { return nil }
        }
        if let slash = rest.firstIndex(of: "/") {
            guard rest[rest.index(after: slash)...].isEmpty else { return nil }
            rest = String(rest[..<slash])
        }
        var wildcard = false
        if rest.hasPrefix("[*.]") {
            rest.removeFirst(4)
            wildcard = true
        } else if rest.hasPrefix("*.") {
            rest.removeFirst(2)
            wildcard = true
        }
        var host = rest
        var port = ""
        if rest.hasPrefix("[") {
            // IPv6 literal, optionally followed by a port.
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[...close])
            let tail = rest[rest.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return nil }
                port = String(tail.dropFirst())
            }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        }
        guard port.isEmpty || defaultPorts.contains(port) else { return nil }
        // `[*.]com` would cover a whole top-level domain.
        guard !wildcard || host.contains(".") else { return nil }
        guard !host.isEmpty, !host.contains("*"), !host.contains(where: \.isWhitespace) else { return nil }
        var normalized = PaddleConfig.normalizedHost(host)
        if normalized.hasPrefix("www.") { normalized.removeFirst(4) }
        return normalized.isEmpty || normalized == "www" ? nil : normalized
    }

    /// Accumulates settings; the first value a host gets for a field stays.
    private struct Collector {
        var imported = ImportedSiteSettings()

        mutating func set(_ pattern: String, _ apply: (inout SiteSettings) -> Void) {
            guard let host = BrowserSiteSettingsReader.host(from: pattern) else {
                imported.skippedPatterns += 1
                return
            }
            var candidate = SiteSettings()
            apply(&candidate)
            // The overlay lays the existing values over the new one, so the first value a field got stays.
            imported.sites[host] = candidate.overlaid(with: imported.sites[host] ?? SiteSettings())
        }
    }

    // MARK: - Chromium family

    static func readChromium(_ source: ImportSource) throws -> ImportedSiteSettings {
        let name = source.settingsFile.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: source.settingsFile)
        } catch {
            throw ImportSQLite.translate(error, browser: source.browser, file: name)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BrowserImportError.unreadable("\(source.browser.displayName)'s Preferences file isn't JSON.")
        }
        return chromiumSiteSettings(root)
    }

    static func chromiumSiteSettings(_ root: [String: Any]) -> ImportedSiteSettings {
        var collector = Collector()

        let partitions = ((root["partition"] as? [String: Any])?["per_host_zoom_levels"] as? [String: Any]) ?? [:]
        for partition in partitions.keys.sorted() {
            guard let hosts = partitions[partition] as? [String: Any] else { continue }
            for pattern in hosts.keys.sorted() {
                let raw = hosts[pattern]
                let level = ((raw as? [String: Any])?["zoom_level"] as? NSNumber)?.doubleValue ?? (raw as? NSNumber)?.doubleValue
                guard let level, level.isFinite, level != 0 else { continue }
                let zoom = SitePolicy.normalizedZoom(pow(1.2, level))
                collector.set(pattern) { $0.zoom = zoom }
            }
        }

        let profile = root["profile"] as? [String: Any]
        let exceptions = ((profile?["content_settings"] as? [String: Any])?["exceptions"] as? [String: Any]) ?? [:]
        for type in ["notifications", "geolocation", "javascript"] {
            guard let patterns = exceptions[type] as? [String: Any] else { continue }
            for pattern in patterns.keys.sorted() {
                guard let setting = ((patterns[pattern] as? [String: Any])?["setting"] as? NSNumber)?.intValue else { continue }
                switch (type, setting) {
                case ("notifications", 1): collector.set(pattern) { $0.notifications = .allow }
                case ("notifications", 2): collector.set(pattern) { $0.notifications = .deny }
                case ("geolocation", 1): collector.set(pattern) { $0.location = .allow }
                case ("geolocation", 2): collector.set(pattern) { $0.location = .deny }
                case ("javascript", 2): collector.set(pattern) { $0.javaScript = false }
                default: continue
                }
            }
        }
        return collector.imported
    }

    // MARK: - Firefox

    static func readFirefox(_ source: ImportSource) throws -> ImportedSiteSettings {
        let fm = FileManager.default
        let permissions = source.directory.appending(path: "permissions.sqlite")
        let prefs = source.directory.appending(path: "content-prefs.sqlite")
        let havePermissions = fm.fileExists(atPath: permissions.path)
        let havePrefs = fm.fileExists(atPath: prefs.path)
        guard havePermissions || havePrefs else { throw BrowserImportError.missing("Firefox's site settings") }

        var collector = Collector()
        do {
            if havePermissions {
                let rows = try ImportSQLite.withCopy(of: permissions, browser: .firefox, what: "permissions database") { db in
                    try ImportSQLite.run(db, """
                        SELECT origin, type, permission FROM moz_perms
                        WHERE expireType = 0 AND instr(type, '^') = 0 ORDER BY origin, type, id
                        """) { (ImportSQLite.text($0, 0), ImportSQLite.text($0, 1), Int(ImportSQLite.int($0, 2))) }
                }
                for (origin, type, permission) in rows {
                    switch (type, permission) {
                    case ("desktop-notification", 1): collector.set(origin) { $0.notifications = .allow }
                    case ("desktop-notification", 2): collector.set(origin) { $0.notifications = .deny }
                    case ("geo", 1): collector.set(origin) { $0.location = .allow }
                    case ("geo", 2): collector.set(origin) { $0.location = .deny }
                    case ("autoplay-media", 1): collector.set(origin) { $0.autoplay = .allow }
                    case ("autoplay-media", 5): collector.set(origin) { $0.autoplay = .block }
                    default: continue
                    }
                }
            }
            if havePrefs {
                let rows = try ImportSQLite.withCopy(of: prefs, browser: .firefox, what: "content preferences database") { db in
                    try ImportSQLite.run(db, """
                        SELECT groups.name, prefs.value FROM prefs
                        JOIN groups ON prefs.groupID = groups.id
                        JOIN settings ON prefs.settingID = settings.id
                        WHERE settings.name = 'browser.content.full-zoom' ORDER BY groups.name, prefs.id
                        """) { (ImportSQLite.text($0, 0), ImportSQLite.double($0, 1)) }
                }
                for (group, factor) in rows where factor.isFinite && factor > 0 && factor != 1 {
                    let zoom = SitePolicy.normalizedZoom(factor)
                    collector.set(group) { $0.zoom = zoom }
                }
            }
        } catch let failure as ImportSQLite.Failure {
            throw BrowserImportError.unreadable("Firefox's site settings couldn't be read (\(failure.message)).")
        }
        return collector.imported
    }
}

// MARK: - Mapping onto config.json

/// What importing site settings would write, as `ConfigFile` changes.
public struct SiteSettingsImport: Sendable {
    public var changes: [ConfigChange]
    /// Hosts that had no `sites` entry and get one.
    public var sitesAdded: Int
    public var fieldsSet: [SiteSettings.Field: Int]
    /// Imported values left out because the host already has that field.
    public var keptExisting: Int

    public init(changes: [ConfigChange] = [], sitesAdded: Int = 0, fieldsSet: [SiteSettings.Field: Int] = [:], keptExisting: Int = 0) {
        self.changes = changes
        self.sitesAdded = sitesAdded
        self.fieldsSet = fieldsSet
        self.keptExisting = keptExisting
    }
}

public enum SiteSettingsMapper {
    /// Fill-only: a change per host and field the existing entry (matched by the exact host key) has no value for,
    /// and only when the imported value isn't Paddle's default. Sorted by host, then field.
    public static func map(_ imported: ImportedSiteSettings, existing: [String: SiteSettings]) -> SiteSettingsImport {
        var result = SiteSettingsImport()
        let fields: [SiteSettings.Field] = [.zoom, .javaScript, .autoplay, .location, .notifications]
        for host in imported.sites.keys.sorted() {
            let site = imported.sites[host]!
            let current = existing[host]
            var wrote = false
            for field in fields {
                guard let value = jsonValue(site, field), value != SiteSettings.defaultValue(field) else { continue }
                if let current, jsonValue(current, field) != nil {
                    result.keptExisting += 1
                    continue
                }
                result.changes.append(ConfigChange(path: ["sites", host, field.rawValue], value: value))
                result.fieldsSet[field, default: 0] += 1
                wrote = true
            }
            if wrote, current == nil { result.sitesAdded += 1 }
        }
        return result
    }

    /// The field as `SiteSettings` encodes it, nil when unset.
    private static func jsonValue(_ site: SiteSettings, _ field: SiteSettings.Field) -> JSONValue? {
        switch field {
        case .zoom: site.zoom.map { .number(SitePolicy.normalizedZoom($0)) }
        case .javaScript: site.javaScript.map { .bool($0) }
        case .autoplay: site.autoplay.map { .string($0.rawValue) }
        case .contentBlocking: site.contentBlocking.map { .bool($0) }
        case .location: site.location.map { .string($0.rawValue) }
        case .notifications: site.notifications.map { .string($0.rawValue) }
        case .httpsOnly: site.httpsOnly.map { .bool($0) }
        case .popups: site.popups.map { .bool($0) }
        case .darkMode: site.darkMode.map { .bool($0) }
        case .freeze: site.freeze.map { .string($0.rawValue) }
        }
    }
}
