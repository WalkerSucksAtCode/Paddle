import Foundation
import SQLite3

/// What a history database held, ready for `HistoryStore.importVisits`.
public struct HistoryReadResult: Sendable, Equatable {
    /// Web visits, newest first.
    public var visits: [ImportedVisit]
    /// Visits to addresses that aren't http(s): `chrome://`, `about:`, `file:`, `place:`, extension pages.
    public var skippedNotWeb = 0
    /// Visits with no usable date (before 1990, or more than a day ahead).
    public var skippedBadDate = 0
    /// The database held more web visits than the row cap, or than `since` reached back to; only the newest are here.
    public var truncated = false

    public init(visits: [ImportedVisit] = [], skippedNotWeb: Int = 0, skippedBadDate: Int = 0, truncated: Bool = false) {
        self.visits = visits
        self.skippedNotWeb = skippedNotWeb
        self.skippedBadDate = skippedBadDate
        self.truncated = truncated
    }
}

/// Seconds since 1970 for each browser's own time scale.
public enum BrowserEpoch {
    /// Chrome (WebKit time): microseconds since 1601-01-01 UTC.
    public static func chrome(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    /// Firefox (PRTime): microseconds since 1970-01-01 UTC.
    public static func firefox(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    /// Safari (Core Data): seconds since 2001-01-01 UTC.
    public static func safari(seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// The inverse of `chrome(microseconds:)`, for a `since` bound.
    static func chromeMicroseconds(_ date: Date) -> Int64 {
        Int64(((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000).rounded(.down))
    }

    static func firefoxMicroseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
    }
}

/// Another browser's history DB. Each format is a separate query, from the browsers' schemas:
///
/// - Chrome `History`: `urls(id, url, title)` and `visits(url → urls.id, visit_time, transition)`; `visit_time` is
///   microseconds since 1601-01-01 UTC, and `transition & 0xFF == 1` is a typed address.
/// - Firefox `places.sqlite`: `moz_places(id, url, title)` and `moz_historyvisits(place_id → moz_places.id,
///   visit_date, visit_type)`; `visit_date` is microseconds since 1970 (PRTime), and `visit_type == 2` is typed.
/// - Safari `History.db`: `history_items(id, url)` and `history_visits(history_item → history_items.id,
///   visit_time, title)`; `visit_time` is seconds since 2001-01-01 (Core Data) and the title lives on the visit.
///
/// The browser may be running and holding its database open, so a copy (the file and its `-wal` / `-shm`) goes to a
/// temporary folder and is opened read-only; the copy is deleted when the read ends.
public enum BrowserHistoryReader {
    public static let defaultRowCap = 200_000

    public static func read(
        _ source: ImportSource, limit: Int = defaultRowCap, since: Date? = nil, now: Date = Date()
    ) throws -> HistoryReadResult {
        try read(database: source.historyFile, browser: source.browser, limit: limit, since: since, now: now)
    }

    /// `temporaryRoot` is where the copy's folder is made (the app uses the system's temporary folder).
    public static func read(
        database: URL, browser: ImportSource.Browser, limit: Int = defaultRowCap, since: Date? = nil, now: Date = Date(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> HistoryReadResult {
        guard limit > 0 else { return HistoryReadResult() }
        return try ImportSQLite.withCopy(of: database, browser: browser, what: "history database", temporaryRoot: temporaryRoot) { db in
            try query(db, browser.family, limit: limit, since: since, now: now)
        }
    }

    /// EPERM and EACCES anywhere in the error chain: macOS refusing a protected folder, or plain file permissions.
    static func isPermissionDenied(_ error: any Error) -> Bool { ImportSQLite.isPermissionDenied(error) }

    // MARK: - Query

    private static func query(
        _ db: OpaquePointer, _ family: ImportSource.Family, limit: Int, since: Date?, now: Date
    ) throws -> HistoryReadResult {
        let spec: Spec
        let lowerBound: Bind
        switch family {
        case .chromium:
            spec = Spec(
                from: "visits v JOIN urls u ON u.id = v.url", time: "v.visit_time", url: "u.url", title: "u.title",
                typed: "(v.transition & 255) = 1")
            lowerBound = .int(since.map(BrowserEpoch.chromeMicroseconds) ?? 0)
        case .firefox:
            spec = Spec(
                from: "moz_historyvisits v JOIN moz_places u ON u.id = v.place_id", time: "v.visit_date", url: "u.url",
                title: "u.title", typed: "v.visit_type = 2")
            lowerBound = .int(since.map(BrowserEpoch.firefoxMicroseconds) ?? 0)
        case .safari:
            spec = Spec(
                from: "history_visits v JOIN history_items u ON u.id = v.history_item", time: "v.visit_time", url: "u.url",
                title: "v.title", typed: "0")
            lowerBound = .double(since?.timeIntervalSinceReferenceDate ?? -1e15)
        }

        let isWeb = "(u.url LIKE 'http://%' OR u.url LIKE 'https://%')"
        var result = HistoryReadResult()
        do {
            let notWeb = try ImportSQLite.run(db, "SELECT count(*) FROM \(spec.from) WHERE \(spec.time) >= ? AND NOT \(isWeb)", [lowerBound]) {
                Int(ImportSQLite.int($0, 0))
            }
            result.skippedNotWeb = notWeb.first ?? 0

            // One row past the cap tells whether anything was left out.
            let rows = try ImportSQLite.run(db, """
                SELECT \(spec.url), \(spec.title), \(spec.time), \(spec.typed) FROM \(spec.from)
                WHERE \(spec.time) >= ? AND \(isWeb) ORDER BY \(spec.time) DESC LIMIT ?
                """, [lowerBound, .int(Int64(limit) + 1)]) { stmt -> (String, String, Date, Bool) in
                let date: Date = switch family {
                case .chromium: BrowserEpoch.chrome(microseconds: sqlite3_column_int64(stmt, 2))
                case .firefox: BrowserEpoch.firefox(microseconds: sqlite3_column_int64(stmt, 2))
                case .safari: BrowserEpoch.safari(seconds: sqlite3_column_double(stmt, 2))
                }
                return (ImportSQLite.text(stmt, 0), ImportSQLite.text(stmt, 1), date, sqlite3_column_int64(stmt, 3) != 0)
            }
            result.truncated = rows.count > limit
            let earliest = Date(timeIntervalSince1970: 631_152_000) // 1 Jan 1990
            let latest = now.addingTimeInterval(86_400)
            for (url, title, date, typed) in rows.prefix(limit) {
                guard URL(string: url).map(HistoryStore.isRecordable) == true else {
                    result.skippedNotWeb += 1
                    continue
                }
                guard date >= earliest, date <= latest else {
                    result.skippedBadDate += 1
                    continue
                }
                result.visits.append(ImportedVisit(url: url, title: title, date: date, typed: typed))
            }
        } catch let error as ImportSQLite.Failure {
            throw BrowserImportError.unreadable("This doesn't look like a readable history database (\(error.message)).")
        }
        return result
    }

    private struct Spec {
        var from: String
        var time: String
        var url: String
        var title: String
        var typed: String
    }

    private typealias Bind = ImportSQLite.Bind
}
