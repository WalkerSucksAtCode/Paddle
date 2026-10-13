import CryptoKit
import Foundation

/// The file side of a store install, after the package's signatures checked out (`CRX3.verify`) and its ZIP passed
/// `ZipSafety.entries`: unpacking with `ditto`, checking the unpacked folder against the archive, reading the
/// manifest, hashing the files, picking the folder, and swapping it into `extensions/` with the old copy kept until
/// the install is recorded. Anything unexpected is refused.
public enum StoreInstall {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// `ditto` didn't start, failed or took too long.
        case unpackFailed(String)
        /// No regular `manifest.json` at the top of the package.
        case noManifest
        /// `manifest.json` isn't a JSON object.
        case manifestUnreadable
        /// The manifest's `key` is for a different extension than the package's signature.
        case keyMismatch
        /// A file in the unpacked folder couldn't be read for its hash.
        case unreadableFile(String)
        /// The staging folder already exists.
        case stagingExists

        public var errorDescription: String? {
            switch self {
            case .unpackFailed(let why): "unpacking failed (\(why))"
            case .noManifest: "the package has no manifest.json at its top"
            case .manifestUnreadable: "the package's manifest.json isn't readable JSON"
            case .keyMismatch: "the manifest's key is for a different extension"
            case .unreadableFile(let path): "a file in the package can't be read: \(path)"
            case .stagingExists: "a previous install left its working folder behind; try again"
            }
        }
    }

    /// An unpacked, checked package waiting in its staging folder.
    public struct Package: Sendable, Equatable {
        /// The Chrome id the signatures were checked for.
        public let id: String
        /// The manifest's name with `__MSG_…__` resolved, else `id`. Extension text: sanitize before showing it.
        public let displayName: String
        public let version: String?
        /// The staging folder holding the unpacked files (`manifest.json` at its top).
        public let folder: URL
        /// SHA-256 (lowercase hex) of every regular file, by path inside `folder`.
        public let fileHashes: [String: String]
    }

    /// What installing a package would do.
    public enum Plan: Equatable, Sendable {
        /// A new folder.
        case install(folder: String)
        /// The same id and version is already in `folder`.
        case alreadyInstalled(folder: String, version: String?)
        /// The same id, another version: replace `folder` once the user agrees.
        case replace(folder: String, oldVersion: String?, newVersion: String?)
    }

    // MARK: - Unpack

    /// Unpacks `zip` (whose `entries` passed `ZipSafety.entries`) into `staging`, which must not exist yet, through a
    /// file in `scratch`. Then: the folder must hold exactly `entries` (`ZipSafety.verifyUnpacked`); permissions
    /// are reset to 0644 files and 0755 folders; `manifest.json` must be a regular file at the top holding a JSON
    /// object; for a Chrome Web Store package, a manifest `key`, if any, must be `id`'s (add-ons carry Chrome keys in
    /// cross-browser builds, and their signature is checked elsewhere). The caller deletes `staging` and `scratch` whatever
    /// happens.
    public static func unpack(
        zip: Data, entries: [ZipSafety.Entry], store: Persona.Source, id: String, into staging: URL, scratch: URL,
        fileManager: FileManager = .default, timeout: TimeInterval = 120
    ) throws -> Package {
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let zipURL = scratch.appending(path: "package.zip")
        try zip.write(to: zipURL, options: .withoutOverwriting)
        guard !fileManager.fileExists(atPath: staging.path) else { throw Failure.stagingExists }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw Failure.stagingExists
        }
        try runDitto(zip: zipURL, into: staging, timeout: timeout)
        try ZipSafety.verifyUnpacked(staging, matches: entries, fileManager: fileManager)
        try normalizePermissions(staging, fileManager: fileManager)

        let manifestURL = staging.appending(path: "manifest.json")
        guard (try? fileManager.attributesOfItem(atPath: manifestURL.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw Failure.noManifest
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.manifestUnreadable }
        if store == .chromeWebStore, let key = manifest["key"] {
            guard let key = key as? String, ExtensionIdentity.chromeID(manifestKey: key) == id.lowercased() else { throw Failure.keyMismatch }
        }
        let name = displayName(manifest: manifest, root: staging)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Package(
            id: id.lowercased(),
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? id.lowercased(),
            version: manifest["version"] as? String,
            folder: staging,
            fileHashes: try fileHashes(in: staging, fileManager: fileManager)
        )
    }

    /// `/usr/bin/ditto -x -k --norsrc <zip> <folder>`, no shell, an empty environment; killed after `timeout`.
    static func runDitto(zip: URL, into folder: URL, timeout: TimeInterval) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", zip.path, folder.path]
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw Failure.unpackFailed("ditto didn't start")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw Failure.unpackFailed("ditto took over \(Int(timeout)) s")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.unpackFailed("ditto exit status \(process.terminationStatus)")
        }
    }

    /// Files 0644, folders 0755: no executable, setuid or unreadable bits from the archive survive.
    static func normalizePermissions(_ folder: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard let enumerator = fileManager.enumerator(atPath: folder.path) else { throw Failure.unreadableFile("the folder itself") }
        while let path = enumerator.nextObject() as? String {
            let isDirectory = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            try fileManager.setAttributes([.posixPermissions: isDirectory ? 0o755 : 0o644], ofItemAtPath: folder.appending(path: path).path)
        }
    }

    // MARK: - Manifest

    /// The manifest's `name`, with a `__MSG_key__` looked up in `_locales/<default_locale>/messages.json` (keys
    /// compare case-insensitively, as in Chrome). Nil when there is no name or the message can't be found.
    public static func displayName(manifest: [String: Any], root: URL) -> String? {
        guard let name = manifest["name"] as? String else { return nil }
        return localized(name, manifest: manifest, root: root)
    }

    /// `value` itself, or the message it names when it is `__MSG_key__`.
    public static func localized(_ value: String, manifest: [String: Any], root: URL) -> String? {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        guard let locale = manifest["default_locale"] as? String, isLocaleFolder(locale) else { return nil }
        let url = root.appending(path: "_locales").appending(path: locale).appending(path: "messages.json")
        guard let data = try? Data(contentsOf: url),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let match = messages.keys.sorted().first { $0.lowercased() == key }
        return match.flatMap { (messages[$0] as? [String: Any])?["message"] as? String }
    }

    /// `en`, `en_US`, `pt_BR`: letters, digits, `_` and `-`, so it can't leave `_locales/`.
    static func isLocaleFolder(_ locale: String) -> Bool {
        (1...20).contains(locale.count)
            && locale.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    // MARK: - Hashes

    /// SHA-256 (lowercase hex) of every regular file under `folder`, by path inside it.
    public static func fileHashes(in folder: URL, fileManager: FileManager = .default) throws -> [String: String] {
        guard let enumerator = fileManager.enumerator(atPath: folder.path) else { throw Failure.unreadableFile("the folder itself") }
        var hashes: [String: String] = [:]
        while let path = enumerator.nextObject() as? String {
            guard (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeRegular else { continue }
            guard let data = try? Data(contentsOf: folder.appending(path: path), options: .mappedIfSafe) else {
                throw Failure.unreadableFile(path)
            }
            hashes[path.precomposedStringWithCanonicalMapping] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    /// Paths whose hash differs between what was installed and what is there now (changed, removed or added),
    /// sorted. Empty when nothing was recorded.
    public static func changedFiles(recorded: [String: String], current: [String: String]) -> [String] {
        guard !recorded.isEmpty else { return [] }
        return Set(recorded.keys).union(current.keys).filter { recorded[$0] != current[$0] }.sorted()
    }

    // MARK: - Plan

    /// Install into a new folder named from `displayName`, or replace the folder already holding `id` from
    /// `store` (when that folder still exists), or nothing when it holds the same version.
    public static func plan(
        id: String, store: Persona.Source, version: String?, displayName: String, sources: ExtensionSources,
        existingFolders: Set<String>
    ) -> Plan {
        if let folder = sources.folder(forStoreID: id, store: store), existingFolders.contains(folder) {
            let old = sources.records[folder]?.version
            if let old, old == version { return .alreadyInstalled(folder: folder, version: old) }
            return .replace(folder: folder, oldVersion: old, newVersion: version)
        }
        return .install(folder: ExtensionSources.folderName(forDisplayName: displayName, existing: existingFolders))
    }

    // MARK: - Swap

    /// Moves `staged` to `destination`. When `destination` exists it is moved to `aside` first, and moved back if
    /// the move in fails. Returns whether the old copy is now at `aside`: delete it with `finish` once the install
    /// is recorded, or put it back with `rollBack`.
    public static func swapIn(staged: URL, destination: URL, aside: URL, fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: staged, to: destination)
            return false
        }
        try fileManager.moveItem(at: destination, to: aside)
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            try? fileManager.moveItem(at: aside, to: destination)
            throw error
        }
        return true
    }

    /// Undoes `swapIn`: deletes the new `destination` and, when there was an old copy, moves it back.
    public static func rollBack(destination: URL, aside: URL, hadOld: Bool, fileManager: FileManager = .default) throws {
        try fileManager.removeItem(at: destination)
        if hadOld { try fileManager.moveItem(at: aside, to: destination) }
    }

    // MARK: - Store pages

    /// The extension's name from a Chrome Web Store page title ("SponsorBlock - Chrome Web Store"); nil when the
    /// title has none.
    public static func storePageName(title: String) -> String? {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Chrome Web Store", " – Chrome Web Store", " — Chrome Web Store"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty || name == "Chrome Web Store" ? nil : name
    }
}
