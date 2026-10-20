import Foundation
@testable import PaddleCore
import Testing

struct FilterUpdatePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    let easyList = "https://easylist.to/easylist/easylist.txt"
    let easyPrivacy = "https://easylist.to/easylist/easyprivacy.txt"
    let added = "https://example.com/lists/annoyances.txt"

    @Test func neverDownloadedIsAlwaysDue() {
        #expect(FilterUpdatePolicy.isDue(lastUpdated: nil, now: now, days: 7))
        #expect(FilterUpdatePolicy.isDue(lastUpdated: nil, now: now, days: 0))
    }

    @Test func dueOnceOlderThanTheInterval() {
        #expect(!FilterUpdatePolicy.isDue(lastUpdated: daysAgo(6.9), now: now, days: 7))
        #expect(FilterUpdatePolicy.isDue(lastUpdated: daysAgo(7), now: now, days: 7))
        #expect(FilterUpdatePolicy.isDue(lastUpdated: daysAgo(30), now: now, days: 7))
        #expect(FilterUpdatePolicy.isDue(lastUpdated: daysAgo(1.5), now: now, days: 1))
        #expect(!FilterUpdatePolicy.isDue(lastUpdated: now, now: now, days: 1))
    }

    @Test func zeroOrNegativeDaysMeansOnlyByHand() {
        #expect(!FilterUpdatePolicy.isDue(lastUpdated: daysAgo(400), now: now, days: 0))
        #expect(!FilterUpdatePolicy.isDue(lastUpdated: daysAgo(400), now: now, days: -3))
    }

    @Test func futureDatesFromABadClockRefresh() {
        #expect(!FilterUpdatePolicy.isDue(lastUpdated: now.addingTimeInterval(60), now: now, days: 7))
        #expect(FilterUpdatePolicy.isDue(lastUpdated: now.addingTimeInterval(3 * 86_400), now: now, days: 7))
    }

    /// The default lists keep their old file names, so nothing already downloaded is fetched again.
    @Test func defaultListsKeepTheirOldFileNames() {
        #expect(FilterUpdatePolicy.fileName(forList: easyList) == "easylist.txt")
        #expect(FilterUpdatePolicy.fileName(forList: easyPrivacy) == "easyprivacy.txt")
        #expect(PaddleConfig.defaultFilterLists == [easyList, easyPrivacy])
    }

    /// Any other list is named from its whole URL: the same name on two hosts or paths gives two files.
    @Test func otherListsGetUniqueStableFileNames() throws {
        let a = try #require(FilterUpdatePolicy.fileName(forList: "https://example.com/a/filters.txt"))
        let b = try #require(FilterUpdatePolicy.fileName(forList: "https://example.com/b/filters.txt"))
        let c = try #require(FilterUpdatePolicy.fileName(forList: "https://other.test/a/filters.txt"))
        #expect(Set([a, b, c]).count == 3)
        #expect(a.hasPrefix("filters-") && a.hasSuffix(".txt"))
        #expect(a.count == "filters-".count + 8 + ".txt".count)
        #expect(FilterUpdatePolicy.fileName(forList: "https://example.com/a/filters.txt") == a)
        #expect(FilterUpdatePolicy.fileName(forList: "https://example.com/a/list")?.hasPrefix("list-") == true)
        // A mirror of EasyList is a different list with its own file, not the default's.
        #expect(FilterUpdatePolicy.fileName(forList: "https://mirror.test/easylist.txt") != "easylist.txt")
        #expect(FilterUpdatePolicy.fileName(forList: "http://example.com/list.txt") == nil)
        #expect(FilterUpdatePolicy.fileName(forList: "not a url") == nil)
        #expect(FilterUpdatePolicy.fileName(forList: "https://example.com/") == nil)
    }

    /// A list downloaded before names carried the hash is renamed to its new file, not fetched again; a plain
    /// name that a default list or a second same-named list could have written is left alone.
    @Test func legacyFilesAreRenamedOnceWhenTheNameIsUnambiguous() throws {
        let hashed = try #require(FilterUpdatePolicy.fileName(forList: added))
        var files: Set<String> = ["easylist.txt", "easyprivacy.txt", "annoyances.txt"]
        let renames = FilterUpdatePolicy.legacyRenames([easyList, easyPrivacy, added]) { files.contains($0) }
        #expect(renames.map(\.from) == ["annoyances.txt"])
        #expect(renames.map(\.to) == [hashed])

        files.remove("annoyances.txt"); files.insert(hashed)
        #expect(FilterUpdatePolicy.legacyRenames([easyList, easyPrivacy, added]) { files.contains($0) }.isEmpty)
        files.insert("annoyances.txt")
        #expect(FilterUpdatePolicy.legacyRenames([easyList, easyPrivacy, added]) { files.contains($0) }.isEmpty)

        // Two configured lists with the same name: neither can claim the old file.
        let twin = "https://other.test/annoyances.txt"
        files.remove(hashed)
        #expect(FilterUpdatePolicy.legacyRenames([added, twin]) { files.contains($0) }.isEmpty)
        // A mirror of EasyList never takes easylist.txt from the default.
        let mirror = "https://mirror.test/easylist.txt"
        #expect(FilterUpdatePolicy.legacyRenames([easyList, mirror]) { files.contains($0) }.isEmpty)
        #expect(FilterUpdatePolicy.legacyRenames([mirror]) { files.contains($0) }.map(\.from) == ["easylist.txt"])
    }

    /// One fresh list must not hide a stale one (e.g. EasyPrivacy failing while EasyList succeeds).
    @Test func eachListIsJudgedOnItsOwnFile() {
        let dates = ["easylist.txt": daysAgo(1), "easyprivacy.txt": daysAgo(9)]
        let due = FilterUpdatePolicy.dueLists([easyList, easyPrivacy], now: now, days: 7) { dates[$0] }
        #expect(due == [easyPrivacy])
    }

    /// A list added to config (or one whose download never succeeded) is fetched at the next check.
    @Test func missingFileIsDueEvenWhenOthersAreFresh() {
        let dates = ["easylist.txt": daysAgo(1), "easyprivacy.txt": daysAgo(1)]
        #expect(FilterUpdatePolicy.dueLists([easyList, easyPrivacy, added], now: now, days: 7) { dates[$0] } == [added])
        #expect(FilterUpdatePolicy.dueLists([easyList, easyPrivacy, added], now: now, days: 0) { dates[$0] } == [added])
        #expect(FilterUpdatePolicy.dueLists([easyList, easyPrivacy], now: now, days: 7) { dates[$0] }.isEmpty)
    }

    @Test func nonHTTPSEntriesAreNeverDue() {
        #expect(FilterUpdatePolicy.dueLists(["http://example.com/x.txt", "junk"], now: now, days: 7) { _ in nil }.isEmpty)
    }

    @Test func configDefaultsToWeekly() throws {
        #expect(PaddleConfig().filterUpdateDays == 7)
        #expect(try PaddleConfig.decode(Data("{}".utf8)).filterUpdateDays == 7)
        #expect(try PaddleConfig.decode(Data(#"{"filterUpdateDays": 0}"#.utf8)).filterUpdateDays == 0)
    }

    @Test func fileNameIsOneSafePathComponent() throws {
        for list in ["https://x.com/..%2F..%2Fevil.txt", "https://x.com/a%2Fb.txt", "https://x.com/%2E%2Ehidden.txt"] {
            let name = try #require(FilterUpdatePolicy.fileName(forList: list))
            #expect(!name.contains("/") && !name.contains(":") && !name.hasPrefix("."))
        }
        #expect(FilterUpdatePolicy.fileName(forList: easyList) == "easylist.txt")
        #expect(FilterUpdatePolicy.fileName(forList: easyPrivacy) == "easyprivacy.txt")
        #expect(FilterUpdatePolicy.fileName(forList: added)?.hasPrefix("annoyances-") == true)
    }
}
