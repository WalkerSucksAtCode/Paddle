import Foundation
@testable import PaddleCore
import SQLite3

/// Synthetic stand-ins for other browsers' files, built from the formats' documented schemas in a temporary
/// folder. Nothing here reads a real browser profile.
final class ImportFixture {
    let root: URL
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PaddleImportTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        // A test may leave a file unreadable on purpose.
        chmodAll(root, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    private func chmodAll(_ url: URL, _ mode: Int) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        for child in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
            chmodAll(url.appending(path: child), mode)
        }
    }

    func path(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to relative: String) throws -> URL {
        let url = try path(relative)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - SQLite

    /// Runs statements on a database file. Pass `keepOpen` to hold the connection (and its WAL) open.
    @discardableResult
    func database(_ url: URL, wal: Bool = false, _ statements: [String], keepOpen: Bool = false) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("open")
        }
        if wal { try run(db, "PRAGMA journal_mode = WAL") }
        for statement in statements { try run(db, statement) }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }

    func run(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            throw FixtureError.sqlite("\(text): \(sql)")
        }
    }

    enum FixtureError: Error { case sqlite(String) }

    // MARK: - Dates (all one instant: 2023-11-14 22:13:20 UTC = Unix 1_700_000_000)

    static let unix: Int64 = 1_700_000_000
    static var chromeTime: Int64 { (unix + 11_644_473_600) * 1_000_000 }
    static var firefoxTime: Int64 { unix * 1_000_000 }
    static var safariTime: Double { Double(unix) - 978_307_200 }

    // MARK: - History databases

    /// Chrome `History`: urls(id, url, title) and visits(id, url → urls.id, visit_time, transition).
    func chromeHistory(at relative: String = "Library/Application Support/Google/Chrome/Default/History") throws -> URL {
        let url = try path(relative)
        let t = Self.chromeTime
        try database(url, [
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER)",
            "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0)",
            "INSERT INTO urls (id, url, title) VALUES (1, 'https://example.com/a', 'Example A')",
            "INSERT INTO urls (id, url, title) VALUES (2, 'http://example.org/b', 'Example B')",
            "INSERT INTO urls (id, url, title) VALUES (3, 'chrome://settings/', 'Settings')",
            "INSERT INTO urls (id, url, title) VALUES (4, 'file:///tmp/x.html', 'File')",
            "INSERT INTO urls (id, url, title) VALUES (5, 'https://example.com/zero', 'Zero date')",
            // transition 0x30000001 = typed with qualifier bits set; 0 = link.
            "INSERT INTO visits (url, visit_time, transition) VALUES (1, \(t), 805306369)",
            "INSERT INTO visits (url, visit_time, transition) VALUES (1, \(t - 3_600_000_000), 0)",
            "INSERT INTO visits (url, visit_time, transition) VALUES (2, \(t - 7_200_000_000), 0)",
            "INSERT INTO visits (url, visit_time, transition) VALUES (3, \(t), 0)",
            "INSERT INTO visits (url, visit_time, transition) VALUES (4, \(t), 0)",
            "INSERT INTO visits (url, visit_time, transition) VALUES (5, 0, 0)",
        ])
        return url
    }

    /// Firefox `places.sqlite`: moz_places(id, url, title) and moz_historyvisits(id, place_id, visit_date, visit_type).
    func firefoxHistory(at relative: String = "Library/Application Support/Firefox/Profiles/abc.default/places.sqlite") throws -> URL {
        let url = try path(relative)
        let t = Self.firefoxTime
        try database(url, [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER)",
            "CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER, session INTEGER)",
            "INSERT INTO moz_places (id, url, title) VALUES (1, 'https://example.com/a', 'Example A')",
            "INSERT INTO moz_places (id, url, title) VALUES (2, 'http://example.org/b', NULL)",
            "INSERT INTO moz_places (id, url, title) VALUES (3, 'place:type=6&sort=14', 'Recent tags')",
            "INSERT INTO moz_places (id, url, title) VALUES (4, 'about:reader?url=x', 'Reader')",
            "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (1, \(t), 2)",
            "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (1, \(t - 3_600_000_000), 1)",
            "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (2, \(t - 7_200_000_000), 1)",
            "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (3, \(t), 1)",
            "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (4, \(t), 1)",
        ])
        return url
    }

    /// Safari `History.db`: history_items(id, url) and history_visits(id, history_item → history_items.id, visit_time, title).
    func safariHistory(at relative: String = "Library/Safari/History.db") throws -> URL {
        let url = try path(relative)
        let t = Self.safariTime
        try database(url, [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT, visit_count INTEGER NOT NULL)",
            "CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT, load_successful BOOLEAN)",
            "INSERT INTO history_items (id, url, visit_count) VALUES (1, 'https://example.com/a', 2)",
            "INSERT INTO history_items (id, url, visit_count) VALUES (2, 'http://example.org/b', 1)",
            "INSERT INTO history_items (id, url, visit_count) VALUES (3, 'favorites://', 1)",
            "INSERT INTO history_items (id, url, visit_count) VALUES (4, 'safari-resource:/ErrorPage.html', 1)",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, \(t), 'Example A')",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (1, \(t - 3600), 'Example A')",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (2, \(t - 7200), NULL)",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (3, \(t), 'Favorites')",
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (4, \(t), 'Error')",
        ])
        return url
    }

    // MARK: - mozlz4

    /// A `.mozlz4` file holding `data` as a single literals-only LZ4 block (valid, if not small).
    static func mozLZ4(_ data: Data) -> Data {
        var block: [UInt8] = []
        let count = data.count
        block.append(UInt8(min(count, 15)) << 4)
        if count >= 15 {
            var rest = count - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        block += [UInt8](data)
        return mozLZ4(block: block, size: count)
    }

    static func mozLZ4(block: [UInt8], size: Int) -> Data {
        var file = Data(MozLZ4.magic)
        for shift in stride(from: 0, to: 32, by: 8) { file.append(UInt8((size >> shift) & 0xFF)) }
        file.append(contentsOf: block)
        return file
    }
}
