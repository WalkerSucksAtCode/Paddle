import Foundation

/// The last store update check result for one extension folder, persisted on `ExtensionSources.Record.lastOutcome`.
public struct ExtensionUpdateOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case upToDate
        case updated
        case waitingPermission
        case declined
        case failed
        case notChecked
    }

    public var kind: Kind
    /// When this outcome was recorded.
    public var at: Date
    /// Installed version at the start of the check (for deltas and messages).
    public var fromVersion: String?
    /// The store version involved (newer offer, declined target, or version installed).
    public var storeVersion: String?
    /// Extra detail for failures, skips, or explicit store answers.
    public var detail: String?

    public init(
        kind: Kind, at: Date, fromVersion: String? = nil, storeVersion: String? = nil, detail: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.fromVersion = fromVersion
        self.storeVersion = storeVersion
        self.detail = detail
    }

    /// Builds an outcome from the legacy log line `ExtensionUpdater` used before persistence.
    public static func fromLegacyStatusLine(_ line: String, installed: String?, at: Date) -> ExtensionUpdateOutcome {
        let lower = line.lowercased()
        if lower == "up to date" {
            return ExtensionUpdateOutcome(kind: .upToDate, at: at, fromVersion: installed, detail: nil)
        }
        if lower.hasPrefix("updated to ") {
            let version = String(line.dropFirst("updated to ".count))
            return ExtensionUpdateOutcome(kind: .updated, at: at, fromVersion: installed, storeVersion: version)
        }
        if lower.contains("waiting for permission"), let version = parseVersion(after: "update ", in: line) {
            return ExtensionUpdateOutcome(kind: .waitingPermission, at: at, fromVersion: installed, storeVersion: version)
        }
        if lower.contains("declined"), let version = parseVersion(after: "update ", in: line) {
            return ExtensionUpdateOutcome(kind: .declined, at: at, fromVersion: installed, storeVersion: version)
        }
        if lower.hasPrefix("not checked:") {
            let detail = String(line.dropFirst("not checked:".count)).trimmingCharacters(in: .whitespaces)
            return ExtensionUpdateOutcome(kind: .notChecked, at: at, fromVersion: installed, detail: detail.isEmpty ? nil : detail)
        }
        if lower.hasPrefix("not updated:") {
            let detail = String(line.dropFirst("not updated:".count)).trimmingCharacters(in: .whitespaces)
            return ExtensionUpdateOutcome(kind: .failed, at: at, fromVersion: installed, detail: detail.isEmpty ? nil : detail)
        }
        if lower.hasPrefix("not tracked:") {
            let detail = String(line.dropFirst("not tracked:".count)).trimmingCharacters(in: .whitespaces)
            return ExtensionUpdateOutcome(kind: .failed, at: at, fromVersion: installed, detail: detail.isEmpty ? nil : detail)
        }
        return ExtensionUpdateOutcome(kind: .failed, at: at, fromVersion: installed, detail: line)
    }

    /// The short line the log and Extensions menu still use.
    public func legacyStatusLine(installedVersion: String?) -> String {
        switch kind {
        case .upToDate:
            return "up to date"
        case .updated:
            if let storeVersion {
                if let fromVersion, fromVersion != storeVersion { return "updated \(fromVersion) → \(storeVersion)" }
                return "updated to \(storeVersion)"
            }
            return "updated"
        case .waitingPermission:
            if let storeVersion { return "update \(storeVersion) waiting for permission" }
            return "update waiting for permission"
        case .declined:
            if let storeVersion { return "update \(storeVersion) declined; not asked again" }
            return "update declined; not asked again"
        case .failed:
            if let detail { return "not updated: \(detail)" }
            return "not updated"
        case .notChecked:
            if let detail { return "not checked: \(detail)" }
            return "not checked"
        }
    }

    /// Settings row title (explicit about store answer vs failure vs permission).
    public func settingsSummary(record: ExtensionSources.Record) -> String {
        let installed = record.version ?? fromVersion
        switch kind {
        case .upToDate:
            if record.adopted == true, record.verified == nil {
                return "Up to date — store has no newer version"
            }
            if let installed { return "Up to date — installed \(installed)" }
            return "Up to date"
        case .updated:
            if let from = fromVersion ?? installed, let to = storeVersion ?? record.version, from != to {
                return "Updated \(from) → \(to)"
            }
            if let to = storeVersion ?? record.version { return "Updated to \(to)" }
            return "Updated"
        case .waitingPermission:
            if let storeVersion {
                if record.adopted == true || record.verified == false || record.verified == nil {
                    return "Update \(storeVersion) waiting — review permissions or certificate"
                }
                return "Update \(storeVersion) waiting for permission"
            }
            return "Update waiting for permission"
        case .declined:
            if let storeVersion { return "Declined update \(storeVersion)" }
            return "Update declined"
        case .failed:
            if let detail { return "Not updated: \(detail)" }
            return "Check failed"
        case .notChecked:
            if let detail { return "Not checked: \(detail)" }
            return "Not checked"
        }
    }

    public func settingsSymbol() -> String {
        switch kind {
        case .upToDate, .updated: "checkmark.circle"
        case .waitingPermission: "hourglass"
        case .declined: "hand.raised"
        case .failed, .notChecked: "exclamationmark.triangle"
        }
    }

    private static func parseVersion(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let space = rest.firstIndex(of: " ") else { return String(rest) }
        return String(rest[..<space])
    }
}

/// The last manual “check all” summary, persisted so Settings can show it after reopen.
public struct ExtensionUpdateBatchSummary: Codable, Sendable, Equatable {
    public var at: Date
    public var folderCount: Int
    public var updated: [String]
    public var upToDate: [String]
    public var waiting: [String]
    public var declined: [String]
    public var failed: [String]
    public var notChecked: [String]

    public init(
        at: Date, folderCount: Int, updated: [String] = [], upToDate: [String] = [], waiting: [String] = [],
        declined: [String] = [], failed: [String] = [], notChecked: [String] = []
    ) {
        self.at = at
        self.folderCount = folderCount
        self.updated = updated
        self.upToDate = upToDate
        self.waiting = waiting
        self.declined = declined
        self.failed = failed
        self.notChecked = notChecked
    }

    public static func build(at: Date, folderCount: Int, outcomes: [String: ExtensionUpdateOutcome]) -> ExtensionUpdateBatchSummary {
        var updated: [String] = []
        var upToDate: [String] = []
        var waiting: [String] = []
        var declined: [String] = []
        var failed: [String] = []
        var notChecked: [String] = []
        for folder in outcomes.keys.sorted() {
            switch outcomes[folder]?.kind {
            case .updated: updated.append(folder)
            case .upToDate: upToDate.append(folder)
            case .waitingPermission: waiting.append(folder)
            case .declined: declined.append(folder)
            case .failed: failed.append(folder)
            case .notChecked: notChecked.append(folder)
            case nil: break
            }
        }
        return ExtensionUpdateBatchSummary(
            at: at, folderCount: folderCount, updated: updated, upToDate: upToDate, waiting: waiting,
            declined: declined, failed: failed, notChecked: notChecked
        )
    }

    /// Multi-line note for Settings > Updates (stays until the next check).
    public var settingsNote: String {
        var parts: [String] = [
            "Last check \(at.formatted(date: .abbreviated, time: .shortened)): \(folderCount) store extension\(folderCount == 1 ? "" : "s").",
        ]
        var counts: [String] = []
        if !updated.isEmpty { counts.append("\(updated.count) updated") }
        if !upToDate.isEmpty { counts.append("\(upToDate.count) up to date") }
        if !waiting.isEmpty { counts.append("\(waiting.count) waiting on you") }
        if !declined.isEmpty { counts.append("\(declined.count) declined") }
        if !failed.isEmpty { counts.append("\(failed.count) failed") }
        if !notChecked.isEmpty { counts.append("\(notChecked.count) skipped") }
        if !counts.isEmpty { parts.append(counts.joined(separator: ", ") + ".") }
        if !updated.isEmpty { parts.append("Updated: \(updated.joined(separator: ", ")).") }
        if !waiting.isEmpty { parts.append("Waiting: \(waiting.joined(separator: ", ")).") }
        if !failed.isEmpty { parts.append("Failed: \(failed.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    public static func decodeFile(_ data: Data) throws -> ExtensionUpdateBatchSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExtensionUpdateBatchSummary.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
