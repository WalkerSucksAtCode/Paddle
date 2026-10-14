import Foundation
import PaddleCore

/// Settings > Advanced: what is in config.json beyond the values the other panes edit. Everything here is read
/// from `base` (the bytes on disk) or `file`, so it follows hand edits while the window is open.
extension SettingsModel {
    /// Top-level keys Paddle doesn't read (typos, keys from old versions), in file order.
    var unknownKeys: [String] {
        (try? ConfigFile.unknownKeys(in: base)) ?? []
    }

    /// What Tidy would remove: known keys, `extensions` and `shortcuts` entries and `sites` fields that hold their default.
    var tidyPaths: [[String]] {
        guard case .success(let result) = ConfigFile.tidy(base, shortcutDefaults: MainMenu.defaultBindings) else { return [] }
        return result.removed
    }

    /// Problems in config.json's values: first the values of the wrong type that fell back to their defaults or were
    /// skipped (`decodeIssues`), then the problems in values that parse, from `ConfigValidator` (errors block saving
    /// that key, warnings don't).
    var issues: [ConfigIssue] {
        // With the default shortcuts, a binding that takes another action's default key shows up here too.
        decodeIssues + ConfigValidator.issues(file, actionNames: Set(MainMenu.actionNames), defaults: MainMenu.validatorDefaults)
    }

    /// A key's value as written in the file, shortened for a confirmation message.
    func writtenValue(of key: String) -> String? {
        guard let spans = try? JSONSpans.scan(base), let member = spans.member(key) else { return nil }
        let text = String(decoding: spans.data[member.valueRange], as: UTF8.self)
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    /// Removes the keys Tidy listed when the user confirmed. `snapshot` is the `base` the list was computed from,
    /// so a key edited by hand since then is a conflict, not a silent removal.
    func tidy(_ paths: [[String]], basedOn snapshot: Data) async {
        await save(paths.map { ConfigChange(path: $0, value: nil) }, basedOn: snapshot)
    }

    /// An issue can be fixed by removing what it points at when that only drops one value: a whole key (it falls
    /// back to its default) or one entry of an object key, which Paddle already ignores when it is wrong. Not an
    /// array element (`filterLists`) and not a field inside a `sites` entry, where removing the entry would take the
    /// host's other settings with it.
    static func resetPath(for issue: ConfigIssue) -> [String]? {
        switch issue.path.count {
        case 1: issue.path
        case 2 where [.shortcuts, .siteUserAgents, .sites, .extensions, .extensionCompat, .sitePersonas].contains(issue.key):
            issue.path
        default: nil
        }
    }

    /// `snapshot` is the `base` the confirmation was opened on (see `tidy`).
    func reset(_ path: [String], basedOn snapshot: Data) async {
        await save([ConfigChange(path: path, value: nil)], basedOn: snapshot)
    }

    // MARK: - Site user agents

    /// Sets (or with `agent` nil removes) the user agent for `host`; renaming a host removes `oldHost` in the same
    /// write. `snapshot` is the base the row's draft started from.
    func setSiteUserAgent(host: String, agent: String?, replacing oldHost: String? = nil, basedOn snapshot: Data? = nil) async {
        let key = PaddleConfig.CodingKeys.siteUserAgents.rawValue
        var changes: [ConfigChange] = []
        if let oldHost, oldHost != host { changes.append(ConfigChange(key, oldHost, nil)) }
        changes.append(ConfigChange(key, host, agent.map(JSONValue.string)))
        await save(changes, basedOn: snapshot)
    }
}
