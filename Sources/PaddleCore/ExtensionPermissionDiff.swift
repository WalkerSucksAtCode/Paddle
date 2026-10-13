import Foundation

/// What an extension's manifest asks the user about, and what a newer version adds to that. Names are as the manifest
/// writes them (`tabs`, `https://example.com/*`, `<all_urls>`); the app compares them with the user's answers.
public enum ExtensionPermissionDiff {
    /// Permission names and host match patterns.
    public typealias Requests = (permissions: Set<String>, hosts: Set<String>)

    /// What the manifest asks for at install: its `permissions` names, its `host_permissions`, and the match patterns in
    /// `permissions` (Manifest V2). `optional_permissions` and `optional_host_permissions` are not asked for at install.
    public static func required(manifest: Data) throws -> Requests {
        guard let root = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            throw ExtensionManifest.ParseError.notAnObject
        }
        var permissions = Set<String>()
        var hosts = Set<String>()
        for case let item as String in root["permissions"] as? [Any] ?? [] {
            if ExtensionManifest.isPattern(item) { hosts.insert(item) } else { permissions.insert(item) }
        }
        for case let item as String in root["host_permissions"] as? [Any] ?? [] { hosts.insert(item) }
        return (permissions, hosts)
    }

    /// What `new` requires that `installed` did not. A permission or host the installed version kept optional, which
    /// `new` requires, counts as added: Chrome asks about those when it updates.
    public static func added(from installed: Data, to new: Data) throws -> Requests {
        let before = try required(manifest: installed)
        let after = try required(manifest: new)
        return (after.permissions.subtracting(before.permissions), after.hosts.subtracting(before.hosts))
    }

    /// What a newer version needs answered before it may replace the copy that runs: the undecided requests (what a load
    /// asks about, `ExtensionDecisions.undecided`), plus the requests `added` names that the user hasn't granted, which
    /// includes ones the user refused before. Granted requests are never asked again, and "Only When I Click" hosts count
    /// as granted. Empty means the version asks for nothing the user hasn't granted, so it can swap in without a question.
    /// `name` is the extension's display name as a load compares it; a different name means nothing was granted.
    public static func asks(
        requested: Requests, added: Requests, decisions: ExtensionDecisions, folder: String, name: String
    ) -> Requests {
        let undecided = decisions.undecided(folder: folder, name: name, permissions: requested.permissions, hosts: requested.hosts)
        var granted: Requests = ([], [])
        if let snapshot = decisions.byFolder[folder], snapshot.name == name {
            granted.permissions = Set(snapshot.permissions.filter { $0.value == .allow }.keys)
            granted.hosts = Set(snapshot.hosts.filter { $0.value != .deny }.keys)
        }
        let addedUngranted = (
            permissions: requested.permissions.intersection(added.permissions).subtracting(granted.permissions)
                .subtracting(ExtensionSnapshot.unrecorded),
            hosts: requested.hosts.intersection(added.hosts).subtracting(granted.hosts)
        )
        return (undecided.permissions.union(addedUngranted.permissions), undecided.hosts.union(addedUngranted.hosts))
    }
}
