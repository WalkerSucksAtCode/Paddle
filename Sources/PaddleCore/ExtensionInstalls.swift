import Foundation

/// `extension-installs.json`: when Paddle first ran each extension folder, by folder name
/// (`{"protonpass": "2026-10-12T09:00:00Z"}`). WebKit never fires `runtime.onInstalled` with `install` (4c-0, E19),
/// so a folder with no entry gets `CompatPlan.installReason` "install" on its first load, and an entry from then on.
/// When the file doesn't exist yet, every folder that already has a permission record counts as seen, so
/// extensions that ran before this file existed aren't told they were just installed.
public struct ExtensionInstalls: Codable, Sendable, Equatable {
    public var firstSeen: [String: Date]

    public init(firstSeen: [String: Date] = [:]) {
        self.firstSeen = firstSeen
    }

    public init(from decoder: any Decoder) throws {
        firstSeen = try decoder.singleValueContainer().decode([String: Date].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(firstSeen)
    }

    /// A new file: each of `folders` (those with a permission record) seen at `now`.
    public static func seeded(folders: some Sequence<String>, now: Date) -> ExtensionInstalls {
        ExtensionInstalls(firstSeen: Dictionary(folders.map { ($0, now) }, uniquingKeysWith: { a, _ in a }))
    }

    /// "install" when the folder has never run in Paddle, else nil.
    public func installReason(folder: String) -> String? {
        firstSeen[folder] == nil ? "install" : nil
    }

    @discardableResult
    /// Records the first run; later calls keep the first date.
    public mutating func markSeen(folder: String, now: Date) -> Bool {
        guard firstSeen[folder] == nil else { return false }
        firstSeen[folder] = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return true
    }

    /// Drops folders that are gone from `extensions/`, so one put back later counts as a new install, as in Chrome.
    @discardableResult
    public mutating func prune(keeping folders: Set<String>) -> Bool {
        let before = firstSeen.count
        firstSeen = firstSeen.filter { folders.contains($0.key) }
        return firstSeen.count != before
    }

    public static func decode(_ data: Data) throws -> ExtensionInstalls {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExtensionInstalls.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
