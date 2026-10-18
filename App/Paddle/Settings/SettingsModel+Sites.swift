import AppKit
import PaddleCore

/// One host in Settings > Sites, from a `sites` entry, a `siteUserAgents` entry or both: what Paddle does on that
/// host, and where each value comes from.
struct SiteRow: Identifiable, Equatable {
    /// The key as written in config.json (the `sites` spelling when both keys have the host).
    let key: String
    /// The host's own `siteUserAgents` entry, and the key it is under.
    let userAgent: (key: String, value: String)?
    /// The host's effective settings (`PaddleConfig.sitePolicy`): the entry's own fields over its parent
    /// domains' entries over Paddle's defaults.
    let policy: SitePolicy
    /// What the host would get without this entry, so setting a field back to it removes the field.
    let inherited: SitePolicy
    /// A parent domain's entry that turns content blocking off; its exception covers this host whatever the entry
    /// says (see `PaddleConfig.blockingOffHosts`).
    let blockingOffBy: String?
    /// ConfigValidator's issues on this entry (a key that is no host, a zoom that isn't above 0).
    let issues: [ConfigIssue]

    var id: String { key }

    static func == (a: SiteRow, b: SiteRow) -> Bool {
        a.key == b.key && a.userAgent?.key == b.userAgent?.key && a.userAgent?.value == b.userAgent?.value
            && a.policy == b.policy && a.inherited == b.inherited && a.blockingOffBy == b.blockingOffBy && a.issues == b.issues
    }
}

/// Settings > Sites' reads and writes of `sites`, and its site-data and session-answer actions.
extension SettingsModel {
    /// Every host with a `sites` or `siteUserAgents` entry, one row per host (keys compared as
    /// `PaddleConfig.normalizedHost` gives them).
    var siteRows: [SiteRow] {
        let issues = self.issues.filter { $0.key == .sites || $0.key == .siteUserAgents }
        var keys = file.sites.keys.sorted()
        let siteHosts = Set(keys.map(PaddleConfig.normalizedHost))
        let isDark = AppModel.shared.effectiveAppearanceIsDark
        keys += file.siteUserAgents.keys.sorted().filter { !siteHosts.contains(PaddleConfig.normalizedHost($0)) }
        return keys.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }.map { key in
            var without = file
            without.sites[key] = nil
            let parents = file.siteSettingsKeys(forHost: key).filter { $0 != key }
            return SiteRow(
                key: key,
                userAgent: userAgentEntry(forKey: key),
                policy: file.sitePolicy(forHost: key, systemIsDark: isDark),
                inherited: without.sitePolicy(forHost: key, systemIsDark: isDark),
                blockingOffBy: parents.last { file.sites[$0]?.contentBlocking == false },
                issues: issues.filter { $0.path.starts(with: ["sites", key]) || $0.path.starts(with: ["siteUserAgents", key]) }
            )
        }
    }

    /// The `siteUserAgents` entry for the same host as `key`, in whatever spelling it was written.
    private func userAgentEntry(forKey key: String) -> (key: String, value: String)? {
        let host = PaddleConfig.normalizedHost(key)
        guard let uaKey = file.siteUserAgents.keys.sorted().first(where: { PaddleConfig.normalizedHost($0) == host }),
              let value = file.siteUserAgents[uaKey] else { return nil }
        return (uaKey, value)
    }

    /// Sets the row's user agent (`siteUserAgents.<host>`), or removes it for nil (Safari's, Paddle's default).
    func setUserAgent(_ value: String?, for row: SiteRow) async {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = value?.isEmpty == false ? value : nil
        await save([ConfigChange("siteUserAgents", row.userAgent?.key ?? row.key, text.map(JSONValue.string))])
    }

    /// The host of the frontmost ordinary window's page, for Add Current Site (`BrowserModel.currentPageTab`). Private
    /// windows don't count: adding their site would write it to config.json.
    var currentSiteHost: String? {
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }
            .first { !$0.model.isPrivate }
        return front?.model.currentPageTab(schemes: ["http", "https"])?.url?.host()
    }

    /// The key `text` would be added under: a pasted URL gives its host; the host is lowercased with no trailing
    /// dot. Returns the existing key when the host already has an entry (any spelling).
    func siteKey(forTyped text: String) -> (key: String, exists: Bool)? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.contains("://"), let parsed = URL(string: host)?.host() { host = parsed }
        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let normalized = PaddleConfig.normalizedHost(host)
        let keys = Array(file.sites.keys) + Array(file.siteUserAgents.keys)
        if let existing = keys.filter({ PaddleConfig.normalizedHost($0) == normalized }).min() {
            return (existing, true)
        }
        return (host, false)
    }

    /// What ConfigValidator says about a new entry for `key`, before it is written.
    func newSiteIssues(_ key: String) -> [ConfigIssue] {
        issues(for: .sites) { $0.sites[key] = SiteSettings() }.filter { $0.path.starts(with: ["sites", key]) }
    }

    /// Add Site: an empty entry, so the host has a row to set fields on. Every field is unset (Paddle's defaults,
    /// or a parent domain's entry).
    func addSite(_ key: String) async {
        await save([ConfigChange("sites", key, .object([:]))])
    }

    /// Remove Site: the whole `sites` entry, unknown members included, and the host's user agent.
    func removeSite(_ row: SiteRow) async {
        var changes: [ConfigChange] = []
        if file.sites[row.key] != nil { changes.append(ConfigChange("sites", row.key, nil)) }
        if let ua = row.userAgent { changes.append(ConfigChange("siteUserAgents", ua.key, nil)) }
        guard !changes.isEmpty else { return }
        await save(changes)
    }

    /// Sets one field of `sites.<key>`. A value equal to what the host would get without the field (its parent
    /// domains' entries, else Paddle's default) removes the field; the entry itself stays, even empty, until
    /// Remove Site. The entry is rebuilt from the bytes the write is based on, so other members (unknown ones
    /// included) and an edit queued just before survive. Refused when the result still has a ConfigValidator error
    /// on this entry; returns that error's message.
    @discardableResult
    func setSiteField(_ field: SiteSettings.Field, _ value: JSONValue, forKey key: String) async -> String? {
        var candidate = file
        var entry = candidate.sites[key] ?? SiteSettings()
        switch (field, value) {
        case (.zoom, .number(let zoom)): entry.zoom = zoom
        case (.javaScript, .bool(let on)): entry.javaScript = on
        case (.autoplay, .string(let text)): entry.autoplay = SiteSettings.Autoplay(rawValue: text)
        case (.contentBlocking, .bool(let on)): entry.contentBlocking = on
        case (.location, .string(let text)): entry.location = SiteSettings.Permission(rawValue: text)
        case (.notifications, .string(let text)): entry.notifications = SiteSettings.Permission(rawValue: text)
        case (.httpsOnly, .bool(let on)): entry.httpsOnly = on
        case (.popups, .bool(let on)): entry.popups = on
        case (.freeze, .string(let text)): entry.freeze = SiteSettings.Freeze(rawValue: text)
        case (.darkMode, .bool(let on)): entry.darkMode = on
        default: return "\(field.rawValue) can't be set to that value."
        }
        candidate.sites[key] = entry
        let errors = ConfigValidator.issues(candidate, actionNames: Set(MainMenu.actionNames))
            .filter { $0.severity == .error && $0.path.starts(with: ["sites", key]) }
        if let error = errors.first { return error.message }

        var without = file
        without.sites[key] = nil
        // Dark mode set to follow the system inherits macOS's look, so "off" on a dark Mac is a real choice.
        let inherited = Self.json(field, of: without.sitePolicy(forHost: key, systemIsDark: AppModel.shared.effectiveAppearanceIsDark))
        await save(building: { base in
            var object = ((try? JSONSpans.scan(base))?.object["sites"]?.objectValue?[key]?.objectValue) ?? [:]
            object[field.rawValue] = value == inherited ? nil : value
            return [ConfigChange("sites", key, .object(object))]
        })
        return nil
    }

    /// Clear Data: every kind of website data WebKit keeps for `key`'s domain in the ordinary store
    /// (`WebEnvironment.clearData`). Returns how many records went.
    func clearSiteData(_ key: String) async -> Int {
        await AppModel.shared.web.clearData(forHost: key, profile: profileID)
    }

    /// "This session": this profile's camera, microphone, location and download answers, grouped by host.
    var sessionAnswers: [(host: String, answers: [SessionPermissions.Answer])] {
        let all = AppModel.shared[permissionsFor: false, profile: profileID].all
        var hosts: [String] = []
        for answer in all where !hosts.contains(answer.host) { hosts.append(answer.host) }
        return hosts.map { host in (host, all.filter { $0.host == host }) }
    }

    /// Forget: the host's next camera, microphone, location, notification or download request asks again.
    func forgetSessionAnswers(_ host: String) {
        AppModel.shared.forgetSessionAnswers(forHost: host, profile: profileID)
    }

    /// `field` of `policy` as config.json writes it.
    static func json(_ field: SiteSettings.Field, of policy: SitePolicy) -> JSONValue {
        switch field {
        case .zoom: .number(policy.zoom)
        case .javaScript: .bool(policy.javaScript)
        case .autoplay: .string(policy.autoplay.rawValue)
        case .contentBlocking: .bool(policy.contentBlocking)
        case .location: .string(policy.location.rawValue)
        case .notifications: .string(policy.notifications.rawValue)
        case .httpsOnly: .bool(policy.httpsOnly)
        case .popups: .bool(policy.popups)
        case .darkMode: .bool(policy.darkMode)
        case .freeze: .string(policy.freeze.rawValue)
        }
    }
}
