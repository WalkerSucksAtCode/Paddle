import Foundation

public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
    /// Hosts only (Only When I Click): neither granted nor denied to WebKit, so a click on the extension's button
    /// grants that tab through `activeTab` for that click. An explicit denial would block that grant.
    case click
}

/// What the user decided for one extension, as stored in `extension-permissions.json`.
public struct ExtensionSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var decided: Date
    /// WebKit permission names (`tabs`, `storage`, ...).
    public var permissions: [String: PermissionDecision]
    /// Match patterns exactly as WebKit stores them (`https://example.com/*`).
    public var hosts: [String: PermissionDecision]
    /// The install alert's answer to "may it run at all". It tells an allowed extension that asks for nothing apart
    /// from one never asked about. nil in records written before it existed: the answers above decide.
    public var run: PermissionDecision?

    public init(name: String, version: String, decided: Date,
                permissions: [String: PermissionDecision] = [:], hosts: [String: PermissionDecision] = [:],
                run: PermissionDecision? = nil) {
        self.name = name
        self.version = version
        self.decided = decided
        self.permissions = permissions
        self.hosts = hosts
        self.run = run
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        decided = try c.decode(Date.self, forKey: .decided)
        permissions = try c.decodeIfPresent([String: PermissionDecision].self, forKey: .permissions) ?? [:]
        hosts = try c.decodeIfPresent([String: PermissionDecision].self, forKey: .hosts) ?? [:]
        run = try c.decodeIfPresent(PermissionDecision.self, forKey: .run)
    }

    /// True when the extension must not load: the user said Don't Allow, or (in older records) nothing was allowed.
    public var isFullyDeclined: Bool {
        switch run {
        case .deny: true
        case .allow, .click: false  // `.click` is for hosts; never written as `run`
        case nil: !permissions.values.contains(.allow) && !hosts.values.contains(.allow)
        }
    }

    /// Records an install-alert answer. `undecided` are the items the alert listed; the rest of `requested` were
    /// answered before (a newer version asking for more). The answer covers the whole extension, not just the list:
    /// - Allow grants the listed items; earlier answers stay.
    /// - Only When I Click grants the listed permission names and marks every requested host pattern `.click`,
    ///   earlier grants included, so pages are reachable only through `activeTab` on a click.
    /// - Don't Allow denies everything requested and stops the extension running.
    /// Names in `unrecorded` are never written.
    public mutating func apply(
        _ answer: ExtensionInstallAnswer, requested: (permissions: Set<String>, hosts: Set<String>),
        undecided: (permissions: Set<String>, hosts: Set<String>)
    ) {
        let requested = (permissions: requested.permissions.subtracting(Self.unrecorded), hosts: requested.hosts)
        let undecided = (permissions: undecided.permissions.subtracting(Self.unrecorded), hosts: undecided.hosts)
        switch answer {
        case .allow:
            for permission in undecided.permissions { permissions[permission] = .allow }
            for host in undecided.hosts { hosts[host] = .allow }
        case .onlyWhenClicked:
            for permission in undecided.permissions { permissions[permission] = .allow }
            for host in requested.hosts.union(undecided.hosts) { hosts[host] = .click }
        case .deny:
            for permission in requested.permissions.union(undecided.permissions) { permissions[permission] = .deny }
            for host in requested.hosts.union(undecided.hosts) { hosts[host] = .deny }
        }
        for permission in Self.unrecorded { permissions[permission] = nil }
        let allowsSomething = permissions.values.contains(.allow) || hosts.values.contains(.allow)
        let asksForNothing = requested.permissions.isEmpty && requested.hosts.isEmpty
        run = answer != .deny && (allowsSomething || asksForNothing) ? .allow : .deny
    }

    /// Builds a snapshot from WebKit's four permission dictionaries (item to expiry date). Only entries expiring
    /// more than 10 years from `now` are kept: WebKit reports "no expiry" as 4001-01-01, while grants made by a
    /// user gesture (`activeTab`) carry a short expiry and must not be persisted. A denial beats a grant for the same item.
    /// `clickHosts`: patterns recorded as `.click`; WebKit holds no lasting state for them, so each one that is still
    /// neither granted nor denied stays `.click`.
    /// Permission names Paddle decides itself, so they are never asked about or written: `nativeMessaging` reaches
    /// only Paddle's own compatibility bus (`ExtensionCompat.busID`), which Paddle grants on the context.
    public static let unrecorded: Set<String> = ["nativeMessaging"]

    public static func from(name: String, version: String, run: PermissionDecision? = nil,
                            granted: [String: Date], denied: [String: Date],
                            grantedHosts: [String: Date], deniedHosts: [String: Date],
                            clickHosts: Set<String> = [], now: Date) -> ExtensionSnapshot {
        let cutoff = now.addingTimeInterval(10 * 365 * 86_400)
        func decisions(_ allowed: [String: Date], _ refused: [String: Date]) -> [String: PermissionDecision] {
            var result: [String: PermissionDecision] = [:]
            for (item, date) in allowed where date > cutoff { result[item] = .allow }
            for (item, date) in refused where date > cutoff { result[item] = .deny }
            return result
        }
        let permissions = decisions(granted, denied).filter { !unrecorded.contains($0.key) }
        // Whole seconds: the file stores ISO 8601 without fractions.
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var hosts = decisions(grantedHosts, deniedHosts)
        for host in clickHosts where hosts[host] == nil { hosts[host] = .click }
        return ExtensionSnapshot(name: name, version: version, decided: stamp,
                                 permissions: permissions, hosts: hosts, run: run)
    }
}

/// The install alert's three answers.
public enum ExtensionInstallAnswer: Sendable, Equatable {
    case allow
    /// Permission names granted, every host pattern `.click`: pages are reachable only through `activeTab` on a click.
    case onlyWhenClicked
    case deny
}

/// The whole `extension-permissions.json`: a top-level object keyed by folder name.
public struct ExtensionDecisions: Codable, Sendable, Equatable {
    public var byFolder: [String: ExtensionSnapshot]

    public init(byFolder: [String: ExtensionSnapshot] = [:]) {
        self.byFolder = byFolder
    }

    public init(from decoder: any Decoder) throws {
        byFolder = try decoder.singleValueContainer().decode([String: ExtensionSnapshot].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(byFolder)
    }

    /// Parses the file (ISO 8601 dates). Unknown keys are ignored; anything else wrong throws.
    public static func decode(_ data: Data) throws -> ExtensionDecisions {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExtensionDecisions.self, from: data)
    }

    /// Pretty, sorted keys, unescaped slashes: hand-editable.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The permissions and hosts the user hasn't decided on yet. A folder with no record, or one that now holds an
    /// extension with a different name, has decided nothing.
    public func undecided(folder: String, name: String, permissions: Set<String>, hosts: Set<String>)
        -> (permissions: Set<String>, hosts: Set<String>) {
        let permissions = permissions.subtracting(ExtensionSnapshot.unrecorded)
        guard let snapshot = byFolder[folder], snapshot.name == name else { return (permissions, hosts) }
        return (permissions.subtracting(snapshot.permissions.keys), hosts.subtracting(snapshot.hosts.keys))
    }

    /// True when the user must be asked before the extension loads: never asked (an extension that asks for nothing
    /// included), a different extension in the folder now, or a newer version asking for more.
    public func needsPrompt(folder: String, name: String, permissions: Set<String>, hosts: Set<String>) -> Bool {
        guard let snapshot = byFolder[folder], snapshot.name == name else { return true }
        let open = undecided(folder: folder, name: name, permissions: permissions, hosts: hosts)
        return !open.permissions.isEmpty || !open.hosts.isEmpty
    }

    public mutating func set(folder: String, _ snapshot: ExtensionSnapshot) {
        byFolder[folder] = snapshot
    }

    public mutating func forget(folder: String) {
        byFolder[folder] = nil
    }
}

/// Plain-language text for the permission alerts.
public enum ExtensionPermissionText {
    static let allSitesLine = "Every website: read and change everything, including sites you're signed in to"
    static let noAccessLine = "No access to your pages or tabs; it runs its own code and can use the network"
    static let allSitesPatterns: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]
    static let maxLines = 12
    static let maxHosts = 5
    /// Combining marks kept in a row: enough for real text and emoji, not for a tower of stacked accents.
    static let maxMarksInRow = 2

    static let phrases: [String: String] = [
        "activeTab": "See and change the current page when you click its button",
        "alarms": "Run tasks on a timer",
        "clipboardWrite": "Put things on your clipboard",
        "contextMenus": "Add items to menus",
        "cookies": "Read and change cookies, including for sites you're signed in to",
        "declarativeNetRequest": "Block content on pages",
        "declarativeNetRequestFeedback": "See which of its block rules matched",
        "declarativeNetRequestWithHostAccess": "Block or change requests on the sites it can access",
        "menus": "Add items to menus",
        "nativeMessaging": "Talk to Paddle's compatibility layer (never to other apps)",
        "scripting": "Run code in pages",
        "storage": "Keep its own settings and data",
        "tabs": "See the addresses and titles of your tabs",
        "unlimitedStorage": "Store an unlimited amount of its own data",
        "webNavigation": "See which pages you open and where you go next",
        "webRequest": "See the requests pages make",
    ]

    /// Makes extension-supplied text (and folder names) safe to show: strips control, format (bidi overrides) and
    /// line-break characters, keeps at most two combining marks in a row, trims, and truncates to `max` characters
    /// and `3 × max` Unicode scalars with a trailing "…".
    public static func sanitize(_ s: String, max: Int = 60) -> String {
        let banned: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark]
        var scalars = String.UnicodeScalarView()
        var marksInRow = 0
        for scalar in s.unicodeScalars {
            let category = scalar.properties.generalCategory
            if banned.contains(category) { continue }
            if marks.contains(category) {
                marksInRow += 1
                if marksInRow > maxMarksInRow { continue }
            } else {
                marksInRow = 0
            }
            scalars.append(scalar)
        }
        let clean = String(scalars).trimmingCharacters(in: .whitespaces)
        let scalarBudget = max * 3
        guard clean.count > max || clean.unicodeScalars.count > scalarBudget else { return clean }
        var out = ""
        var characters = 0
        var used = 0
        for character in clean {
            let cost = character.unicodeScalars.count
            guard characters < Swift.max(max - 1, 0), used + cost < scalarBudget else { break }
            out.append(character)
            characters += 1
            used += cost
        }
        return out + "…"
    }

    /// One line per thing the extension wants, at most 12. All-sites access comes first: the well-known patterns,
    /// any pattern whose host is `*`, and the patterns in `allSites` (those WebKit reports as matching every host).
    /// Wildcards over a whole domain ending (`*.com`, `*.co.uk`) get their own line, so the five-host cap can't hide
    /// them; other hosts share one line (five at most, with the rest counted). Permissions follow, sorted by name.
    /// An extension that asks for nothing gets one line saying so.
    public static func lines(permissions: Set<String>, hosts: Set<String>, allSites: Set<String> = []) -> [String] {
        var result: [String] = []
        let everySite = hosts.filter { allSitesPatterns.contains($0) || allSites.contains($0) || hostPart($0) == "*" }
        if !everySite.isEmpty { result.append(allSitesLine) }

        let rest = hosts.subtracting(everySite)
        let endings = Set(rest.compactMap(domainEnding)).sorted()
        if !endings.isEmpty { result.append("Every site ending in " + capped(endings) + ": read and change pages") }

        let names = Set(rest.filter { domainEnding($0) == nil }.map(displayHost)).sorted()
        if !names.isEmpty { result.append("Read and change pages on: " + capped(names)) }

        result += permissions.sorted().map { phrases[$0] ?? sanitize($0) }
        if result.isEmpty { return [noAccessLine] }
        guard result.count > maxLines else { return result }
        let hidden = result.count - (maxLines - 1)
        return Array(result.prefix(maxLines - 1)) + ["(and \(hidden) more)"]
    }

    private static func capped(_ items: [String]) -> String {
        var text = items.prefix(maxHosts).joined(separator: ", ")
        if items.count > maxHosts { text += " (and \(items.count - maxHosts) more)" }
        return text
    }

    /// The host part of a match pattern, without a port; nil when the pattern has none.
    private static func hostPart(_ pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        let host = pattern[range.upperBound...].prefix { $0 != "/" }
        return String(host.prefix { $0 != ":" })
    }

    /// `.com` for `*://*.com/*`, `.co.uk` for `https://*.co.uk/*`: a wildcard over a top-level domain or a
    /// two-part ending whose first part is short (co.uk, com.au, ne.jp). nil for anything else. A false match only
    /// makes the line more explicit, never hides access.
    private static func domainEnding(_ pattern: String) -> String? {
        guard let host = hostPart(pattern), host.hasPrefix("*.") else { return nil }
        let labels = host.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return nil }
        let isEnding = labels.count == 1 || (labels.count == 2 && labels[0].count <= 3 && labels[1].count == 2)
        return isEnding ? sanitize("." + labels.joined(separator: ".")) : nil
    }

    /// `https://*.example.com/*` becomes `example.com`; patterns without a usable host are shown as written.
    private static func displayHost(_ pattern: String) -> String {
        guard var host = hostPart(pattern) else { return sanitize(pattern) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        return host.isEmpty || host == "*" ? sanitize(pattern) : sanitize(host)
    }
}
