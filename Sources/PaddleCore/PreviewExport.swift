import Foundation

/// The pure parts of Open in Preview (`BrowserWindowController.paddleOpenInPreview`): which URLs are fetched, which
/// files are accepted, and when an export folder is stale. Each export is a PDF in its own folder under `Paddle Preview`.
public enum PreviewExport {
    /// The largest PDF accepted: 512 MB.
    public static let maxBytes: Int64 = 512 * 1024 * 1024
    /// Export folders created longer ago than this are deleted.
    public static let maxFolderAge: TimeInterval = 24 * 60 * 60

    /// Only http and https pages are fetched. Anything else gets WebKit's own rendering of the page.
    public static func canFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func isWithinSizeLimit(_ bytes: Int64) -> Bool {
        bytes >= 0 && bytes <= maxBytes
    }

    /// A PDF starts with `%PDF`.
    public static func isPDF(_ head: Data) -> Bool {
        head.starts(with: Data("%PDF".utf8))
    }

    public static func isPDF(file url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isPDF((try? handle.read(upToCount: 4)) ?? Data())
    }

    /// Data small enough and starting with `%PDF`.
    public static func isAcceptable(_ data: Data) -> Bool {
        isWithinSizeLimit(Int64(data.count)) && isPDF(data)
    }

    /// A file within the size cap that starts with `%PDF`.
    public static func isAcceptable(file url: URL) -> Bool {
        isWithinSizeLimit(fileSize(at: url) ?? -1) && isPDF(file: url)
    }

    public static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Whether a folder created at `created` is older than `maxFolderAge` at `now`.
    public static func isStale(created: Date, now: Date) -> Bool {
        now.timeIntervalSince(created) > maxFolderAge
    }

    /// A new export folder named by a UUID inside `root`, both owner-only (0700). Creates `root` if needed.
    public static func makeFolder(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Deletes the entries in `root` created more than `maxFolderAge` before `now`. A missing `root` is fine, and an
    /// entry with no creation date is kept.
    public static func removeStaleFolders(in root: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for entry in entries {
            guard let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  isStale(created: created, now: now) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}
