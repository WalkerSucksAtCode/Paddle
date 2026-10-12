import CryptoKit
import Foundation

/// What `ExtensionOverlay.make` built.
public struct ExtensionOverlayResult: Equatable, Sendable {
    /// Absolute root of the patched clone; what `WKWebExtension` is loaded from.
    public let root: URL
    /// The prelude is first in `background.scripts`.
    public let backgroundPatched: Bool
    /// The prelude is first in at least one of the extension's own content scripts.
    public let contentScriptsPatched: Bool
    /// The background kind left as it is (`service_worker` or `page`), if any.
    public let unpatchedBackground: ExtensionCompat.UnpatchedBackground?
    /// The popup page got its size stylesheet.
    public let popupPatched: Bool
    /// Bytes written when the folder couldn't be cloned (another volume, or a volume without clones) and was copied
    /// in full; nil for an APFS clone.
    public let copiedBytes: Int64?
    /// The overlay from an earlier load was kept because the source folder hasn't changed since.
    public let reused: Bool

    /// The prelude runs in at least one of the extension's contexts.
    public var runsPrelude: Bool { backgroundPatched || contentScriptsPatched }

    /// One line for the status list.
    public var statusText: String {
        var notes: [String] = []
        let base = runsPrelude ? "compat prelude applied" : "compat popup style applied"
        switch (backgroundPatched, contentScriptsPatched) {
        case (true, false): notes.append("background only")
        case (false, true): notes.append("content scripts only")
        default: break
        }
        if let kind = unpatchedBackground { notes.append("background.\(kind.rawValue) left unpatched") }
        if let copiedBytes { notes.append("copied, \(Self.size(copiedBytes))") }
        return notes.isEmpty ? base : "\(base) (\(notes.joined(separator: "; ")))"
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000
            ? "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
            : "\(max(1, Int((Double(bytes) / 1_000).rounded()))) KB"
    }
}

/// A patched clone of an extension folder, one per extension under `extension-overlays/`. Made with `clonefile`,
/// which on the same APFS volume costs almost no disk or time; where cloning isn't possible (the folder sits on
/// another volume through a symlink, or on a volume without clones) it is a full copy, and the status line says so.
/// It is kept between loads while the source folder is unchanged and remade when anything in it changes. Edits to
/// the user's folder never reach it and patching it never touches the user's folder. The extension's identity,
/// permission record and storage stay keyed by the original folder name; only the load path changes.
///
/// Pure file work with no shared state: safe to call off the main actor.
public enum ExtensionOverlay {
    public enum MakeError: Error, Equatable, LocalizedError {
        case badName(String)
        case clone(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .badName(let name): "\"\(name)\" is not a plain folder name"
            case .clone(let why): "could not clone the folder: \(why)"
            case .unreadable(let path): "could not list \(path)"
            }
        }
    }

    /// Bump when what `make` writes changes, so every kept overlay is remade once.
    static let recipeVersion = 2
    /// Written last into a finished overlay: the source fingerprint it was made from and what it holds.
    static let stampFileName = ".paddle-overlay.json"

    struct Stamp: Codable, Equatable {
        let fingerprint: String
        let copiedBytes: Int64?
        let popupPatched: Bool
    }

    /// Builds the overlay for the extension at `source` as `overlays/<name>/`, or keeps the one already there when
    /// the source is unchanged. Returns nil, after removing any stale overlay of that name, when the extension needs
    /// none: a Safari build, or one whose manifest has nowhere to put the prelude and no popup to fix. Throws when the
    /// manifest can't be read or the clone or patch fails; the caller then loads the original folder.
    public static func make(
        from source: URL, name: String, in overlays: URL, fileManager: FileManager = .default
    ) throws -> ExtensionOverlayResult? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") else { throw MakeError.badName(name) }
        let manifestData = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw ExtensionCompat.PatchError.notAnObject
        }
        let target = overlays.appendingPathComponent(name, isDirectory: true)
        guard ExtensionCompat.needsPrelude(manifest: manifest) else {
            remove(name: name, in: overlays, fileManager: fileManager)
            return nil
        }

        // The rewrite is checked before anything is cloned, so a manifest the patch can't handle leaves no overlay.
        let patch = try ExtensionCompat.patchManifest(manifestData)
        let css = ExtensionCompat.popupCSS(forGeckoID: ExtensionCompat.geckoID(manifest: manifest))
        let popup = css == nil ? nil : ExtensionCompat.popupPath(manifest: manifest)
        guard patch.preludeApplied || popup != nil else {
            remove(name: name, in: overlays, fileManager: fileManager)
            return nil
        }
        func result(popupPatched: Bool, copiedBytes: Int64?, reused: Bool) -> ExtensionOverlayResult {
            ExtensionOverlayResult(
                root: target.standardizedFileURL, backgroundPatched: patch.backgroundPatched,
                contentScriptsPatched: patch.contentScriptsPatched, unpatchedBackground: patch.unpatchedBackground,
                popupPatched: popupPatched, copiedBytes: copiedBytes, reused: reused
            )
        }

        let (fingerprint, sourceBytes) = try fingerprint(of: source, fileManager: fileManager)
        let stampURL = target.appendingPathComponent(stampFileName)
        if let data = try? Data(contentsOf: stampURL), let stamp = try? JSONDecoder().decode(Stamp.self, from: data),
           stamp.fingerprint == fingerprint,
           fileManager.fileExists(atPath: target.appendingPathComponent("manifest.json").path),
           fileManager.fileExists(atPath: target.appendingPathComponent(ExtensionCompat.preludeFileName).path) {
            return result(popupPatched: stamp.popupPatched, copiedBytes: stamp.copiedBytes, reused: true)
        }

        try fileManager.createDirectory(at: overlays, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        let cloned = try clone(source, to: target, fileManager: fileManager)

        try replaceFile(target.appendingPathComponent("manifest.json"), with: patch.data, fileManager: fileManager)
        try replaceFile(
            target.appendingPathComponent(ExtensionCompat.preludeFileName), with: Data(ExtensionCompat.prelude.utf8),
            fileManager: fileManager
        )

        var popupPatched = false
        if let css, let popup, let popupURL = containedRegularFile(popup, under: target),
           let html = try? Data(contentsOf: popupURL) {
            let patched = ExtensionCompat.insertStyle(css, into: html)
            if patched != html {
                try replaceFile(popupURL, with: patched, fileManager: fileManager)
                popupPatched = true
            }
        }

        // Last, so a half-made overlay is never taken for a finished one.
        let copiedBytes = cloned ? nil : sourceBytes
        let stamp = Stamp(fingerprint: fingerprint, copiedBytes: copiedBytes, popupPatched: popupPatched)
        try JSONEncoder().encode(stamp).write(to: stampURL, options: .atomic)
        return result(popupPatched: popupPatched, copiedBytes: copiedBytes, reused: false)
    }

    /// Deletes the overlays whose names aren't in `keeping` (extension folders that are gone).
    public static func prune(in overlays: URL, keeping names: Set<String>, fileManager: FileManager = .default) {
        let children = (try? fileManager.contentsOfDirectory(atPath: overlays.path)) ?? []
        for child in children where !names.contains(child) {
            try? fileManager.removeItem(at: overlays.appendingPathComponent(child))
        }
    }

    /// Deletes one overlay, if it exists.
    public static func remove(name: String, in overlays: URL, fileManager: FileManager = .default) {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        let target = overlays.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.removeItem(at: target)
    }

    // MARK: - Files

    /// A digest of everything `make` reads or writes: the source path, every entry under it (type, inode, size,
    /// modification and change times, without following symlinks) and the patch recipe. Also the total size of the
    /// regular files, for the copy fallback's status line.
    static func fingerprint(of source: URL, fileManager: FileManager) throws -> (digest: String, bytes: Int64) {
        guard let walk = fileManager.enumerator(atPath: source.path) else { throw MakeError.unreadable(source.path) }
        var entries: [String] = []
        var bytes: Int64 = 0
        for case let relative as String in walk {
            var info = stat()
            guard lstat(source.appendingPathComponent(relative).path, &info) == 0 else {
                entries.append("\(relative)\tgone")
                continue
            }
            if info.st_mode & S_IFMT == S_IFREG { bytes += Int64(info.st_size) }
            entries.append([
                relative, "\(info.st_mode)", "\(info.st_ino)", "\(info.st_size)",
                "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
                "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
            ].joined(separator: "\t"))
        }
        let lines = [
            "recipe \(recipeVersion)", "source \(source.standardizedFileURL.path)",
            "prelude \(ExtensionCompat.prelude)", "css \(ExtensionCompat.protonPassPopupCSS)"
        ] + entries.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return (digest.map { String(format: "%02x", $0) }.joined(), bytes)
    }

    /// `relative` under `root` when it names a regular file reached through real folders only: no `..`, no symlink
    /// at any step (a clone keeps the source's symlinks, which can point anywhere), and still inside `root` once
    /// symlinks are resolved. Nil otherwise, and the caller leaves the file alone.
    static func containedRegularFile(_ relative: String, under root: URL) -> URL? {
        let components = relative.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        var url = root
        for (index, component) in components.enumerated() {
            url = url.appendingPathComponent(component)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            guard kind == (index == components.count - 1 ? S_IFREG : S_IFDIR) else { return nil }
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolved.count > base.count, Array(resolved.prefix(base.count)) == base else { return nil }
        return url
    }

    /// Writes `data` as a new regular file at `url`, removing whatever was there first so a symlink the clone
    /// carried over is replaced rather than written through.
    private static func replaceFile(_ url: URL, with data: Data, fileManager: FileManager) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { try fileManager.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
    }

    /// An APFS clone of the whole folder in one call (true); a plain recursive copy when the volume can't clone or
    /// source and target sit on different volumes (false).
    private static func clone(_ source: URL, to target: URL, fileManager: FileManager) throws -> Bool {
        if clonefile(source.path, target.path, 0) == 0 { return true }
        let why = String(cString: strerror(errno))
        do {
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: source, to: target)
            return false
        } catch {
            throw MakeError.clone("\(why); copy failed too: \(error.localizedDescription)")
        }
    }
}
