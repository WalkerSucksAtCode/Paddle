import CryptoKit
import Foundation

public struct ExtensionOverlayResult: Equatable, Sendable {
    /// Absolute root of the patched clone; what `WKWebExtension` is loaded from.
    public let root: URL
    /// `none` for the wave 4b overlay, else the persona whose v2 prelude it carries.
    public let persona: Persona
    /// The prelude is first in `background.scripts`.
    public let backgroundPatched: Bool
    /// The prelude is first in at least one of the extension's own content scripts.
    public let contentScriptsPatched: Bool
    /// The background kind left as it is (`service_worker` or `page`), if any.
    public let unpatchedBackground: ExtensionCompat.UnpatchedBackground?
    /// v2: the service worker runs through `paddle-sw.js`.
    public let serviceWorkerWrapped: Bool
    /// v2: extension pages (`.html`) that load the prelude first.
    public let pagesTagged: Int
    /// Bytes written when the folder couldn't be cloned (another volume, or a volume without clones) and was copied
    /// in full; nil for an APFS clone.
    public let copiedBytes: Int64?
    /// The overlay from an earlier load was kept because the source folder hasn't changed since.
    public let reused: Bool
    /// Content scripts rewritten to Latin-1 (`ScriptLatin1`), so WebKit keeps them as 8-bit text.
    public let scriptsNarrowed: Int

    init(
        root: URL, persona: Persona = .none, backgroundPatched: Bool, contentScriptsPatched: Bool,
        unpatchedBackground: ExtensionCompat.UnpatchedBackground?, serviceWorkerWrapped: Bool = false,
        pagesTagged: Int = 0, copiedBytes: Int64?, reused: Bool, scriptsNarrowed: Int = 0
    ) {
        self.root = root
        self.persona = persona
        self.backgroundPatched = backgroundPatched
        self.contentScriptsPatched = contentScriptsPatched
        self.unpatchedBackground = unpatchedBackground
        self.serviceWorkerWrapped = serviceWorkerWrapped
        self.pagesTagged = pagesTagged
        self.copiedBytes = copiedBytes
        self.reused = reused
        self.scriptsNarrowed = scriptsNarrowed
    }

    /// The prelude runs in at least one of the extension's contexts.
    public var runsPrelude: Bool { backgroundPatched || contentScriptsPatched || pagesTagged > 0 }

    /// One line for the status list.
    public var statusText: String {
        var notes: [String] = []
        if persona.runsPersonaPrelude {
            if backgroundPatched { notes.append(serviceWorkerWrapped ? "service worker" : "background") }
            if pagesTagged > 0 { notes.append(pagesTagged == 1 ? "1 page" : "\(pagesTagged) pages") }
            if contentScriptsPatched { notes.append("content scripts") }
            if scriptsNarrowed > 0 { notes.append(scriptsNarrowed == 1 ? "1 script in Latin-1" : "\(scriptsNarrowed) scripts in Latin-1") }
            if let copiedBytes { notes.append("copied, \(Self.size(copiedBytes))") }
            let base = "\(persona.rawValue) persona"
            return notes.isEmpty ? base : "\(base) (\(notes.joined(separator: "; ")))"
        }
        let base = "compat prelude applied"
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

/// Patched clone of an extension folder under `extension-overlays/`. `clonefile` on the same APFS
/// volume; otherwise a full copy (status line says so). Kept while the source is unchanged, remade
/// when it changes. Never writes the user's folder; identity, permissions and storage stay keyed by
/// the original folder name. No shared state: safe off the main actor.
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
    static let recipeVersion = 8
    /// Written last into a finished overlay: the source fingerprint it was made from and what it holds.
    static let stampFileName = ".paddle-overlay.json"

    struct Stamp: Codable, Equatable {
        let fingerprint: String
        let copiedBytes: Int64?
        var pagesTagged: Int?
        var scriptsNarrowed: Int?
    }

    /// At most this many `.html` files get the prelude tag, each at most `maxPageBytes`.
    static let maxPages = 2_000
    static let maxPageBytes = 5_000_000

    /// Overlay at `overlays/<name>/`, or the existing one if the source is unchanged. Nil (and any stale
    /// overlay of that name removed) when the extension needs none. Throws if the manifest can't be read or
    /// the clone/patch fails; the caller then loads the original folder.
    ///
    /// - `plan` nil or persona `none`: the wave 4b overlay (none for a Safari build, or one with nowhere to put the
    ///   prelude).
    /// - `native`: no overlay.
    /// - `chrome` / `firefox`: `ExtensionCompat.patchManifest(_:persona:)`, the worker wrapper, the prelude tag in
    ///   every `.html` page, and `paddle-prelude.js` / `paddle-content.js` from `CompatPrelude`. Those two depend on
    ///   the plan, not the folder, so they are rewritten (when different) at every call, kept overlay or not.
    public static func make(
        from source: URL, name: String, in overlays: URL, plan: CompatPlan? = nil, fileManager: FileManager = .default
    ) throws -> ExtensionOverlayResult? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") else { throw MakeError.badName(name) }
        let manifestData = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw ExtensionCompat.PatchError.notAnObject
        }
        let target = overlays.appendingPathComponent(name, isDirectory: true)
        let persona = plan?.persona ?? .none
        let v2 = persona.runsPersonaPrelude
        guard persona != .native, v2 || ExtensionCompat.needsPrelude(manifest: manifest) else {
            remove(name: name, in: overlays, fileManager: fileManager)
            return nil
        }

        // The rewrite is checked before anything is cloned, so a manifest the patch can't handle leaves no overlay.
        let patch = try ExtensionCompat.patchManifest(manifestData, persona: persona)
        guard v2 || patch.preludeApplied else {
            remove(name: name, in: overlays, fileManager: fileManager)
            return nil
        }
        // Generated from the plan, so written at every load; the 4b prelude is fixed text.
        var generated: [(String, String)] = [(ExtensionCompat.preludeFileName, ExtensionCompat.prelude)]
        if v2, let plan {
            generated = [
                (ExtensionCompat.preludeFileName, CompatPrelude.source(for: plan, kind: .full)),
                (ExtensionCompat.contentFileName, CompatPrelude.source(for: plan, kind: .content)),
            ]
        }
        // Latin-1, like the extension's content scripts (`narrowContentScripts`): they carry the manifest's own text.
        generated = generated.map { file, text in
            if case .rewritten(let latin1) = ScriptLatin1.rewrite(text) { (file, latin1) } else { (file, text) }
        }
        func result(pagesTagged: Int, copiedBytes: Int64?, reused: Bool, scriptsNarrowed: Int) -> ExtensionOverlayResult {
            ExtensionOverlayResult(
                root: target.standardizedFileURL, persona: v2 ? persona : .none, backgroundPatched: patch.backgroundPatched,
                contentScriptsPatched: patch.contentScriptsPatched, unpatchedBackground: patch.unpatchedBackground,
                serviceWorkerWrapped: patch.serviceWorkerWrapper != nil || (v2 && isWrapped(manifest)),
                pagesTagged: pagesTagged, copiedBytes: copiedBytes, reused: reused, scriptsNarrowed: scriptsNarrowed
            )
        }

        let (fingerprint, sourceBytes) = try fingerprint(of: source, persona: v2 ? persona : .none, fileManager: fileManager)
        let stampURL = target.appendingPathComponent(stampFileName)
        if let data = try? Data(contentsOf: stampURL), let stamp = try? JSONDecoder().decode(Stamp.self, from: data),
           stamp.fingerprint == fingerprint,
           fileManager.fileExists(atPath: target.appendingPathComponent("manifest.json").path),
           fileManager.fileExists(atPath: target.appendingPathComponent(ExtensionCompat.preludeFileName).path) {
            for (file, text) in generated { try writeIfChanged(target.appendingPathComponent(file), text: text, fileManager: fileManager) }
            return result(
                pagesTagged: stamp.pagesTagged ?? 0, copiedBytes: stamp.copiedBytes, reused: true,
                scriptsNarrowed: stamp.scriptsNarrowed ?? 0
            )
        }

        try fileManager.createDirectory(at: overlays, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        let cloned = try clone(source, to: target, fileManager: fileManager)

        try replaceFile(target.appendingPathComponent("manifest.json"), with: patch.data, fileManager: fileManager)
        for (file, text) in generated {
            try replaceFile(target.appendingPathComponent(file), with: Data(text.utf8), fileManager: fileManager)
        }
        if let wrapper = patch.serviceWorkerWrapper {
            // Next to the worker, which must be a regular file reached through real folders.
            let worker = (manifest["background"] as? [String: Any])?["service_worker"] as? String ?? ""
            guard let workerPath = ExtensionCompat.containedPath(worker), containedRegularFile(workerPath, under: target) != nil else {
                throw MakeError.unreadable(worker)
            }
            try replaceFile(target.appendingPathComponent(wrapper.path), with: Data(wrapper.contents.utf8), fileManager: fileManager)
        }
        let pagesTagged = v2 ? try tagPages(in: target, fileManager: fileManager) : 0
        let scriptsNarrowed = try narrowContentScripts(in: target, manifest: patch.data, fileManager: fileManager)

        // Last, so a half-made overlay is never taken for a finished one.
        let copiedBytes = cloned ? nil : sourceBytes
        let stamp = Stamp(fingerprint: fingerprint, copiedBytes: copiedBytes, pagesTagged: pagesTagged, scriptsNarrowed: scriptsNarrowed)
        try JSONEncoder().encode(stamp).write(to: stampURL, options: .atomic)
        return result(pagesTagged: pagesTagged, copiedBytes: copiedBytes, reused: false, scriptsNarrowed: scriptsNarrowed)
    }

    /// The source manifest's worker is already the wrapper (a folder copied from an overlay).
    private static func isWrapped(_ manifest: [String: Any]) -> Bool {
        let worker = ((manifest["background"] as? [String: Any])?["service_worker"] as? String) ?? ""
        return worker.split(separator: "/").last.map(String.init) == ExtensionCompat.serviceWorkerWrapperName
    }

    /// Puts the prelude's script tag first in every `.html` / `.htm` page under `root` (regular files reached
    /// through real folders, up to `maxPages` of at most `maxPageBytes`). Returns how many pages carry it.
    static func tagPages(in root: URL, fileManager: FileManager) throws -> Int {
        guard let walk = fileManager.enumerator(atPath: root.path) else { throw MakeError.unreadable(root.path) }
        var tagged = 0
        var seen = 0
        for case let relative as String in walk {
            let lower = relative.lowercased()
            guard lower.hasSuffix(".html") || lower.hasSuffix(".htm") else { continue }
            seen += 1
            guard seen <= maxPages else { break }
            guard let url = containedRegularFile(relative, under: root),
                  let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxPageBytes,
                  let html = try? Data(contentsOf: url) else { continue }
            let patched = ExtensionCompat.insertScriptTag(into: html, src: "/" + ExtensionCompat.preludeFileName)
            if patched != html { try replaceFile(url, with: patched, fileManager: fileManager) }
            if patched != html || String(data: html, encoding: .utf8)?.contains(ExtensionCompat.preludeScriptTag()) == true { tagged += 1 }
        }
        return tagged
    }

    /// Rewrites the manifest's content scripts (regular files reached through real folders) to Latin-1 with
    /// `ScriptLatin1`: WebKit sends each to every WebContent process and keeps it 16-bit if one character isn't
    /// Latin-1. Returns how many it rewrote; the others stay as they are.
    static func narrowContentScripts(in root: URL, manifest: Data, fileManager: FileManager) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else { return 0 }
        var paths: Set<String> = []
        for entry in (object["content_scripts"] as? [[String: Any]]) ?? [] {
            for js in (entry["js"] as? [String]) ?? [] { paths.insert(js) }
        }
        var narrowed = 0
        for path in paths.sorted() {
            guard let relative = ExtensionCompat.containedPath(path), let url = containedRegularFile(relative, under: root),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  case .rewritten(let latin1) = ScriptLatin1.rewrite(text) else { continue }
            try replaceFile(url, with: Data(latin1.utf8), fileManager: fileManager)
            narrowed += 1
        }
        return narrowed
    }

    /// Writes `text` to `url` unless the file already holds exactly that.
    private static func writeIfChanged(_ url: URL, text: String, fileManager: FileManager) throws {
        let data = Data(text.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return }
        }
        try replaceFile(url, with: data, fileManager: fileManager)
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
    static func fingerprint(of source: URL, persona: Persona = .none, fileManager: FileManager) throws -> (digest: String, bytes: Int64) {
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
            "recipe \(recipeVersion)", "persona \(persona.rawValue)", "source \(source.standardizedFileURL.path)",
            "prelude \(ExtensionCompat.prelude)"
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
