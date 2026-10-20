import CryptoKit
import Foundation

/// When downloaded filter lists are refreshed automatically (`filterUpdateDays` in config.json).
/// Each list is judged on its own file in `filters/`, so one fresh list never hides a stale, failing or new one.
public enum FilterUpdatePolicy {
    /// The file in `filters/` a list URL downloads to, or nil when the entry is not an https URL (such entries
    /// are never downloaded). The two default lists keep the names they have always had (`easylist.txt`,
    /// `easyprivacy.txt`), so existing downloads stay in use. Any other list is `<name>-<hash>.txt`, the hash
    /// taken from the whole URL, so two lists whose URLs end in the same name (`…/a/filters.txt`,
    /// `…/b/filters.txt`) never share a file.
    public static func fileName(forList string: String) -> String? {
        guard let name = stem(forList: string) else { return nil }
        if PaddleConfig.defaultFilterLists.contains(string) { return "\(name).txt" }
        let hash = SHA256.hash(data: Data(string.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(name)-\(hash).txt"
    }

    /// The last path component of an https list URL without its extension, or nil for anything else. The
    /// component is percent-decoded, so `/`, `:` and leading dots are removed to keep it one safe file name.
    private static func stem(forList string: String) -> String? {
        guard let url = URL(string: string), url.scheme == "https" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let safe = String(name.filter { $0 != "/" && $0 != ":" && $0 != "\0" }.drop { $0 == "." })
        guard !safe.isEmpty else { return nil }
        return safe
    }

    /// Files to rename once, `(from: "annoyances.txt", to: "annoyances-1a2b3c4d.txt")`: before file names carried
    /// the URL hash, every list downloaded to `<name>.txt`. A configured list whose hashed file is missing takes
    /// its old file instead of downloading again, but only when no other configured list (a default one, or
    /// another with the same name) could have written that file. `exists` says whether a file name is present.
    public static func legacyRenames(_ lists: [String], exists: (String) -> Bool) -> [(from: String, to: String)] {
        var claims: [String: Int] = [:]
        for list in lists {
            if let name = stem(forList: list) { claims["\(name).txt", default: 0] += 1 }
        }
        var renames: [(from: String, to: String)] = []
        for list in lists {
            guard let name = stem(forList: list), let file = fileName(forList: list), file != "\(name).txt" else { continue }
            let legacy = "\(name).txt"
            guard claims[legacy] == 1, !exists(file), exists(legacy) else { continue }
            renames.append((from: legacy, to: file))
        }
        return renames
    }

    /// Whether one list last downloaded at `lastUpdated` should be fetched again.
    /// - `lastUpdated` nil (file missing): always due, even with `days` 0, so a new or never-fetched list gets blocking.
    /// - `days` 0 or less: otherwise only by hand.
    /// - A date more than a day in the future means the clock was wrong when the list was saved; refresh it.
    public static func isDue(lastUpdated: Date?, now: Date, days: Int) -> Bool {
        guard let lastUpdated else { return true }
        guard days > 0 else { return false }
        let age = now.timeIntervalSince(lastUpdated)
        if age < -86_400 { return true }
        return age >= Double(days) * 86_400
    }

    /// The configured https lists that are due, in config order. `modificationDate` gets a list's file name and
    /// returns that file's modification date, or nil when the file does not exist.
    public static func dueLists(
        _ lists: [String], now: Date, days: Int, modificationDate: (String) -> Date?
    ) -> [String] {
        lists.filter { list in
            guard let file = fileName(forList: list) else { return false }
            return isDue(lastUpdated: modificationDate(file), now: now, days: days)
        }
    }
}
