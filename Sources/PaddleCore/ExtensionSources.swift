import Foundation

/// `extension-sources.json`: where each store-installed extension came from, by folder name:
/// `{"sponsorblock": {"store": "chromeWebStore", "id": "<crx id>", "version": "5.9.1",
/// "installedAt": "2026-10-12T09:00:00Z", "lastCheck": "2026-10-13T09:00:00Z", "fileHashes": {"manifest.json": "<sha256 hex>"}}}`.
/// Folders dropped into `extensions/` by hand have no entry. `id` is the Chrome id for the Chrome Web Store and the
/// guid for addons.mozilla.org; an add-on's `slug` (its store page's name) is recorded too, when it was known.
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
        /// Whether the package's signature chain was checked: true for a Chrome Web Store package (Google's and the
        /// developer's signatures), and for an addons.mozilla.org add-on only when Mozilla's root was bundled. False when
        /// the add-on's file hash and signature were checked but its certificate wasn't. Absent before this was recorded.
        public var verified: Bool?
        /// The store version the user refused in an update alert. That version is not downloaded or asked about again;
        /// installing a newer one clears it. Absent until a refusal.
        public var declinedVersion: String?
        /// The addons.mozilla.org slug the install link named, so the store page's link matches this record. Absent for
        /// Chrome Web Store installs and for records written before it was recorded.
        public var slug: String?
        /// True for a hand-installed add-on the user chose to keep updated; its first update always asks. Absent
        /// otherwise, and cleared (absent) by the first update.
        public var adopted: Bool?

        public init(
            store: Persona.Source, id: String, version: String? = nil, installedAt: Date? = nil, lastCheck: Date? = nil,
            fileHashes: [String: String] = [:], verified: Bool? = nil, declinedVersion: String? = nil, slug: String? = nil,
            adopted: Bool? = nil
        ) {
            self.adopted = adopted
            self.store = store
            self.id = id
            self.version = version
            self.installedAt = installedAt
            self.lastCheck = lastCheck
            self.fileHashes = fileHashes
            self.verified = verified
            self.declinedVersion = declinedVersion
            self.slug = slug
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            store = try c.decode(Persona.Source.self, forKey: .store)
            id = try c.decode(String.self, forKey: .id)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt)
            lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
            fileHashes = try c.decodeIfPresent([String: String].self, forKey: .fileHashes) ?? [:]
            verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
            declinedVersion = try c.decodeIfPresent(String.self, forKey: .declinedVersion)
            slug = try c.decodeIfPresent(String.self, forKey: .slug)
            adopted = try c.decodeIfPresent(Bool.self, forKey: .adopted)
        }
    }

    public var records: [String: Record]
    /// Folder names whose hand-installed add-on the user said no to (Not Now, Stop Updating); they are not offered
    /// again. Stored under the top-level key `declinedAdoption`; absent (nil) until there is one.
    public var declinedAdoption: [String]?

    /// The top-level key that holds `declinedAdoption` instead of a folder's record.
    public static let declinedKey = "declinedAdoption"

    public init(records: [String: Record] = [:], declinedAdoption: [String]? = nil) {
        self.records = records
        self.declinedAdoption = declinedAdoption
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var records: [String: Record] = [:]
        var declined: [String]?
        for key in c.allKeys {
            if key.stringValue == Self.declinedKey {
                declined = try c.decode([String].self, forKey: key)
            } else {
                records[key.stringValue] = try c.decode(Record.self, forKey: key)
            }
        }
        self.records = records
        declinedAdoption = declined
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (folder, record) in records where folder != Self.declinedKey {
            try c.encode(record, forKey: AnyKey(folder))
        }
        if let declinedAdoption { try c.encode(declinedAdoption, forKey: AnyKey(Self.declinedKey)) }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Whether `folder` was declined for adoption.
    public func hasDeclinedAdoption(_ folder: String) -> Bool {
        declinedAdoption?.contains(folder) ?? false
    }

    /// Adds `folder` to the declined list (once).
    public mutating func declineAdoption(folder: String) {
        var list = declinedAdoption ?? []
        if !list.contains(folder) { list.append(folder) }
        declinedAdoption = list
    }

    /// Removes `folder` from the declined list; the list becomes absent when empty.
    public mutating func clearDeclinedAdoption(folder: String) {
        guard var list = declinedAdoption else { return }
        list.removeAll { $0 == folder }
        declinedAdoption = list.isEmpty ? nil : list
    }

    /// Records a hand-installed add-on as tracked: addons.mozilla.org, `guid` as id, the lookup's `slug`, the installed
    /// manifest `version` and the hashes of the folder's current files (`StoreInstall.fileHashes`), unverified, adopted.
    /// Clears the folder from the declined list. `lastCheck` stays absent so the first check is due at once.
    public mutating func adopt(
        folder: String, guid: String, slug: String?, version: String?, fileHashes: [String: String], now: Date
    ) {
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        records[folder] = Record(
            store: .mozillaAddons, id: guid, version: version, installedAt: now, lastCheck: nil, fileHashes: fileHashes,
            verified: nil, slug: slug, adopted: true
        )
        clearDeclinedAdoption(folder: folder)
    }

    /// Drops an adopted folder's record and keeps it from being offered again. Returns false (changing nothing) when
    /// the folder has no adopted record.
    public mutating func stopAdopted(folder: String) -> Bool {
        guard records[folder]?.adopted == true else { return false }
        records[folder] = nil
        declineAdoption(folder: folder)
        return true
    }

    /// Records an install or update into `folder`, replacing what was there. `installedAt` and `lastCheck` are
    /// `now`, to the second.
    public mutating func recordInstall(
        folder: String, store: Persona.Source, id: String, version: String?, fileHashes: [String: String],
        verified: Bool? = nil, slug: String? = nil, now: Date
    ) {
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        records[folder] = Record(
            store: store, id: id, version: version, installedAt: now, lastCheck: now, fileHashes: fileHashes, verified: verified,
            slug: slug
        )
    }

    /// Drops records of folders that are gone, so a folder dropped in later under the same name doesn't inherit
    /// the store's identity. Returns whether anything was dropped.
    public mutating func prune(keeping folders: Set<String>) -> Bool {
        let before = records.count
        records = records.filter { folders.contains($0.key) }
        return records.count != before
    }

    /// The folder already holding `id` from `store`, so reinstalling the same extension replaces it instead of adding
    /// a second copy. `id` is a Chrome id (compared lowercase), or an add-on's guid or slug (a slug compares lowercase
    /// too). When several folders claim it, the first by name.
    public func folder(forStoreID id: String, store: Persona.Source) -> String? {
        records
            .filter { _, record in
                guard record.store == store else { return false }
                guard store == .chromeWebStore else {
                    return record.id == id || record.slug?.lowercased() == id.lowercased()
                }
                return record.id.lowercased() == id.lowercased()
            }
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
