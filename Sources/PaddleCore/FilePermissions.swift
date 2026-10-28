import Foundation

/// Owner-only permissions for what Paddle keeps: folders 0700, files 0600.
public enum FilePermissions {
    public static let folderMode = 0o700
    public static let fileMode = 0o600

    /// True when `mode` gives group or others any access.
    public static func isTooOpen(_ mode: Int) -> Bool { mode & 0o077 != 0 }

    /// The mode to set for something now at `mode`: keeps the owner's bits, drops group and others.
    public static func tightened(_ mode: Int, directory: Bool) -> Int {
        let owner = mode & 0o700
        return directory ? (owner | 0o700) : (owner | 0o600) & 0o700
    }

    /// Makes an existing file or folder owner-only. False when it doesn't exist, was already tight or can't be changed.
    @discardableResult
    public static func restrict(_ url: URL, directory: Bool) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              attrs[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
        let wanted = tightened(mode, directory: directory)
        guard wanted != mode & 0o777 || isTooOpen(mode) else { return false }
        return (try? fm.setAttributes([.posixPermissions: wanted], ofItemAtPath: url.path)) != nil
    }

    /// A SQLite database and the side files it may have next to it.
    public static func restrictDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            restrict(URL(fileURLWithPath: url.path + suffix), directory: false)
        }
    }

    /// Creates a folder (and missing parents) and makes it owner-only.
    public static func createPrivateFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: folderMode])
        restrict(url, directory: true)
    }
}
