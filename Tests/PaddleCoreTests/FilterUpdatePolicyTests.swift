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

    @Test func fileNameFollowsTheURL() {
        #expect(FilterUpdatePolicy.fileName(forList: easyList) == "easylist.txt")
        #expect(FilterUpdatePolicy.fileName(forList: "https://example.com/a/list") == "list.txt")
        #expect(FilterUpdatePolicy.fileName(forList: "http://example.com/list.txt") == nil)
        #expect(FilterUpdatePolicy.fileName(forList: "not a url") == nil)
        #expect(FilterUpdatePolicy.fileName(forList: "https://example.com/") == nil)
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
}
