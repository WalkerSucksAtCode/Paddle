import Foundation

/// `extension-sources.json`: where each store-installed extension came from, by folder name:
/// `{"sponsorblock": {"store": "chromeWebStore", "id": "<crx id>", "version": "5.9.1",
/// "installedAt": "2026-10-12T09:00:00Z", "lastCheck": "2026-10-13T09:00:00Z", "fileHashes": {"manifest.json": "<sha256 hex>"}}}`.
/// Folders dropped into `extensions/` by hand have no entry. `id` is the Chrome id for the Chrome Web Store and the
/// slug or guid for addons.mozilla.org.
public struct ExtensionSources: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable {
        public var store: Persona.Source
        public var id: String
        public var version: String?
        public var installedAt: Date?
        /// When the store was last asked for a newer version; absent until it has been.
        public var lastCheck: Date?
        /// SHA-256 (lowercase hex) of each file as installed, by path inside the folder, so a later update can tell
        /// files the user changed.
        public var fileHashes: [String: String]

        public init(
            store: Persona.Source, id: String, version: String? = nil, installedAt: Date? = nil, lastCheck: Date? = nil,
            fileHashes: [String: String] = [:]
        ) {
            self.store = store
            self.id = id
            self.version = version
            self.installedAt = installedAt
            self.lastCheck = lastCheck
            self.fileHashes = fileHashes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            store = try c.decode(Persona.Source.self, forKey: .store)
            id = try c.decode(String.self, forKey: .id)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt)
            lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
            fileHashes = try c.decodeIfPresent([String: String].self, forKey: .fileHashes) ?? [:]
        }
    }

    public var records: [String: Record]

    public init(records: [String: Record] = [:]) {
        self.records = records
    }

    public init(from decoder: any Decoder) throws {
        records = try decoder.singleValueContainer().decode([String: Record].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(records)
    }

    /// Records an install or update into `folder`, replacing what was there. `installedAt` and `lastCheck` are
    /// `now`, to the second.
    public mutating func recordInstall(
        folder: String, store: Persona.Source, id: String, version: String?, fileHashes: [String: String], now: Date
    ) {
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        records[folder] = Record(store: store, id: id, version: version, installedAt: now, lastCheck: now, fileHashes: fileHashes)
    }

    /// Drops records of folders that are gone, so a folder dropped in later under the same name doesn't inherit
    /// the store's identity. Returns whether anything was dropped.
    public mutating func prune(keeping folders: Set<String>) -> Bool {
        let before = records.count
        records = records.filter { folders.contains($0.key) }
        return records.count != before
    }

    /// The folder already holding `id` from `store`, so reinstalling the same extension replaces it instead of adding
    /// a second copy. Chrome ids compare lowercase. When several folders claim it, the first by name.
    public func folder(forStoreID id: String, store: Persona.Source) -> String? {
        let wanted = store == .chromeWebStore ? id.lowercased() : id
        return records
            .filter { $0.value.store == store && (store == .chromeWebStore ? $0.value.id.lowercased() : $0.value.id) == wanted }
            .keys.sorted().first
    }

    /// A new folder name for an extension called `displayName`: lowercase ASCII letters, digits and hyphens, at most
    /// 40 characters, never empty, and `-2`, `-3` ... when it collides (case-insensitively) with one of `existing`.
    /// Accents are dropped ("Ünïcode" → "unicode"); anything else becomes a hyphen.
    public static func folderName(forDisplayName displayName: String, existing: some Sequence<String>) -> String {
        let maxLength = 40
        let taken = Set(existing.map { $0.lowercased() })
        let folded = displayName.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var base = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                base.unicodeScalars.append(scalar)
            } else if !base.isEmpty, base.last != "-" {
                base.append("-")
            }
        }
        base = trimmed(base, to: maxLength)
        if base.isEmpty { base = "extension" }
        if !taken.contains(base) { return base }
        var number = 2
        while true {
            let suffix = "-\(number)"
            let candidate = trimmed(base, to: maxLength - suffix.count) + suffix
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// `name` cut to `length` characters, without trailing hyphens.
    private static func trimmed(_ name: String, to length: Int) -> String {
        var name = String(name.prefix(length))
        while name.hasSuffix("-") { name.removeLast() }
        return name
    }

    public static func decode(_ data: Data) throws -> ExtensionSources {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExtensionSources.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
