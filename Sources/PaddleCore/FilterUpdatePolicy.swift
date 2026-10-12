import Foundation

/// When downloaded filter lists are refreshed automatically (`filterUpdateDays` in config.json).
/// Each list is judged on its own file in `filters/`, so one fresh list never hides a stale, failing or new one.
public enum FilterUpdatePolicy {
    /// The file in `filters/` a list URL downloads to (`easylist.txt` for `…/easylist.txt`), or nil when the
    /// entry is not an https URL (such entries are never downloaded).
    public static func fileName(forList string: String) -> String? {
        guard let url = URL(string: string), url.scheme == "https" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return "\(name).txt"
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
