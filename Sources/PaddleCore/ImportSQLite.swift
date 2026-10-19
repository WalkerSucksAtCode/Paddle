import Foundation
import SQLite3

/// Reads another browser's SQLite file without touching the original. The browser may be running and holding the
/// database open, so a copy (the file and its `-wal` / `-shm`) goes to a private temporary folder and is opened
/// read-only; the copy is deleted when the read ends.
enum ImportSQLite {
    enum Bind {
        case int(Int64)
        case double(Double)
        case text(String)
    }

    /// A statement SQLite refused or a row it couldn't step; the readers turn it into their own message.
    struct Failure: Error {
        var message: String
    }

    /// Copies `url` (and its WAL files), opens the copy read-only and runs `body` on the handle. Errors become
    /// `BrowserImportError`: macOS refusing the file is `accessDenied(browser)`, a missing file is `missing`, anything
    /// else `unreadable`. `what` names the database in the "couldn't be opened" message.
    static func withCopy<T>(
        of url: URL, browser: ImportSource.Browser, what: String = "database",
        temporaryRoot: URL? = nil, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let fm = FileManager.default
        let root = temporaryRoot ?? fm.temporaryDirectory
        let folder = root.appending(path: "PaddleImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }

        let copy = folder.appending(path: "import.sqlite")
        try copyDatabase(from: url, to: copy, browser: browser, fm)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close_v2(handle) }
        guard rc == SQLITE_OK, let db = handle else {
            throw BrowserImportError.unreadable("The \(what) couldn't be opened (SQLite error \(rc)).")
        }
        sqlite3_busy_timeout(db, 2_000)
        return try body(db)
    }

    /// Copies the database and whichever of its `-wal` and `-shm` siblings exist, under the names SQLite pairs them by.
    private static func copyDatabase(from source: URL, to copy: URL, browser: ImportSource.Browser, _ fm: FileManager) throws {
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: source.path + suffix)
            let to = URL(filePath: copy.path + suffix)
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                if suffix.isEmpty || !isMissing(error) { throw translate(error, browser: browser, file: source.lastPathComponent) }
            }
        }
    }

    /// EPERM and EACCES anywhere in the error chain: macOS refusing a protected folder, or plain file permissions.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? any Error { return isPermissionDenied(underlying) }
        return false
    }

    static func isMissing(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? any Error { return isMissing(underlying) }
        return false
    }

    static func translate(_ error: any Error, browser: ImportSource.Browser, file: String) -> BrowserImportError {
        if isPermissionDenied(error) { return .accessDenied(browser) }
        if isMissing(error) { return .missing("\(browser.displayName)'s \(file)") }
        return .unreadable("\(browser.displayName)'s \(file) couldn't be copied: \(error.localizedDescription)")
    }

    // MARK: - Query helpers

    /// Column text, or "" for NULL.
    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    static func int(_ stmt: OpaquePointer, _ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }

    static func double(_ stmt: OpaquePointer, _ column: Int32) -> Double { sqlite3_column_double(stmt, column) }

    static func isNull(_ stmt: OpaquePointer, _ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }

    /// Runs a query and maps every row. Throws `Failure` when SQLite refuses the statement or a step.
    static func run<T>(_ db: OpaquePointer, _ sql: String, _ binds: [Bind] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let stmt = handle else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(handle)
            throw Failure(message: message)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            switch bind {
            case .int(let value): sqlite3_bind_int64(stmt, index, value)
            case .double(let value): sqlite3_bind_double(stmt, index, value)
            case .text(let value): sqlite3_bind_text(stmt, index, value, -1, transient)
            }
        }
        var rows: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(map(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
        return rows
    }
}
