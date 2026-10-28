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

/// Unpacked extensions in a directory.
public enum ExtensionScan {
    /// Extensions in `directory`, sorted by folder name, plus a one-line problem for each unloadable
    /// folder or file (keyed by name).
    ///
    /// - A folder with `manifest.json` at its top is an extension; else a folder with exactly one
    ///   subfolder holding `manifest.json` (usual unzip layout) uses that subfolder.
    /// - Names starting with `.` or `_` are skipped. `.zip` and `.crx` get a problem; other files ignored.
    /// - `root` is absolute with symlinks resolved (a relative URL traps `WKWebExtension.init`). A
    ///   symlink is fine unless its resolved path equals, contains, or lies inside a `forbiddenRoots` entry (pass
    ///   home and support) while not being inside `directory` itself; and a link inside the extension that
    ///   resolves outside the extension's own folder is a problem.
    public static func scan(
        _ directory: URL, forbiddenRoots: [URL], fileManager: FileManager = .default
    ) -> (entries: [ExtensionEntry], problems: [String: String]) {
        var entries: [ExtensionEntry] = []
        var problems: [String: String] = [:]
        let forbidden = forbiddenRoots.map(resolved)
        let base = resolved(directory)
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
            // A link out of extensions/ into a place inside a protected folder (like ~/.ssh) would let the extension
            // read it through its own resources; only the extensions folder itself may sit there.
            if !contains(base, root), forbidden.contains(where: { contains($0, root) }) {
                problems[name] = "points into a protected folder"
                continue
            }
            if let escaping = firstLinkLeaving(root, fileManager: fileManager) {
                problems[name] = "contains a link that leaves its folder (\(escaping))"
                continue
            }
            entries.append(ExtensionEntry(name: name, root: root))
        }
        return (entries, problems)
    }

    /// The relative path of the first symbolic link under `root` whose target is outside `root`; nil when none is.
    /// Looks at the first 50,000 items only.
    private static func firstLinkLeaving(_ root: URL, fileManager: FileManager) -> String? {
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return nil }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 50_000 { break }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = resolved(url)
            if target.path != root.path && !contains(root, target) {
                return String(url.path.dropFirst(root.path.count).drop { $0 == "/" })
            }
        }
        return nil
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
