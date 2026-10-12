import Foundation
import PaddleCore

/// What the Privacy & Blocking pane reads from disk: how many visits a shorter history would delete, which
/// files in `filters/` no list uses, and each list's state. Nothing here is kept between calls.
enum PrivacySettings {
    /// uBlock Origin's lists Settings offers to add (uAssets, the same files uBO itself uses).
    static let uBlockLists: [(title: String, url: String)] = [
        ("uBlock filters", "https://ublockorigin.github.io/uAssets/filters/filters.txt"),
        ("uBlock filters – Quick fixes", "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt"),
        ("uBlock filters – Privacy", "https://ublockorigin.github.io/uAssets/filters/privacy.txt"),
        ("uBlock filters – Unbreak", "https://ublockorigin.github.io/uAssets/filters/unbreak.txt"),
    ]

    /// Visits that keeping `days` of history deletes (`AppModel.pruneHistory` uses the same cutoff), or nil when
    /// history.sqlite can't be read. `days` 0 deletes nothing: history stops recording and the file is kept.
    static func visitsDeleted(keepingDays days: Int, now: Date = Date()) -> Int? {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        if let history = AppModel.shared.history { return try? history.countVisits(olderThan: cutoff) }
        // History is off right now: turning it back on prunes the file as it opens, so count in it too.
        guard FileManager.default.fileExists(atPath: Paths.history.path) else { return 0 }
        guard let store = try? HistoryStore(path: Paths.history.path) else { return nil }
        return try? store.countVisits(olderThan: cutoff)
    }

    /// The `.txt` files in `filters/` that none of `lists` downloads to, sorted by name. A file an old list name
    /// would still be renamed from (`FilterUpdatePolicy.legacyRenames`) counts as used.
    static func unusedListFiles(lists: [String]) -> [URL] {
        let fm = FileManager.default
        let used = Set(lists.compactMap(FilterUpdatePolicy.fileName(forList:)))
        let legacy = Set(FilterUpdatePolicy.legacyRenames(lists) { fm.fileExists(atPath: Paths.filters.appending(path: $0).path) }.map(\.from))
        let files = (try? fm.contentsOfDirectory(
            at: Paths.filters, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { file in
                file.pathExtension == "txt"
                    && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && !used.contains(file.lastPathComponent) && !legacy.contains(file.lastPathComponent)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Moves `files` to the Trash; returns a line for each one that couldn't be moved.
    static func trash(_ files: [URL]) -> [String] {
        var failures: [String] = []
        for file in files {
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    static func fileSize(_ file: URL) -> Int64? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    static func modificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// One configured list as the pane shows it. `status` is the list's line from the running block lists
    /// (`WebEnvironment.blockerStatus`, built from the `compiled-rules/` sidecars), nil until the list is applied.
    struct ListRow: Identifiable {
        var url: String
        var file: String?
        var status: String?
        var problem: String?
        var downloaded: Date?

        var id: String { url }
        var name: String { file.map { ($0 as NSString).deletingPathExtension } ?? url }
    }

    static func rows(lists: [String], blockerStatus: [String], problems: [String: String]) -> [ListRow] {
        lists.map { list in
            let file = FilterUpdatePolicy.fileName(forList: list)
            let name = file.map { ($0 as NSString).deletingPathExtension } ?? list
            return ListRow(
                url: list,
                file: file,
                status: blockerStatus.first { $0.hasPrefix("\(name): ") },
                problem: file.flatMap { problems[$0] },
                downloaded: file.flatMap { modificationDate(Paths.filters.appending(path: $0)) }
            )
        }
    }

    /// The `user-filters` line from the running block lists.
    static func userFiltersStatus(_ blockerStatus: [String]) -> String? {
        let name = Paths.userFilters.deletingPathExtension().lastPathComponent
        return blockerStatus.first { $0.hasPrefix("\(name): ") }
    }
}
