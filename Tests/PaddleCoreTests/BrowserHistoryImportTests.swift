import Foundation
@testable import PaddleCore
import SQLite3
import Testing

struct BrowserHistoryImportTests {
    let fixtureNow = Date(timeIntervalSince1970: Double(ImportFixture.unix) + 86_400)
    let instant = Date(timeIntervalSince1970: Double(ImportFixture.unix))

    // MARK: - Epochs

    @Test func epochsConvertToTheSameInstant() {
        // 2023-11-14 22:13:20 UTC in each browser's own scale.
        #expect(BrowserEpoch.chrome(microseconds: 13_344_473_600_000_000) == instant)
        #expect(BrowserEpoch.firefox(microseconds: 1_700_000_000_000_000) == instant)
        #expect(BrowserEpoch.safari(seconds: 721_692_800) == instant)
        // The scales' own zero points.
        #expect(BrowserEpoch.chrome(microseconds: 11_644_473_600_000_000) == Date(timeIntervalSince1970: 0))
        #expect(BrowserEpoch.safari(seconds: 0) == Date(timeIntervalSince1970: 978_307_200))
        #expect(BrowserEpoch.chromeMicroseconds(instant) == 13_344_473_600_000_000)
        #expect(BrowserEpoch.firefoxMicroseconds(instant) == 1_700_000_000_000_000)
    }

    // MARK: - Chrome

    @Test func readsChromeHistory() throws {
        let fixture = try ImportFixture()
        let file = try fixture.chromeHistory()
        let result = try BrowserHistoryReader.read(database: file, browser: .chrome, now: fixtureNow)
        // Newest first; the chrome:// and file: visits are counted as skipped, the 1601-dated visit as a bad date.
        #expect(result.visits == [
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant, typed: true),
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant.addingTimeInterval(-3600)),
            ImportedVisit(url: "http://example.org/b", title: "Example B", date: instant.addingTimeInterval(-7200)),
        ])
        #expect(result.skippedNotWeb == 2)
        #expect(result.skippedBadDate == 1)
        #expect(!result.truncated)
    }

    @Test func sinceNarrowsTheRead() throws {
        let fixture = try ImportFixture()
        let file = try fixture.chromeHistory()
        let result = try BrowserHistoryReader.read(
            database: file, browser: .chrome, since: instant.addingTimeInterval(-5_000), now: fixtureNow)
        #expect(result.visits.map(\.date) == [instant, instant.addingTimeInterval(-3600)])
    }

    @Test func rowCapKeepsTheNewestAndSaysSo() throws {
        let fixture = try ImportFixture()
        let file = try fixture.chromeHistory()
        let result = try BrowserHistoryReader.read(database: file, browser: .chrome, limit: 2, now: fixtureNow)
        #expect(result.visits.map(\.date) == [instant, instant.addingTimeInterval(-3600)])
        #expect(result.truncated)
        // Four web rows in all: the three good visits and the one dated 1601.
        let exact = try BrowserHistoryReader.read(database: file, browser: .chrome, limit: 4, now: fixtureNow)
        #expect(exact.visits.count == 3)
        #expect(exact.skippedBadDate == 1)
        #expect(!exact.truncated)
    }

    @Test func aReadNeverTouchesTheOriginalAndCleansUpItsCopy() throws {
        let fixture = try ImportFixture()
        let file = try fixture.chromeHistory()
        let before = try Data(contentsOf: file)
        // The copy goes in a folder of this test's own, so copies from parallel tests in the system's temporary folder don't count.
        let scratch = fixture.root.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try BrowserHistoryReader.read(database: file, browser: .chrome, now: fixtureNow, temporaryRoot: scratch)
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func readsRowsThatOnlyLiveInTheWAL() throws {
        let fixture = try ImportFixture()
        let file = try fixture.path("Library/Application Support/Google/Chrome/Default/History")
        let t = ImportFixture.chromeTime
        // The connection stays open, as Chrome's would: its newest rows are in the -wal file, not the main file.
        let open = try fixture.database(file, wal: true, [
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR)",
            "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, transition INTEGER DEFAULT 0)",
            "INSERT INTO urls (id, url, title) VALUES (1, 'https://example.com/wal', 'From the WAL')",
            "INSERT INTO visits (url, visit_time) VALUES (1, \(t))",
        ], keepOpen: true)
        defer { sqlite3_close(open) }
        #expect(FileManager.default.fileExists(atPath: file.path + "-wal"))
        let result = try BrowserHistoryReader.read(database: file, browser: .chrome, now: fixtureNow)
        #expect(result.visits.map(\.url) == ["https://example.com/wal"])
    }

    // MARK: - Firefox and Safari

    @Test func readsFirefoxHistory() throws {
        let fixture = try ImportFixture()
        let file = try fixture.firefoxHistory()
        let result = try BrowserHistoryReader.read(database: file, browser: .firefox, now: fixtureNow)
        #expect(result.visits == [
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant, typed: true),
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant.addingTimeInterval(-3600)),
            ImportedVisit(url: "http://example.org/b", title: "", date: instant.addingTimeInterval(-7200)),
        ])
        #expect(result.skippedNotWeb == 2)
    }

    @Test func readsSafariHistory() throws {
        let fixture = try ImportFixture()
        let file = try fixture.safariHistory()
        let result = try BrowserHistoryReader.read(database: file, browser: .safari, now: fixtureNow)
        #expect(result.visits == [
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant),
            ImportedVisit(url: "https://example.com/a", title: "Example A", date: instant.addingTimeInterval(-3600)),
            ImportedVisit(url: "http://example.org/b", title: "", date: instant.addingTimeInterval(-7200)),
        ])
        #expect(result.skippedNotWeb == 2)
        let recent = try BrowserHistoryReader.read(database: file, browser: .safari, since: instant.addingTimeInterval(-60), now: fixtureNow)
        #expect(recent.visits.count == 1)
    }

    // MARK: - Failures

    @Test func aMissingFileIsReportedAsMissing() throws {
        let fixture = try ImportFixture()
        let file = fixture.home.appending(path: "nothing/History")
        #expect(throws: BrowserImportError.missing("Google Chrome's History")) {
            try BrowserHistoryReader.read(database: file, browser: .chrome)
        }
    }

    @Test func aFileThatIsNotADatabaseIsUnreadableNotACrash() throws {
        let fixture = try ImportFixture()
        let file = try fixture.write("this is not sqlite, just a long enough line of text to fill a page header......", to: "History")
        #expect(throws: BrowserImportError.self) { try BrowserHistoryReader.read(database: file, browser: .chrome) }
    }

    @Test func aDatabaseWithOtherTablesIsUnreadable() throws {
        let fixture = try ImportFixture()
        let file = try fixture.path("other.sqlite")
        try fixture.database(file, ["CREATE TABLE things (id INTEGER)"])
        #expect(throws: BrowserImportError.self) { try BrowserHistoryReader.read(database: file, browser: .firefox) }
    }

    @Test func aProtectedFileSaysSoPlainly() throws {
        let fixture = try ImportFixture()
        let file = try fixture.safariHistory()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        // As root nothing is protected; skip rather than fail there.
        guard !FileManager.default.isReadableFile(atPath: file.path) else { return }
        do {
            _ = try BrowserHistoryReader.read(database: file, browser: .safari)
            Issue.record("expected the read to fail")
        } catch {
            #expect(error as? BrowserImportError == .accessDenied(.safari))
            #expect(error.localizedDescription == "Safari's history is protected by macOS. To import it, allow Paddle in System Settings > Privacy & Security > Full Disk Access, or export bookmarks from Safari as HTML.")
        }
    }

    // MARK: - HistoryStore.importVisits

    @Test func importAddsVisitsWithTheirDatesAndPageCounts() throws {
        let fixture = try ImportFixture()
        let store = try HistoryStore(path: ":memory:")
        let read = try BrowserHistoryReader.read(database: fixture.chromeHistory(), browser: .chrome, now: fixtureNow)
        let summary = try store.importVisits(read.visits)
        #expect(summary == HistoryImportSummary(added: 3))
        #expect(store.pageCount == 2)
        let visits = try store.visits(matching: nil, limit: 10)
        #expect(visits.map(\.date) == [instant, instant.addingTimeInterval(-3600), instant.addingTimeInterval(-7200)])
        let pages = try store.recentPages(limit: 10)
        let a = try #require(pages.first { $0.url == "https://example.com/a" })
        #expect(a.visitCount == 2)
        #expect(a.typedCount == 1)
        #expect(a.lastVisit == instant)
        #expect(a.title == "Example A")
    }

    @Test func importingTheSameVisitsTwiceAddsNothing() throws {
        let fixture = try ImportFixture()
        let store = try HistoryStore(path: ":memory:")
        let read = try BrowserHistoryReader.read(database: fixture.firefoxHistory(), browser: .firefox, now: fixtureNow)
        _ = try store.importVisits(read.visits)
        // A second read of the same file gives equal dates, so every visit is a duplicate.
        let again = try BrowserHistoryReader.read(database: fixture.firefoxHistory(at: "copy/places.sqlite"), browser: .firefox, now: fixtureNow)
        let summary = try store.importVisits(again.visits)
        #expect(summary == HistoryImportSummary(duplicates: 3))
        #expect(try store.visits(matching: nil, limit: 10).count == 3)
        #expect(try store.recentPages(limit: 10).first { $0.url == "https://example.com/a" }?.visitCount == 2)
    }

    @Test func duplicatesAreSkippedAgainstVisitsPaddleRecorded() throws {
        let store = try HistoryStore(path: ":memory:")
        try store.recordVisit(url: URL(string: "https://example.com/a")!, title: "Mine", typed: false, at: instant)
        let summary = try store.importVisits([
            ImportedVisit(url: "https://example.com/a", title: "Theirs", date: instant),
            ImportedVisit(url: "https://example.com/a", title: "Older", date: instant.addingTimeInterval(-60)),
        ])
        #expect(summary.duplicates == 1)
        #expect(summary.added == 1)
        // The newer visit keeps its title.
        #expect(try store.recentPages(limit: 1).first?.title == "Mine")
    }

    @Test func importedVisitsFollowTheRecordingRules() throws {
        let store = try HistoryStore(path: ":memory:")
        let cutoff = instant.addingTimeInterval(-86_400)
        let summary = try store.importVisits([
            ImportedVisit(url: "https://user:secret@example.com/a#access_token=abc", title: "A", date: instant),
            ImportedVisit(url: "ftp://example.com/file", title: "FTP", date: instant),
            ImportedVisit(url: "chrome://settings", title: "Settings", date: instant),
            ImportedVisit(url: "not a url", title: "?", date: instant),
            ImportedVisit(url: "https://example.com/old", title: "Old", date: cutoff.addingTimeInterval(-1)),
            ImportedVisit(url: "https://example.com/edge", title: "Edge", date: cutoff),
        ], notBefore: cutoff)
        #expect(summary == HistoryImportSummary(added: 2, notRecordable: 3, beforeRetention: 1))
        #expect(Set(try store.recentPages(limit: 10).map(\.url)) == ["https://example.com/a", "https://example.com/edge"])
    }

    @Test func importedOldVisitFillsAnEmptyTitleButNeverReplacesANewerOne() throws {
        let store = try HistoryStore(path: ":memory:")
        try store.recordVisit(url: URL(string: "https://example.com/blank")!, title: "", typed: false, at: instant)
        _ = try store.importVisits([
            ImportedVisit(url: "https://example.com/blank", title: "Filled in", date: instant.addingTimeInterval(-100)),
            ImportedVisit(url: "https://example.com/new", title: "Newest", date: instant),
            ImportedVisit(url: "https://example.com/new", title: "Older title", date: instant.addingTimeInterval(-100)),
        ])
        let pages = try store.recentPages(limit: 10)
        #expect(pages.first { $0.url == "https://example.com/blank" }?.title == "Filled in")
        #expect(pages.first { $0.url == "https://example.com/new" }?.title == "Newest")
        #expect(pages.first { $0.url == "https://example.com/new" }?.visitCount == 2)
        #expect(pages.first { $0.url == "https://example.com/new" }?.lastVisit == instant)
    }

    @Test func aBigBatchImportsInOneGo() throws {
        let store = try HistoryStore(path: ":memory:")
        let visits = (0..<20_000).map { n in
            ImportedVisit(url: "https://example.com/page/\(n % 5_000)", title: "Page \(n % 5_000)", date: instant.addingTimeInterval(Double(-n)))
        }
        let summary = try store.importVisits(visits)
        #expect(summary.added == 20_000)
        #expect(store.pageCount == 5_000)
        #expect(try store.countVisits(olderThan: instant.addingTimeInterval(1)) == 20_000)
    }

    @Test func aFailedImportRollsBack() throws {
        let fixture = try ImportFixture()
        let file = fixture.home.appending(path: "history.sqlite")
        let store = try HistoryStore(path: file.path)
        // A trigger that refuses one title makes the third insert fail inside the transaction.
        try fixture.database(file, wal: false, [
            "CREATE TRIGGER refuse BEFORE INSERT ON visits WHEN new.title = 'boom' BEGIN SELECT RAISE(ABORT, 'refused'); END",
        ])
        #expect(throws: HistoryStore.Error.self) {
            try store.importVisits([
                ImportedVisit(url: "https://example.com/1", title: "one", date: instant),
                ImportedVisit(url: "https://example.com/2", title: "two", date: instant),
                ImportedVisit(url: "https://example.com/3", title: "boom", date: instant),
            ])
        }
        #expect(store.pageCount == 0)
        #expect(try store.visits(matching: nil, limit: 10).isEmpty)
        // The store is still usable afterwards.
        let summary = try store.importVisits([ImportedVisit(url: "https://example.com/1", title: "one", date: instant)])
        #expect(summary.added == 1)
    }
}
