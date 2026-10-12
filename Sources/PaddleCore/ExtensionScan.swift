import Foundation

/// One extension folder found in `extensions/`.
public struct ExtensionEntry: Sendable, Equatable {
    /// Folder name: the key in `config.json`, in the permissions file and in the extension id.
    public let name: String
    /// Absolute, symlink-resolved directory holding `manifest.json`.
    public let root: URL

    public init(name: String, root: URL) {
        self.name = name
        self.root = root
    }
}

/// Finds unpacked extensions in a directory.
public enum ExtensionScan {
    /// Lists the extensions in `directory`, sorted by folder name, plus a one-line problem for every folder or file
    /// that looks like an attempt but isn't loadable (keyed by its name).
    ///
    /// - A folder with `manifest.json` at its top is an extension; otherwise a folder with exactly one subfolder
    ///   holding `manifest.json` (the usual unzip layout) uses that subfolder.
    /// - Names starting with `.` or `_` are skipped. `.zip` and `.crx` files get a problem; other files are ignored.
    /// - `root` is absolute with symlinks resolved (a relative URL traps `WKWebExtension.init`). A symlinked folder
    ///   is fine unless its resolved path equals or contains one of `forbiddenRoots` (pass the home and support folders).
    public static func scan(
        _ directory: URL, forbiddenRoots: [URL], fileManager: FileManager = .default
    ) -> (entries: [ExtensionEntry], problems: [String: String]) {
        var entries: [ExtensionEntry] = []
        var problems: [String: String] = [:]
        let forbidden = forbiddenRoots.map(resolved)
        let children = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()

        for name in children where !name.hasPrefix(".") && !name.hasPrefix("_") {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                let ext = url.pathExtension.lowercased()
                if ext == "zip" || ext == "crx" { problems[name] = "unzip it into a folder first" }
                continue
            }
            let top = resolved(url)
            guard let root = extensionRoot(in: top, fileManager: fileManager) else {
                problems[name] = "not an extension (needs manifest.json)"
                continue
            }
            if forbidden.contains(where: { $0.path == top.path || $0.path == root.path || contains(root, $0) }) {
                problems[name] = "points at a protected folder"
                continue
            }
            entries.append(ExtensionEntry(name: name, root: root))
        }
        return (entries, problems)
    }

    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func hasManifest(_ dir: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: dir.appendingPathComponent("manifest.json").path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func extensionRoot(in top: URL, fileManager: FileManager) -> URL? {
        if hasManifest(top, fileManager) { return top }
        let nested = ((try? fileManager.contentsOfDirectory(atPath: top.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { resolved(top.appendingPathComponent($0)) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && hasManifest(url, fileManager)
            }
        return nested.count == 1 ? nested[0] : nil
    }

    /// True when `inner` is strictly inside `outer` (compared by path components).
    private static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let o = outer.pathComponents, i = inner.pathComponents
        return i.count > o.count && Array(i.prefix(o.count)) == o
    }
}
