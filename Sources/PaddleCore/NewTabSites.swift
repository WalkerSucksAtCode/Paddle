import Foundation

/// One pinned tile on the New Tab page.
public struct NewTabSite: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String

    public init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case id, title, url }

    /// Lenient, for hand-written files: a missing `id` becomes a fresh one and a missing `title` the address.
    /// A missing `url` is an error (`NewTabSites` skips such entries).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? url
    }
}

/// The New Tab page's pinned sites and the hosts removed from its Frequently visited row (newtab.json).
public struct NewTabSites: Codable, Sendable, Equatable {
    public var sites: [NewTabSite]
    /// Hosts (lowercase, without `www.`) the user removed from Frequently visited.
    public var hiddenFrequent: [String]
    public static let maxSites = 24

    public init(sites: [NewTabSite] = [], hiddenFrequent: [String] = []) {
        self.sites = sites
        self.hiddenFrequent = hiddenFrequent
    }

    private enum CodingKeys: String, CodingKey { case sites, hiddenFrequent }

    /// A bad entry decodes to nil instead of failing the whole file.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Lenient, for hand-written files: unknown keys are ignored, but `sites` or `hiddenFrequent` that isn't a list
    /// throws (so the store refuses to overwrite the file), entries that aren't web addresses (or don't
    /// parse) are skipped, as are duplicates and anything beyond `maxSites`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([Lossy<NewTabSite>].self, forKey: .sites)
        var result = NewTabSites()
        for site in (decoded ?? []).compactMap(\.value) {
            _ = result.add(id: site.id, title: site.title, url: site.url)
        }
        sites = result.sites
        let hidden = try container.decodeIfPresent([Lossy<String>].self, forKey: .hiddenFrequent)
        hiddenFrequent = []
        for host in (hidden ?? []).compactMap(\.value) { hideFrequent(host: host) }
    }

    public static func decode(_ data: Data) throws -> NewTabSites {
        try JSONDecoder().decode(NewTabSites.self, from: data)
    }

    /// Pretty-printed JSON with sorted keys, so the file diffs and hand-edits well.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - Addresses

    /// The form addresses are compared in: scheme and host lowercased, a trailing slash ignored. Nil unless the
    /// address is an http(s) URL with a host.
    public static func normalized(_ address: String) -> String? {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    /// An address's host, lowercased and without `www.`; nil unless it is an http(s) URL with a host.
    public static func siteHost(_ address: String) -> String? {
        guard let normalized = normalized(address), let host = URLComponents(string: normalized)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Editing

    /// Appends a tile. Refuses (false) an address that isn't http(s), one already pinned, and a full page.
    /// An empty title becomes the host.
    @discardableResult
    public mutating func add(title: String, url: String) -> Bool {
        add(id: UUID(), title: title, url: url)
    }

    @discardableResult
    private mutating func add(id: UUID, title: String, url: String) -> Bool {
        guard sites.count < Self.maxSites, let key = Self.normalized(url),
              !sites.contains(where: { Self.normalized($0.url) == key }) else { return false }
        sites.append(NewTabSite(id: id, title: Self.displayTitle(title, url), url: url.trimmingCharacters(in: .whitespacesAndNewlines)))
        return true
    }

    public mutating func remove(id: UUID) {
        sites.removeAll { $0.id == id }
    }

    /// Moves the tile at `from` so it sits at index `to` of the list as it is once the tile is taken out
    /// (`to == sites.count - 1` is the end). Out-of-range indices change nothing.
    public mutating func move(from: Int, to: Int) {
        guard sites.indices.contains(from), (0..<sites.count).contains(to), from != to else { return }
        sites.insert(sites.remove(at: from), at: to)
    }

    /// Changes a tile's title and address. Refuses (false) an address that isn't http(s) or that another tile has.
    @discardableResult
    public mutating func update(id: UUID, title: String, url: String) -> Bool {
        guard let index = sites.firstIndex(where: { $0.id == id }), let key = Self.normalized(url),
              !sites.contains(where: { $0.id != id && Self.normalized($0.url) == key }) else { return false }
        sites[index].title = Self.displayTitle(title, url)
        sites[index].url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Keeps `host` (any case, with or without `www.`) out of Frequently visited.
    public mutating func hideFrequent(host: String) {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !hiddenFrequent.contains(host) else { return }
        hiddenFrequent.append(host)
    }

    private static func displayTitle(_ title: String, _ url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (siteHost(url) ?? url) : trimmed
    }
}
