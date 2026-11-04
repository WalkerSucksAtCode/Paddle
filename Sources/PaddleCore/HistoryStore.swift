import Foundation
import SQLite3

/// One page in the history: a row per URL, with counts summed over all its visits.
public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var typedCount: Int
    public var lastVisit: Date
    public var id: String { url }

    public init(url: String, title: String, visitCount: Int, typedCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }
}

/// One visit to a page: a row per navigation, for the History window's chronological list.
public struct HistoryVisit: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var url: String
    public var title: String
    public var date: Date

    public init(id: Int64, url: String, title: String, date: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }
}

/// One visit read from another browser's history, to be added with `HistoryStore.importVisits`.
public struct ImportedVisit: Sendable, Equatable {
    public var url: String
    public var title: String
    public var date: Date
    /// The address was typed into the old browser's address bar (counts three times in frecency, as here).
    public var typed: Bool

    public init(url: String, title: String, date: Date, typed: Bool = false) {
        self.url = url
        self.title = title
        self.date = date
        self.typed = typed
    }
}

/// What `HistoryStore.importVisits` did with a batch.
public struct HistoryImportSummary: Sendable, Equatable {
    /// Visits added.
    public var added = 0
    /// Visits already in the history at the same address and instant (a second import of the same file).
    public var duplicates = 0
    /// Visits whose address is not an http(s) page.
    public var notRecordable = 0
    /// Visits older than the retention cutoff, which the next prune would delete again.
    public var beforeRetention = 0

    public init(added: Int = 0, duplicates: Int = 0, notRecordable: Int = 0, beforeRetention: Int = 0) {
        self.added = added
        self.duplicates = duplicates
        self.notRecordable = notRecordable
        self.beforeRetention = beforeRetention
    }

    public mutating func add(_ other: HistoryImportSummary) {
        added += other.added
        duplicates += other.duplicates
        notRecordable += other.notRecordable
        beforeRetention += other.beforeRetention
    }
}

/// Address-bar ranking, Firefox-style frecency:
/// `score = (visitCount + 2 * typedCount) * bucket(age of lastVisit)`.
/// Buckets: 100 ≤4 days, 70 ≤14, 50 ≤31, 30 ≤90, 10 after. A typed address counts three times a
/// link visit; recent pages outweigh old ones.
public enum Frecency {
    public static func score(visitCount: Int, typedCount: Int, lastVisit: Date, now: Date) -> Double {
        let weight = Double(max(0, visitCount) + 2 * max(0, typedCount))
        let ageDays = max(0, now.timeIntervalSince(lastVisit)) / 86_400
        let bucket: Double = switch ageDays {
        case ...4: 100
        case ...14: 70
        case ...31: 50
        case ...90: 30
        default: 10
        }
        return weight * bucket
    }
}

/// Browsing history in a SQLite database: pages (one row per URL) and visits (one row per navigation).
///
/// Owns a single `sqlite3*` connection. Not `Sendable`: use it from one actor (the main actor in the app).
/// Word matching is case-insensitive for ASCII letters only (SQLite's built-in `LIKE`).
public final class HistoryStore {
    /// A failed SQLite call, with SQLite's own message.
    public struct Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        public var code: Int32
        public var message: String
        public var description: String { "SQLite error \(code): \(message)" }
    }

    /// Schema version stored in `PRAGMA user_version`. Bump it and add a migration step in `migrate()`.
    static let schemaVersion: Int32 = 1

    private let db: OpaquePointer

    /// Opens or creates the database at `path` (`":memory:"` for a throwaway one). File databases use WAL.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close_v2(handle)
            throw Error(code: rc, message: message)
        }
        db = opened
        sqlite3_busy_timeout(db, 2_000)
        try execute("PRAGMA foreign_keys = ON")
        _ = try rows("PRAGMA secure_delete = ON", []) { _ in 0 }
        if path != ":memory:", !path.isEmpty {
            try execute("PRAGMA journal_mode = WAL")
            // SQLite's recommended WAL pairing: commits skip the fsync (an app crash still loses nothing; only an OS
            // crash or power loss can drop the latest visits). Visits and title updates commit on the main actor.
            try execute("PRAGMA synchronous = NORMAL")
        }
        try migrate()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Recording

    /// Only web pages are worth remembering: http and https.
    public static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The form a URL is stored and looked up in: without `user:password@`, and without a fragment that carries
    /// sign-in output (`#access_token=…`). Other fragments stay, since single-page sites use them as routes.
    public static func storedURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        if let fragment = parts.fragment?.lowercased(),
           ["access_token=", "id_token=", "code=", "token=", "state="].contains(where: fragment.contains) {
            parts.fragment = nil
        }
        return parts.string ?? url.absoluteString
    }

    /// Adds a visit and updates the page row. Does nothing for URLs that are not recordable.
    /// An empty `title` keeps whatever title the page already has.
    public func recordVisit(url: URL, title: String, typed: Bool, at date: Date) throws {
        guard Self.isRecordable(url) else { return }
        let address = Self.storedURL(url)
        let stamp = date.timeIntervalSince1970
        let typedValue: Int64 = typed ? 1 : 0
        try transaction {
            try execute("""
                INSERT INTO pages (url, title, visit_count, typed_count, last_visit)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT (url) DO UPDATE SET
                    visit_count = visit_count + 1,
                    typed_count = typed_count + excluded.typed_count,
                    last_visit = max(last_visit, excluded.last_visit),
                    title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE pages.title END
                """, [.text(address), .text(title), .int(typedValue), .double(stamp)])
            try execute("""
                INSERT INTO visits (page_id, date, title, typed)
                SELECT id, ?, title, ? FROM pages WHERE url = ?
                """, [.double(stamp), .int(typedValue), .text(address)])
        }
    }

    /// Adds visits from another browser with their original dates, in one transaction.
    /// - Addresses go through the same rules as `recordVisit`: only http(s), stored without credentials.
    /// - A visit already present at the same address and instant is skipped, so importing a file twice adds nothing.
    /// - Visits before `cutoff` (the retention limit) are skipped: the next prune would delete them anyway.
    /// - A page keeps the title of its newest visit: an imported visit never replaces a newer title, but fills an empty one.
    public func importVisits(_ visits: [ImportedVisit], notBefore cutoff: Date? = nil) throws -> HistoryImportSummary {
        var summary = HistoryImportSummary()
        let upsert = """
            INSERT INTO pages (url, title, visit_count, typed_count, last_visit)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT (url) DO UPDATE SET
                visit_count = visit_count + 1,
                typed_count = typed_count + excluded.typed_count,
                title = CASE WHEN excluded.title <> '' AND (pages.title = '' OR excluded.last_visit >= pages.last_visit)
                             THEN excluded.title ELSE pages.title END,
                last_visit = max(last_visit, excluded.last_visit)
            """
        let exists = "SELECT 1 FROM visits v JOIN pages p ON p.id = v.page_id WHERE p.url = ? AND v.date = ? LIMIT 1"
        let insert = "INSERT INTO visits (page_id, date, title, typed) SELECT id, ?, ?, ? FROM pages WHERE url = ?"
        try transaction {
            try withStatement(upsert, []) { upsertStatement in
                try withStatement(exists, []) { existsStatement in
                    try withStatement(insert, []) { insertStatement in
                        for visit in visits {
                            guard let url = URL(string: visit.url), Self.isRecordable(url) else {
                                summary.notRecordable += 1
                                continue
                            }
                            if let cutoff, visit.date < cutoff {
                                summary.beforeRetention += 1
                                continue
                            }
                            let address = Self.storedURL(url)
                            let stamp = visit.date.timeIntervalSince1970
                            let typed: Int64 = visit.typed ? 1 : 0
                            if try step(existsStatement, [.text(address), .double(stamp)], expectsRow: true) {
                                summary.duplicates += 1
                                continue
                            }
                            try step(upsertStatement, [.text(address), .text(visit.title), .int(typed), .double(stamp)])
                            try step(insertStatement, [.double(stamp), .text(visit.title), .int(typed), .text(address)])
                            summary.added += 1
                        }
                    }
                }
            }
        }
        return summary
    }

    /// Sets the title of the page and of its latest visit. Empty titles are ignored (a page that has not
    /// loaded yet reports one).
    public func updateTitle(url: URL, title: String) throws {
        guard !title.isEmpty else { return }
        let address = Self.storedURL(url)
        try transaction {
            try execute("UPDATE pages SET title = ? WHERE url = ?", [.text(title), .text(address)])
            try execute("""
                UPDATE visits SET title = ? WHERE id = (
                    SELECT v.id FROM visits v JOIN pages p ON p.id = v.page_id
                    WHERE p.url = ? ORDER BY v.date DESC, v.id DESC LIMIT 1)
                """, [.text(title), .text(address)])
        }
    }

    // MARK: - Queries

    /// Pages whose title or URL contains every whitespace-separated word of `query`. Pages whose host starts
    /// with the first word come first ("go" finds golang.org even among many busier pages), then best frecency,
    /// then most recent. An empty query returns the top-frecency pages. URLs are matched without their scheme,
    /// so "https" doesn't match everything.
    public func search(_ query: String, limit: Int, now: Date) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let (clause, params) = Self.wordClause(query, titleColumn: "title", urlColumn: Self.urlWithoutScheme)
        let first = query.split(whereSeparator: \.isWhitespace).first.map { Self.escapeLike(String($0)) } ?? ""
        // Frecency is computed in SQL (same buckets as `Frecency.score`) so only `limit` rows come back to Swift;
        // SQLite still scans the matching pages. Named parameters come after the clause's `?`s, in this order.
        return try rows("""
            SELECT url, title, visit_count, typed_count, last_visit FROM pages \(clause)
            ORDER BY (:first <> '' AND (\(Self.urlWithoutScheme) LIKE :first || '%' ESCAPE '\\'
                                    OR \(Self.urlWithoutScheme) LIKE 'www.' || :first || '%' ESCAPE '\\')) DESC,
                (max(visit_count, 0) + 2 * max(typed_count, 0)) * (CASE
                WHEN :now - last_visit <= \(4 * 86_400) THEN 100
                WHEN :now - last_visit <= \(14 * 86_400) THEN 70
                WHEN :now - last_visit <= \(31 * 86_400) THEN 50
                WHEN :now - last_visit <= \(90 * 86_400) THEN 30
                ELSE 10 END) DESC, last_visit DESC, url ASC
            LIMIT :limit
            """, params + [.text(first), .double(now.timeIntervalSince1970), .int(Int64(limit))], Self.entry)
    }

    /// The stored URL without `scheme://`, for matching.
    private static let urlWithoutScheme = "substr(url, instr(url, '://') + 3)"

    /// Visits newest first, optionally narrowed to those whose title or URL contains every word of `query`.
    public func visits(matching query: String?, limit: Int, offset: Int = 0) throws -> [HistoryVisit] {
        guard limit > 0 else { return [] }
        let (clause, params) = Self.wordClause(query ?? "", titleColumn: "v.title", urlColumn: "substr(p.url, instr(p.url, '://') + 3)")
        return try rows("""
            SELECT v.id, p.url, v.title, v.date FROM visits v JOIN pages p ON p.id = v.page_id \(clause)
            ORDER BY v.date DESC, v.id DESC LIMIT ? OFFSET ?
            """, params + [.int(Int64(limit)), .int(Int64(max(0, offset)))]) { stmt in
            HistoryVisit(
                id: sqlite3_column_int64(stmt, 0),
                url: Self.text(stmt, 1),
                title: Self.text(stmt, 2),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            )
        }
    }

    /// Distinct pages, most recently visited first, for the History menu.
    public func recentPages(limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return try rows("""
            SELECT url, title, visit_count, typed_count, last_visit FROM pages
            ORDER BY last_visit DESC, id DESC LIMIT ?
            """, [.int(Int64(limit))], Self.entry)
    }

    /// The sites visited most within the last `days` days, for the New Tab page: one entry per host (without
    /// `www.`), ranked by the sum of its pages' frecency over the visits inside that window. The entry is the
    /// site's front page (`/` on the scheme, host and port of its best-scoring page), so a sign-in redirect or
    /// a deep page never stands for the site; its title is the front page's when that was visited in the window,
    /// otherwise the host. Web pages only; `excludingHosts` (same form) are skipped.
    public func topSites(limit: Int, days: Int, now: Date, excludingHosts: Set<String>) throws -> [HistoryEntry] {
        guard limit > 0, days > 0 else { return [] }
        let since = now.timeIntervalSince1970 - Double(days) * 86_400
        let pages = try rows("""
            SELECT p.url, p.title, count(*), sum(v.typed), max(v.date) FROM visits v JOIN pages p ON p.id = v.page_id
            WHERE v.date >= ? AND v.date <= ? AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%')
            GROUP BY p.id
            """, [.double(since), .double(now.timeIntervalSince1970)], Self.entry)
        var hosts: [String: (score: Double, best: Double, entry: HistoryEntry, frontTitle: String?)] = [:]
        for page in pages {
            guard let host = NewTabSites.siteHost(page.url), !excludingHosts.contains(host) else { continue }
            let score = Frecency.score(visitCount: page.visitCount, typedCount: page.typedCount, lastVisit: page.lastVisit, now: now)
            var current = hosts[host] ?? (0, -1, page, nil)
            current.score += score
            if score > current.best || (score == current.best && page.url < current.entry.url) {
                current.best = score
                current.entry = page
            }
            if Self.isFrontPage(page.url), !page.title.isEmpty { current.frontTitle = page.title }
            hosts[host] = current
        }
        return hosts
            .sorted { ($0.value.score, $0.value.entry.lastVisit, $1.value.entry.url) > ($1.value.score, $1.value.entry.lastVisit, $0.value.entry.url) }
            .prefix(limit)
            .map { host, site in
                var entry = site.entry
                entry.url = Self.frontPage(of: entry.url) ?? entry.url
                entry.title = site.frontTitle ?? host
                return entry
            }
    }

    private static func isFrontPage(_ address: String) -> Bool {
        guard let parts = URLComponents(string: address) else { return false }
        return (parts.path.isEmpty || parts.path == "/") && parts.query == nil
    }

    /// `/` on the address's scheme, host and port.
    private static func frontPage(of address: String) -> String? {
        guard let parts = URLComponents(string: address), let scheme = parts.scheme, let host = parts.host else { return nil }
        var front = URLComponents()
        front.scheme = scheme
        front.host = host
        front.port = parts.port
        front.path = "/"
        return front.string
    }

    /// Number of distinct pages stored (0 if the database cannot be read).
    public var pageCount: Int {
        let counts = (try? rows("SELECT count(*) FROM pages", []) { Int(sqlite3_column_int64($0, 0)) }) ?? []
        return counts.first ?? 0
    }

    // MARK: - Removing

    /// Deletes a page and all its visits.
    public func remove(url: String) throws {
        try transaction {
            try execute("DELETE FROM visits WHERE page_id IN (SELECT id FROM pages WHERE url = ?)", [.text(url)])
            try execute("DELETE FROM pages WHERE url = ?", [.text(url)])
        }
        try scrubDeleted()
    }

    /// "Clear recent history": deletes visits at or after `date`. Pages left with no visits are deleted; the
    /// others get `visit_count`, `typed_count` and `last_visit` recomputed from the visits that remain.
    public func removeVisits(since date: Date) throws {
        let stamp = date.timeIntervalSince1970
        try transaction {
            try execute("DELETE FROM visits WHERE date >= ?", [.double(stamp)])
            try deleteOrphanPages()
            // A page lost a visit exactly when its last visit was at or after the cutoff.
            try execute("""
                UPDATE pages SET
                    visit_count = (SELECT count(*) FROM visits WHERE page_id = pages.id),
                    typed_count = (SELECT coalesce(sum(typed), 0) FROM visits WHERE page_id = pages.id),
                    last_visit = (SELECT max(date) FROM visits WHERE page_id = pages.id),
                    title = coalesce((SELECT title FROM visits WHERE page_id = pages.id AND title <> ''
                                      ORDER BY date DESC, id DESC LIMIT 1), title)
                WHERE last_visit >= ?
                """, [.double(stamp)])
        }
        try scrubDeleted()
    }

    /// Deletes everything.
    public func removeAll() throws {
        try transaction {
            try execute("DELETE FROM visits")
            try execute("DELETE FROM pages")
        }
        try scrubDeleted()
    }

    /// Cleared history must not stay readable on disk: deleted rows are zeroed (`secure_delete`, set at open)
    /// and the write-ahead log, which still holds the old pages, is folded in and truncated.
    private func scrubDeleted() throws {
        _ = try rows("PRAGMA wal_checkpoint(TRUNCATE)", []) { _ in 0 }
    }

    /// How many visits `prune(olderThan:)` would delete, for a "this deletes N visits" confirmation.
    public func countVisits(olderThan date: Date) throws -> Int {
        try rows("SELECT count(*) FROM visits WHERE date < ?", [.double(date.timeIntervalSince1970)]) { stmt in
            Int(sqlite3_column_int64(stmt, 0))
        }.first ?? 0
    }

    /// Retention: drops visits before `date`, then pages with no visits left. Surviving pages keep their
    /// lifetime counts, so frecency does not change when old visits age out. Aged-out visits are scrubbed from disk
    /// like cleared ones.
    public func prune(olderThan date: Date) throws {
        try transaction {
            try execute("DELETE FROM visits WHERE date < ?", [.double(date.timeIntervalSince1970)])
            try deleteOrphanPages()
        }
        try scrubDeleted()
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try rows("PRAGMA user_version", []) { sqlite3_column_int($0, 0) }.first ?? 0
        if version > Self.schemaVersion {
            throw Error(code: SQLITE_MISMATCH, message: "history database is version \(version), newer than this app understands (\(Self.schemaVersion))")
        }
        guard version < Self.schemaVersion else { return }
        try transaction {
            // Version 0 is a new, empty database. Later versions add `if version < N` steps here.
            try execute("""
                CREATE TABLE IF NOT EXISTS pages (
                    id INTEGER PRIMARY KEY,
                    url TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL DEFAULT '',
                    visit_count INTEGER NOT NULL DEFAULT 0,
                    typed_count INTEGER NOT NULL DEFAULT 0,
                    last_visit REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS visits (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    page_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                    date REAL NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    typed INTEGER NOT NULL DEFAULT 0
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS visits_date ON visits(date)")
            try execute("CREATE INDEX IF NOT EXISTS visits_page_id ON visits(page_id)")
            try execute("CREATE INDEX IF NOT EXISTS pages_last_visit ON pages(last_visit)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func deleteOrphanPages() throws {
        try execute("DELETE FROM pages WHERE id NOT IN (SELECT DISTINCT page_id FROM visits)")
    }

    // MARK: - Query building

    /// `WHERE` clause requiring every word in `query` to appear in the title or URL column, plus its bindings.
    /// `%`, `_` and `\` in the words are escaped so they match literally.
    private static func wordClause(_ query: String, titleColumn: String, urlColumn: String) -> (String, [Param]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ("", []) }
        var params: [Param] = []
        let terms = words.map { word -> String in
            let escaped = escapeLike(word)
            params.append(.text("%\(escaped)%"))
            params.append(.text("%\(escaped)%"))
            return "(\(titleColumn) LIKE ? ESCAPE '\\' OR \(urlColumn) LIKE ? ESCAPE '\\')"
        }
        return ("WHERE " + terms.joined(separator: " AND "), params)
    }

    /// Escapes `\`, `%` and `_` so they match literally in `LIKE … ESCAPE '\'`.
    private static func escapeLike(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func entry(_ stmt: OpaquePointer) -> HistoryEntry {
        HistoryEntry(
            url: text(stmt, 0),
            title: text(stmt, 1),
            visitCount: Int(sqlite3_column_int64(stmt, 2)),
            typedCount: Int(sqlite3_column_int64(stmt, 3)),
            lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        )
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    // MARK: - SQLite plumbing

    /// A value bound to a `?` placeholder.
    private enum Param {
        case int(Int64)
        case double(Double)
        case text(String)
    }

    private func lastError() -> Error {
        Error(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    /// Prepares `sql`, binds `params`, runs `body` and always finalizes the statement.
    private func withStatement<T>(_ sql: String, _ params: [Param], _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let stmt = handle else {
            let error = lastError()
            sqlite3_finalize(handle)
            throw error
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        return try body(stmt)
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Param]) throws {
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch param {
            case .int(let value): rc = sqlite3_bind_int64(stmt, index, value)
            case .double(let value): rc = sqlite3_bind_double(stmt, index, value)
            case .text(let value): rc = sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
    }

    /// Runs a prepared statement again with new bindings. With `expectsRow` it returns whether a row came back;
    /// otherwise the statement must run to completion.
    @discardableResult
    private func step(_ stmt: OpaquePointer, _ params: [Param], expectsRow: Bool = false) throws -> Bool {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if expectsRow {
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw lastError() }
            return rc == SQLITE_ROW
        }
        guard rc == SQLITE_DONE else { throw lastError() }
        return false
    }

    /// Runs a statement that returns no rows we care about.
    private func execute(_ sql: String, _ params: [Param] = []) throws {
        try withStatement(sql, params) { stmt in
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
            guard rc == SQLITE_DONE else { throw lastError() }
        }
    }

    /// Runs a query and maps every result row.
    private func rows<T>(_ sql: String, _ params: [Param], _ map: (OpaquePointer) -> T) throws -> [T] {
        try withStatement(sql, params) { stmt in
            var result: [T] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                result.append(map(stmt))
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw lastError() }
            return result
        }
    }

    /// Runs `body` inside one write transaction; rolls back if it throws.
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// Tells SQLite to copy bound text immediately (`SQLITE_TRANSIENT`, which the C header defines as a macro).
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
