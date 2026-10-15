import Foundation
@testable import PaddleCore
import Testing

struct HistoryStoreTests {
    let now = Date(timeIntervalSince1970: 10_000_000)

    func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func url(_ string: String) -> URL { URL(string: string)! }

    func store() throws -> HistoryStore { try HistoryStore(path: ":memory:") }

    @Test func countsVisitsPruneWouldDelete() throws {
        let store = try store()
        #expect(try store.countVisits(olderThan: now) == 0)
        try store.recordVisit(url: url("https://example.com/a"), title: "A", typed: false, at: ago(days: 10))
        try store.recordVisit(url: url("https://example.com/b"), title: "B", typed: false, at: ago(days: 3))
        try store.recordVisit(url: url("https://example.com/b"), title: "B", typed: false, at: ago(days: 1))
        #expect(try store.countVisits(olderThan: ago(days: 2)) == 2)
        #expect(try store.countVisits(olderThan: ago(days: 10)) == 0) // strictly before, like prune
        #expect(try store.countVisits(olderThan: now) == 3)
        try store.prune(olderThan: ago(days: 2))
        #expect(try store.countVisits(olderThan: now) == 1)
    }

    @Test func topSitesRanksOneEntryPerHost() throws {
        let store = try store()
        for _ in 0..<3 { try store.recordVisit(url: url("https://www.busy.test/home"), title: "Busy Home", typed: false, at: ago(days: 1)) }
        try store.recordVisit(url: url("https://busy.test/other"), title: "Other", typed: false, at: ago(days: 2))
        try store.recordVisit(url: url("https://quiet.test/"), title: "Quiet", typed: false, at: ago(days: 2))
        try store.recordVisit(url: url("https://old.test/"), title: "Old", typed: false, at: ago(days: 40))
        try store.recordVisit(url: url("https://skip.test/"), title: "Skip", typed: true, at: ago(days: 1))
        try store.recordVisit(url: url("ftp://files.test/"), title: "Files", typed: true, at: ago(days: 1))
        let top = try store.topSites(limit: 10, days: 30, now: now, excludingHosts: ["skip.test"])
        // A site stands for its front page; it carries the front page's title only when that was visited.
        #expect(top.map(\.title) == ["busy.test", "Quiet"])
        #expect(top.map(\.url) == ["https://www.busy.test/", "https://quiet.test/"])
        #expect(try store.topSites(limit: 1, days: 30, now: now, excludingHosts: []).count == 1)
        #expect(try store.topSites(limit: 10, days: 60, now: now, excludingHosts: ["skip.test"]).count == 3)
        #expect(try store.topSites(limit: 0, days: 30, now: now, excludingHosts: []).isEmpty)
    }

    @Test func topSitesKeepThePortAndSkipQueries() throws {
        let store = try store()
        try store.recordVisit(url: url("http://127.0.0.1:8765/notify.html"), title: "notify test", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://accounts.example.test/ServiceLogin?continue=x"), title: "Redirecting", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://accounts.example.test/?from=mail"), title: "Inbox link", typed: false, at: ago(days: 2))
        let top = try store.topSites(limit: 10, days: 30, now: now, excludingHosts: [])
        #expect(Set(top.map(\.url)) == ["http://127.0.0.1:8765/", "https://accounts.example.test/"])
        #expect(Set(top.map(\.title)) == ["127.0.0.1", "accounts.example.test"])
    }

    @Test func recordUpsertsPageAndCounts() throws {
        let store = try store()
        try store.recordVisit(url: url("https://example.com/a"), title: "Alpha", typed: true, at: ago(days: 2))
        try store.recordVisit(url: url("https://example.com/a"), title: "", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://example.com/a"), title: "Alpha 2", typed: false, at: ago(days: 0))
        #expect(store.pageCount == 1)
        let page = try #require(try store.recentPages(limit: 5).first)
        #expect(page.url == "https://example.com/a")
        #expect(page.title == "Alpha 2")
        #expect(page.visitCount == 3)
        #expect(page.typedCount == 1)
        #expect(page.lastVisit == ago(days: 0))
        #expect(try store.visits(matching: nil, limit: 10).count == 3)
    }

    @Test func hostPrefixOutranksBusierPages() throws {
        let store = try store()
        for n in 0..<40 {
            try store.recordVisit(url: url("https://duckduckgo.com/?q=thing\(n)"), title: "Search \(n)", typed: true, at: ago(days: 0))
        }
        try store.recordVisit(url: url("https://www.stackoverflow.com/questions"), title: "Questions", typed: false, at: ago(days: 8))
        let results = try store.search("st", limit: 5, now: now)
        #expect(results.first?.url == "https://www.stackoverflow.com/questions")
    }

    @Test func schemeDoesNotMatch() throws {
        let store = try store()
        try store.recordVisit(url: url("https://example.com/"), title: "Example", typed: false, at: ago(days: 0))
        #expect(try store.search("https", limit: 5, now: now).isEmpty)
        #expect(try store.visits(matching: "http", limit: 5).isEmpty)
        #expect(try store.search("example.com", limit: 5, now: now).count == 1)
    }

    @Test func credentialsAndTokensAreNotStored() throws {
        let store = try store()
        try store.recordVisit(url: url("https://me:secret@example.com/app#access_token=abc"), title: "App", typed: false, at: ago(days: 0))
        try store.recordVisit(url: url("https://example.com/docs#install"), title: "Docs", typed: false, at: ago(days: 0))
        let urls = try store.recentPages(limit: 5).map(\.url)
        #expect(urls.contains("https://example.com/app"))
        #expect(urls.contains("https://example.com/docs#install"))
        #expect(!urls.joined().contains("secret"))
    }

    @Test func partialClearRestoresEarlierTitle() throws {
        let store = try store()
        try store.recordVisit(url: url("https://example.com/"), title: "Old title", typed: false, at: ago(days: 3))
        try store.recordVisit(url: url("https://example.com/"), title: "Embarrassing title", typed: false, at: ago(days: 0))
        try store.removeVisits(since: ago(days: 1))
        #expect(try store.recentPages(limit: 1).first?.title == "Old title")
    }

    @Test func emptyTitleKeepsExistingTitle() throws {
        let store = try store()
        try store.recordVisit(url: url("https://example.com/"), title: "Home", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://example.com/"), title: "", typed: false, at: ago(days: 0))
        #expect(try store.recentPages(limit: 1).first?.title == "Home")
        #expect(try store.visits(matching: nil, limit: 1).first?.title == "Home")
    }

    @Test func typedPageOutranksMerelyVisited() throws {
        let store = try store()
        try store.recordVisit(url: url("https://visited.example/"), title: "Site", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://visited.example/"), title: "Site", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://typed.example/"), title: "Site", typed: true, at: ago(days: 1))
        let results = try store.search("site", limit: 10, now: now)
        #expect(results.map(\.url) == ["https://typed.example/", "https://visited.example/"])
    }

    @Test func recentPageOutranksOldOne() throws {
        let store = try store()
        try store.recordVisit(url: url("https://old.example/"), title: "Docs", typed: false, at: ago(days: 100))
        try store.recordVisit(url: url("https://new.example/"), title: "Docs", typed: false, at: ago(days: 1))
        let results = try store.search("docs", limit: 10, now: now)
        #expect(results.map(\.url) == ["https://new.example/", "https://old.example/"])
    }

    @Test func equalScoresBreakTieByLastVisit() throws {
        let store = try store()
        try store.recordVisit(url: url("https://a.example/"), title: "Tie", typed: false, at: ago(days: 3))
        try store.recordVisit(url: url("https://b.example/"), title: "Tie", typed: false, at: ago(days: 1))
        #expect(try store.search("tie", limit: 10, now: now).map(\.url) == ["https://b.example/", "https://a.example/"])
    }

    @Test func emptyQueryReturnsTopFrecencyWithinLimit() throws {
        let store = try store()
        try store.recordVisit(url: url("https://one.example/"), title: "One", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://two.example/"), title: "Two", typed: true, at: ago(days: 1))
        try store.recordVisit(url: url("https://three.example/"), title: "Three", typed: false, at: ago(days: 200))
        #expect(try store.search("  ", limit: 2, now: now).map(\.url) == ["https://two.example/", "https://one.example/"])
        #expect(try store.search("", limit: 0, now: now).isEmpty)
    }

    @Test func everyWordMustMatchTitleOrURLCaseInsensitively() throws {
        let store = try store()
        try store.recordVisit(url: url("https://swift.org/documentation"), title: "The Swift Language", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://example.com/swift"), title: "Cooking", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://example.com/other"), title: "Other", typed: false, at: ago(days: 1))
        // "LANGUAGE" is only in the first title, "documentation" only in its URL.
        #expect(try store.search("LANGUAGE documentation", limit: 10, now: now).map(\.url) == ["https://swift.org/documentation"])
        // "swift" matches the first title and the second URL.
        #expect(try store.search("swift", limit: 10, now: now).count == 2)
        #expect(try store.search("swift cooking", limit: 10, now: now).map(\.url) == ["https://example.com/swift"])
        #expect(try store.search("swift nowhere", limit: 10, now: now).isEmpty)
    }

    @Test func likeWildcardsAreEscaped() throws {
        let store = try store()
        try store.recordVisit(url: url("https://shop.example/sale?off=100%25"), title: "Sale 100% off", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://shop.example/1000"), title: "Thousand", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://shop.example/a_b"), title: "Underscore", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://shop.example/axb"), title: "Letter", typed: false, at: ago(days: 1))
        #expect(try store.search("100%", limit: 10, now: now).map(\.title) == ["Sale 100% off"])
        #expect(try store.search("a_b", limit: 10, now: now).map(\.title) == ["Underscore"])
        #expect(try store.search("%", limit: 10, now: now).map(\.title) == ["Sale 100% off"])
        #expect(try store.search("\\", limit: 10, now: now).isEmpty)
    }

    @Test func nonWebURLsAreIgnored() throws {
        let store = try store()
        let ignored = ["about:blank", "data:text/html,hi", "blob:https://example.com/x", "file:///tmp/a.html",
                       "javascript:alert(1)", "paddle://settings", "ftp://example.com/"]
        for string in ignored {
            #expect(!HistoryStore.isRecordable(url(string)))
            try store.recordVisit(url: url(string), title: "x", typed: true, at: now)
        }
        #expect(store.pageCount == 0)
        #expect(try store.visits(matching: nil, limit: 10).isEmpty)
        #expect(HistoryStore.isRecordable(url("http://example.com")))
        #expect(HistoryStore.isRecordable(url("HTTPS://example.com")))
    }

    @Test func updateTitleChangesPageAndLatestVisitOnly() throws {
        let store = try store()
        let page = url("https://example.com/p")
        try store.recordVisit(url: page, title: "Old", typed: false, at: ago(days: 2))
        try store.recordVisit(url: page, title: "", typed: false, at: ago(days: 1))
        try store.updateTitle(url: page, title: "Fresh")
        #expect(try store.recentPages(limit: 1).first?.title == "Fresh")
        #expect(try store.visits(matching: nil, limit: 10).map(\.title) == ["Fresh", "Old"])
        try store.updateTitle(url: page, title: "")
        #expect(try store.recentPages(limit: 1).first?.title == "Fresh")
    }

    @Test func visitsAreNewestFirstWithQueryAndPaging() throws {
        let store = try store()
        for day in 1...5 {
            try store.recordVisit(url: url("https://news.example/\(day)"), title: "News \(day)", typed: false, at: ago(days: Double(10 - day)))
        }
        try store.recordVisit(url: url("https://other.example/"), title: "Other", typed: false, at: ago(days: 0))
        #expect(try store.visits(matching: nil, limit: 10).first?.title == "Other")
        let news = try store.visits(matching: "news", limit: 10)
        #expect(news.map(\.title) == ["News 5", "News 4", "News 3", "News 2", "News 1"])
        #expect(try store.visits(matching: "news", limit: 2, offset: 1).map(\.title) == ["News 4", "News 3"])
        #expect(try store.visits(matching: "news", limit: 2, offset: 4).map(\.title) == ["News 1"])
        #expect(try store.visits(matching: "other.example", limit: 10).count == 1)
        #expect(try store.visits(matching: "", limit: 100).count == 6)
    }

    @Test func recentPagesAreDistinctNewestFirst() throws {
        let store = try store()
        try store.recordVisit(url: url("https://a.example/"), title: "A", typed: false, at: ago(days: 5))
        try store.recordVisit(url: url("https://b.example/"), title: "B", typed: false, at: ago(days: 4))
        try store.recordVisit(url: url("https://a.example/"), title: "A", typed: false, at: ago(days: 3))
        try store.recordVisit(url: url("https://c.example/"), title: "C", typed: false, at: ago(days: 2))
        let recent = try store.recentPages(limit: 10)
        #expect(recent.map(\.url) == ["https://c.example/", "https://a.example/", "https://b.example/"])
        #expect(try store.recentPages(limit: 2).count == 2)
    }

    @Test func removeVisitsSinceRecomputesCountsAndDeletesEmptyPages() throws {
        let store = try store()
        let both = url("https://both.example/")
        let recentOnly = url("https://recent.example/")
        try store.recordVisit(url: both, title: "Both", typed: true, at: ago(days: 10))
        try store.recordVisit(url: both, title: "Both", typed: false, at: ago(days: 2))
        try store.recordVisit(url: both, title: "Both", typed: true, at: ago(days: 1))
        try store.recordVisit(url: recentOnly, title: "Recent", typed: false, at: ago(days: 1))
        try store.removeVisits(since: ago(days: 3))
        #expect(store.pageCount == 1)
        let page = try #require(try store.recentPages(limit: 5).first)
        #expect(page.url == both.absoluteString)
        #expect(page.visitCount == 1)
        #expect(page.typedCount == 1)
        #expect(page.lastVisit == ago(days: 10))
        #expect(try store.visits(matching: nil, limit: 10).count == 1)
    }

    @Test func removeVisitsKeepsUntouchedPagesAsTheyWere() throws {
        let store = try store()
        try store.recordVisit(url: url("https://old.example/"), title: "Old", typed: true, at: ago(days: 30))
        try store.recordVisit(url: url("https://old.example/"), title: "Old", typed: false, at: ago(days: 20))
        try store.removeVisits(since: ago(days: 5))
        let page = try #require(try store.recentPages(limit: 5).first)
        #expect(page.visitCount == 2)
        #expect(page.typedCount == 1)
        #expect(page.lastVisit == ago(days: 20))
    }

    @Test func pruneDropsOldVisitsThenEmptyPages() throws {
        let store = try store()
        try store.recordVisit(url: url("https://ancient.example/"), title: "Ancient", typed: false, at: ago(days: 400))
        try store.recordVisit(url: url("https://mixed.example/"), title: "Mixed", typed: false, at: ago(days: 300))
        try store.recordVisit(url: url("https://mixed.example/"), title: "Mixed", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://fresh.example/"), title: "Fresh", typed: false, at: ago(days: 2))
        try store.prune(olderThan: ago(days: 200))
        #expect(store.pageCount == 2)
        #expect(Set(try store.recentPages(limit: 10).map(\.url)) == ["https://mixed.example/", "https://fresh.example/"])
        #expect(try store.visits(matching: nil, limit: 10).count == 2)
    }

    @Test func removeDeletesOnePageAndItsVisits() throws {
        let store = try store()
        try store.recordVisit(url: url("https://keep.example/"), title: "Keep", typed: false, at: ago(days: 1))
        try store.recordVisit(url: url("https://drop.example/"), title: "Drop", typed: false, at: ago(days: 2))
        try store.recordVisit(url: url("https://drop.example/"), title: "Drop", typed: false, at: ago(days: 1))
        try store.remove(url: "https://drop.example/")
        #expect(store.pageCount == 1)
        #expect(try store.visits(matching: nil, limit: 10).map(\.url) == ["https://keep.example/"])
    }

    @Test func removeAllEmptiesTheStore() throws {
        let store = try store()
        try store.recordVisit(url: url("https://a.example/"), title: "A", typed: true, at: ago(days: 1))
        try store.recordVisit(url: url("https://b.example/"), title: "B", typed: false, at: ago(days: 1))
        try store.removeAll()
        #expect(store.pageCount == 0)
        #expect(try store.visits(matching: nil, limit: 10).isEmpty)
        #expect(try store.search("", limit: 10, now: now).isEmpty)
    }

    @Test func fileBackedStoreReopensWithItsData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaddleHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        do {
            let store = try HistoryStore(path: path)
            try store.recordVisit(url: url("https://example.com/kept"), title: "Kept", typed: true, at: ago(days: 1))
        }
        let reopened = try HistoryStore(path: path)
        #expect(reopened.pageCount == 1)
        let hit = try #require(try reopened.search("kept", limit: 5, now: now).first)
        #expect(hit.url == "https://example.com/kept")
        #expect(hit.typedCount == 1)
        try reopened.recordVisit(url: url("https://example.com/kept"), title: "Kept", typed: false, at: ago(days: 0))
        #expect(try reopened.recentPages(limit: 1).first?.visitCount == 2)
    }

    /// Retention must not leave aged-out pages readable in the write-ahead log, the same as clearing history.
    @Test func pruneScrubsTheWriteAheadLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaddleHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let marker = "agedoutmarker7319"

        let store = try HistoryStore(path: path)
        try store.recordVisit(url: url("https://\(marker).example/"), title: marker, typed: false, at: ago(days: 400))
        try store.recordVisit(url: url("https://fresh.example/"), title: "Fresh", typed: false, at: ago(days: 1))
        try store.prune(olderThan: ago(days: 200))
        #expect(store.pageCount == 1)

        let wal = (try? Data(contentsOf: URL(fileURLWithPath: path + "-wal"))) ?? Data()
        #expect(wal.isEmpty)
        for file in [path, path + "-wal"] {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
            #expect(bytes.range(of: Data(marker.utf8)) == nil, "\(file) still holds the pruned page")
        }
    }

    @Test func unopenablePathThrows() {
        #expect(throws: HistoryStore.Error.self) {
            _ = try HistoryStore(path: "/nonexistent-directory-for-paddle-tests/history.sqlite")
        }
    }

    @Test func frecencyBucketsByAge() {
        func score(_ days: Double, visits: Int = 1, typed: Int = 0) -> Double {
            Frecency.score(visitCount: visits, typedCount: typed, lastVisit: ago(days: days), now: now)
        }
        #expect(score(0) == 100)
        #expect(score(4) == 100)
        #expect(score(5) == 70)
        #expect(score(14) == 70)
        #expect(score(20) == 50)
        #expect(score(31) == 50)
        #expect(score(60) == 30)
        #expect(score(90) == 30)
        #expect(score(200) == 10)
        #expect(score(1, visits: 2, typed: 1) == 400)
        // A visit dated in the future counts as brand new.
        #expect(Frecency.score(visitCount: 1, typedCount: 0, lastVisit: now.addingTimeInterval(3600), now: now) == 100)
    }
}
