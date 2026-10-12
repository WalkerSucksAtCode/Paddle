import Foundation

/// A preflight summary of an extension's manifest, built from the JSON WebKit itself parsed (`WKWebExtension.manifest`),
/// so it never disagrees with WebKit about what the manifest says.
public struct ExtensionManifest: Sendable, Equatable {
    public enum ParseError: Error, Equatable { case notAnObject }

    /// `permissions` and `optional_permissions` entries that are names, not host patterns. Sorted, unique.
    public let permissions: [String]
    /// `background.service_worker`, `background.scripts[]`, `background.page`, in that order. Paths relative to the extension root.
    public let backgroundFiles: [String]
    /// Content-script js/css, action popups, options pages and declarativeNetRequest rule files. Unique, in manifest order, relative to the extension root.
    public let referencedFiles: [String]

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notAnObject }

        var names = Set<String>()
        for key in ["permissions", "optional_permissions"] {
            for case let item as String in root[key] as? [Any] ?? [] where !Self.isPattern(item) { names.insert(item) }
        }
        permissions = names.sorted()

        var background: [String] = []
        if let bg = root["background"] as? [String: Any] {
            if let worker = bg["service_worker"] as? String { background.append(worker) }
            background += (bg["scripts"] as? [Any] ?? []).compactMap { $0 as? String }
            if let page = bg["page"] as? String { background.append(page) }
        }
        backgroundFiles = Self.unique(background.map(Self.cleaned))

        var files: [String] = []
        for case let script as [String: Any] in root["content_scripts"] as? [Any] ?? [] {
            for key in ["js", "css"] { files += (script[key] as? [Any] ?? []).compactMap { $0 as? String } }
        }
        for key in ["action", "browser_action", "page_action"] {
            if let popup = (root[key] as? [String: Any])?["default_popup"] as? String { files.append(popup) }
        }
        if let page = root["options_page"] as? String { files.append(page) }
        if let page = (root["options_ui"] as? [String: Any])?["page"] as? String { files.append(page) }
        let resources = (root["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [Any] ?? []
        for case let resource as [String: Any] in resources {
            if let path = resource["path"] as? String { files.append(path) }
        }
        referencedFiles = Self.unique(files.map(Self.cleaned))
    }

    /// Files named by the manifest that don't exist under `root`, split into background files (a missing service
    /// worker hangs the background with no error) and everything else. Names have no leading "/" (stripped when the
    /// manifest is read); a path that escapes `root` counts as missing.
    public func missingFiles(in root: URL, fileManager: FileManager = .default) -> (background: [String], other: [String]) {
        let base = root.standardizedFileURL.pathComponents
        func missing(_ path: String) -> Bool {
            let target = root.appendingPathComponent(path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard Array(target.pathComponents.prefix(base.count)) == base, target.pathComponents.count > base.count else { return true }
            return !(fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) && !isDirectory.boolValue)
        }
        return (backgroundFiles.filter(missing), referencedFiles.filter { !backgroundFiles.contains($0) }.filter(missing))
    }

    /// Requested permission names that aren't in `supported` (WebKit drops these silently), sorted.
    public func unsupportedPermissions(supported: Set<String>) -> [String] {
        permissions.filter { !supported.contains($0) }.sorted()
    }

    private static func isPattern(_ s: String) -> Bool {
        s.contains("/") || s.contains("*") || s.hasPrefix("<")
    }

    /// Turns a manifest path into a path relative to the extension root: drops a query or fragment
    /// (`popup.html?x#y`) and leading slashes.
    private static func cleaned(_ path: String) -> String {
        String(path.prefix { $0 != "?" && $0 != "#" }.drop { $0 == "/" })
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
