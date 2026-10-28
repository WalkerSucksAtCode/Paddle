import AppKit
import os
import PaddleCore

/// Install from the Chrome Web Store or AMO (Extensions > Install from Link…, or the bar on a store
/// page). Chrome: Google's update service, then `CRX3.verify` (Web Store signature and developer key).
/// AMO: lookup, SHA-256 of the file, `AMO.verifySignature`. Both then `ZipSafety`, `StoreInstall.unpack`,
/// swap into `extensions/`, record in `extension-sources.json`, and hand to `ExtensionHost` (load +
/// permission prompt). A failed check leaves nothing behind. Updates reuse the same downloads, checks
/// and `place` (`ExtensionUpdater`).
@Observable
final class StoreInstaller {
    static let shared = StoreInstaller()

    enum Outcome: Equatable {
        case installed(name: String, version: String?, verified: Bool)
        case updated(name: String, version: String?, verified: Bool)
        case alreadyInstalled(name: String, version: String?)
        case cancelled
        case failed(String)

        /// A sentence for the panel, the bar and VoiceOver.
        var message: String {
            switch self {
            case .installed(let name, let version, let verified):
                "Installed \(Self.label(name, version))\(Self.note(verified)). It will ask for its permissions next."
            case .updated(let name, let version, let verified):
                "Updated \(Self.label(name, version))\(Self.note(verified)). It will ask again if it wants more permissions."
            case .alreadyInstalled(let name, let version):
                "\(Self.label(name, version)) is already installed."
            case .cancelled:
                "Cancelled. Nothing was changed."
            case .failed(let reason):
                reason
            }
        }

        var succeeded: Bool {
            switch self {
            case .installed, .updated, .alreadyInstalled: true
            case .cancelled, .failed: false
            }
        }

        private static func label(_ name: String, _ version: String?) -> String {
            version.map { "\(name) \(ExtensionPermissionText.sanitize($0, max: 30))" } ?? name
        }

        /// Said after an install or update whose certificate chain wasn't checked.
        private static func note(_ verified: Bool) -> String {
            verified ? "" : " without checking Mozilla's certificate"
        }
    }

    /// A refusal: why a package or a change isn't used, as a sentence. The caller adds "Not installed:" or "not updated:".
    struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A package that passed its store's checks and is unpacked in the staging folder, with what its record needs.
    struct Checked {
        let store: Persona.Source
        /// The Chrome id, or the add-on's guid.
        let id: String
        /// The add-on's slug as its install link named it (`ExtensionSources.Record.slug`); nil for Chrome.
        let slug: String?
        let package: StoreInstall.Package
        /// Whether the signature chain was checked (`ExtensionSources.Record.verified`).
        let verified: Bool

        var site: StoreSite { store == .mozillaAddons ? .addonsMozilla : .chromeWebStore }
    }

    /// `extension-sources.json` as last read or written.
    private(set) var sources = ExtensionSources()
    /// The file is unreadable: installs are refused, the host ignores it, and it is never overwritten.
    private(set) var sourcesError: String?
    /// The store link being installed now; one install at a time.
    private(set) var installing: StoreLink?
    /// The last outcome's message per store link, for the store-page bar.
    private(set) var lastMessage: [StoreLink: String] = [:]

    @ObservationIgnored private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    // MARK: - extension-sources.json

    /// Reads `extension-sources.json`; a missing file is empty.
    func reloadSources() {
        guard FileManager.default.fileExists(atPath: Paths.extensionSources.path) else {
            sources = ExtensionSources()
            sourcesError = nil
            return
        }
        do {
            sources = try ExtensionSources.decode(Data(contentsOf: Paths.extensionSources))
            sourcesError = nil
        } catch {
            sources = ExtensionSources()
            sourcesError = "extension-sources.json is unreadable (\(error.localizedDescription)). Fix or delete it, then try again."
            log.error("extension-sources.json unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The record for an extension folder, when it came from a store (none while the file is unreadable).
    func record(forFolder folder: String) -> ExtensionSources.Record? {
        sourcesError == nil ? sources.records[folder] : nil
    }

    /// Every install record by folder (none while the file is unreadable).
    var allRecords: [String: ExtensionSources.Record] {
        sourcesError == nil ? sources.records : [:]
    }

    /// Whether a folder holds this store extension: a Chrome id, or an add-on's slug or guid, from its own store
    /// (`ExtensionSources.folder(forStoreID:store:)`).
    func isInstalled(_ link: StoreLink) -> Bool {
        sources.folder(forStoreID: link.storeID, store: link.source) != nil
    }

    /// Drops records of folders that are gone (`ExtensionHost` calls this with the folders it found).
    func pruneSources(keeping folders: Set<String>) {
        guard sourcesError == nil else { return }
        var pruned = sources
        guard pruned.prune(keeping: folders) else { return }
        do {
            try writeSources(pruned)
            log.info("extension-sources.json: records of removed folders dropped")
        } catch {
            log.error("extension-sources.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeSources(_ updated: ExtensionSources) throws {
        // Through a symlink, as config.json is written: an atomic write to the link itself would replace it with a file.
        try updated.encoded().write(to: Paths.extensionSources.resolvingSymlinksInPath(), options: .atomic)
        sources = updated
    }

    // MARK: - Install

    /// Installs the extension `link` names. `window` hosts the questions, if any.
    func install(_ link: StoreLink, window: NSWindow?) async -> Outcome {
        guard installing == nil else {
            return .failed("Another extension is being installed. Try again when it's done.")
        }
        guard !ExtensionUpdater.shared.checking else {
            return .failed("Extensions are being checked for updates. Try again when that's done.")
        }
        installing = link
        defer { installing = nil }
        let outcome: Outcome
        do {
            outcome = try await run(link, window: window)
        } catch _ where Task.isCancelled {
            log.info("store install \(link.storeID, privacy: .public): cancelled")
            outcome = .cancelled
        } catch let refusal as Refusal {
            log.error("store install \(link.storeID, privacy: .public) refused: \(refusal.message, privacy: .public)")
            outcome = .failed("Not installed: \(refusal.message)")
        } catch {
            log.error("store install \(link.storeID, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            outcome = .failed("Not installed: \(error.localizedDescription).")
        }
        lastMessage[link] = outcome.message
        return outcome
    }

    /// The non-default profile of the browser window an install started from (or the window its sheet is on); nil
    /// for the default profile, a private window or no browser window.
    private static func profile(of window: NSWindow?) -> ProfileID? {
        let browser = (window?.windowController as? BrowserWindowController)
            ?? (window?.sheetParent?.windowController as? BrowserWindowController)
        guard let browser, !browser.model.isPrivate, browser.model.profileID != ProfileStore.defaultID else { return nil }
        return browser.model.profileID
    }

    private func run(_ link: StoreLink, window: NSWindow?) async throws -> Outcome {
        reloadSources()
        if let sourcesError { throw Refusal(sourcesError) }

        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.extensions, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8).lowercased()
        // Names starting with "." are skipped by the folder scan, so a half-made folder never loads.
        let staging = Paths.extensions.appending(path: ".installing-\(token)", directoryHint: .isDirectory)
        let scratch = fm.temporaryDirectory.appending(path: "Paddle-store-\(token)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: scratch)
        }

        let checked: Checked
        switch link {
        case .chromeWebStore(let id):
            checked = try await fetchChrome(id: id, staging: staging, scratch: scratch)
        case .mozillaAddons(let slug):
            let addon = try await lookupAddon(slug: slug)
            checked = try await fetchAddon(addon, slug: slug, staging: staging, scratch: scratch)
        }

        // Cancelled while it downloaded or unpacked: stop before anything in extensions/ changes.
        try Task.checkCancellation()
        // Read again: the file may have changed during the download.
        reloadSources()
        if let sourcesError { throw Refusal(sourcesError) }
        let existing = Set((try? fm.contentsOfDirectory(atPath: Paths.extensions.path)) ?? [])
        let package = checked.package
        let name = ExtensionPermissionText.sanitize(package.displayName)
        let folder: String
        var replacing = false
        switch StoreInstall.plan(
            id: checked.id, store: checked.store, version: package.version, displayName: package.displayName,
            sources: sources, existingFolders: existing
        ) {
        case .alreadyInstalled(let installedFolder, let version):
            log.info("store install \(checked.id, privacy: .public): same version already installed")
            // An add-on installed before slugs were recorded gets its slug now, so its store page shows it as installed.
            if let slug = checked.slug { changeRecord(installedFolder) { $0.slug = $0.slug ?? slug } }
            return .alreadyInstalled(name: name, version: version)
        case .install(let newFolder):
            folder = newFolder
        case .replace(let oldFolder, let oldVersion, let newVersion):
            let changed = await changedFiles(in: oldFolder)
            guard await confirmReplace(
                checked, name: name, oldVersion: oldVersion, newVersion: newVersion, changed: changed, window: window
            ) else {
                return .cancelled
            }
            // An older version, even a validly signed one, may carry a fixed flaw: the user must say so.
            if ExtensionVersion.isDowngrade(from: oldVersion, to: newVersion, store: checked.store) {
                guard await confirmOlder(name: name, oldVersion: oldVersion, newVersion: newVersion, window: window) else {
                    return .cancelled
                }
            }
            try Task.checkCancellation()
            folder = oldFolder
            replacing = true
        }
        if !checked.verified {
            guard await confirmUnverified(name: name, version: package.version, window: window) else { return .cancelled }
            try Task.checkCancellation()
            log.notice("store install \(checked.id, privacy: .public): installing without a verified certificate chain")
        }

        try place(
            package, into: folder, store: checked.store, id: checked.id, slug: checked.slug, verified: checked.verified, token: token
        )
        log.info("store install \(checked.id, privacy: .public): \(replacing ? "updated" : "installed", privacy: .public) into \(folder, privacy: .public), version \(package.version ?? "none", privacy: .public), verified \(checked.verified, privacy: .public)")

        // The normal flow takes over: the host scans, loads it and asks for its permissions. A replaced folder that
        // was running is unloaded first so the new files load.
        let reload: Set<String> = replacing ? [folder] : []
        let profile = Self.profile(of: window)
        Task {
            // A new extension installed from another profile's window runs only there: on in that profile, off in
            // the default one (config.json), before the hosts reconcile.
            if !replacing, let profile { await AppModel.shared.installOnlyInProfile(folder: folder, profile: profile) }
            await AppModel.shared.reconcileExtensions(reloading: reload)
        }
        return replacing
            ? .updated(name: name, version: package.version, verified: checked.verified)
            : .installed(name: name, version: package.version, verified: checked.verified)
    }

    /// Puts the unpacked `package` in `extensions/<folder>` and records it in `extension-sources.json`. An old copy in the
    /// folder is moved aside until the record is written, then deleted; if the record can't be written, the old copy goes
    /// back. Nothing awaits in here, so no load or reconcile can see the folder half-swapped. Used by installs and by
    /// `ExtensionUpdater`, which add their own "Not installed" or "not updated" to the refusal.
    func place(
        _ package: StoreInstall.Package, into folder: String, store: Persona.Source, id: String, slug: String?, verified: Bool,
        token: String
    ) throws {
        let destination = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        let aside = Paths.extensions.appending(path: ".replaced-\(folder)-\(token)", directoryHint: .isDirectory)
        let hadOld: Bool
        do {
            hadOld = try StoreInstall.swapIn(staged: package.folder, destination: destination, aside: aside)
        } catch {
            throw Refusal("the extension couldn't be moved into place (\(error.localizedDescription)). Nothing was changed.")
        }
        var updated = sources
        updated.recordInstall(
            folder: folder, store: store, id: id, version: package.version, fileHashes: package.fileHashes,
            verified: verified, slug: slug, now: Date()
        )
        do {
            try writeSources(updated)
        } catch {
            do {
                try StoreInstall.rollBack(destination: destination, aside: aside, hadOld: hadOld)
            } catch {
                log.fault("store \(id, privacy: .public): rollback failed: \(error.localizedDescription, privacy: .public)")
                throw Refusal("extension-sources.json couldn't be written, and undoing the change failed. Check extensions/\(folder) (the previous copy may be in extensions/.replaced-\(folder)-\(token)).")
            }
            throw Refusal("extension-sources.json couldn't be written (\(error.localizedDescription)). Nothing was changed.")
        }
        if hadOld {
            do {
                try FileManager.default.removeItem(at: aside)
            } catch {
                log.error("store \(id, privacy: .public): old copy not deleted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Changes one folder's record in `extension-sources.json` and writes the file. Nothing changes when the folder has no
    /// record or the file is unreadable.
    func changeRecord(_ folder: String, _ change: (inout ExtensionSources.Record) -> Void) {
        reloadSources()
        guard sourcesError == nil, var record = sources.records[folder] else { return }
        change(&record)
        var updated = sources
        updated.records[folder] = record
        do {
            try writeSources(updated)
        } catch {
            log.error("extension-sources.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Adoption of hand-installed add-ons

    /// Records the hand-installed folder as tracked (`ExtensionSources.adopt`): the add-on `guid` must be the gecko id of
    /// the folder's manifest. The file hashes are those an install records, taken from the folder as it is now. Returns
    /// the reason it failed, or nil when the record is written.
    func adopt(folder: String, guid: String, slug: String?) async -> String? {
        reloadSources()
        if let problem = sourcesError { return problem }
        guard sources.records[folder] == nil else { return "it already has an update record" }
        let url = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        guard let manifestData = try? Data(contentsOf: url.appending(path: "manifest.json")),
              ExtensionAdoption.geckoID(manifest: manifestData) == guid else {
            return "the folder's manifest doesn't name the add-on's id"
        }
        let version = ((try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any])?["version"] as? String
        guard let hashes = await Task.detached(priority: .userInitiated, operation: { try? StoreInstall.fileHashes(in: url) }).value else {
            return "its files couldn't be read"
        }
        reloadSources()
        if let problem = sourcesError { return problem }
        guard sources.records[folder] == nil, FileManager.default.fileExists(atPath: url.path) else {
            return "the folder changed meanwhile"
        }
        var updated = sources
        updated.adopt(folder: folder, guid: guid, slug: slug, version: version, fileHashes: hashes, now: Date())
        do {
            try writeSources(updated)
        } catch {
            return "extension-sources.json couldn't be written (\(error.localizedDescription))"
        }
        return nil
    }

    /// Adds `folder` to `declinedAdoption` so it isn't offered again. Returns false when the file couldn't be written.
    @discardableResult
    func declineAdoption(folder: String) -> Bool {
        reloadSources()
        guard sourcesError == nil else { return false }
        var updated = sources
        updated.declineAdoption(folder: folder)
        do { try writeSources(updated) } catch { return false }
        return true
    }

    /// Stop Updating: removes an adopted folder's record and adds it to `declinedAdoption`. Returns false when it isn't
    /// an adopted folder or the file couldn't be written.
    func stopUpdating(folder: String) -> Bool {
        reloadSources()
        guard sourcesError == nil else { return false }
        var updated = sources
        guard updated.stopAdopted(folder: folder) else { return false }
        do { try writeSources(updated) } catch { return false }
        return true
    }

    /// Downloads the Chrome Web Store package for `id`, checks Google's signature, the developer's key and the ZIP, and
    /// unpacks it into `staging`.
    func fetchChrome(id: String, staging: URL, scratch: URL) async throws -> Checked {
        guard let url = StoreLink.chromeDownloadURL(id: id) else {
            throw Refusal("Paddle couldn't make the download address for this extension.")
        }
        log.info("store install \(id, privacy: .public): download start")
        let data = try await download(url, maxBytes: CRX3.maxFileSize, site: .chromeWebStore)
        log.info("store install \(id, privacy: .public): download finished, \(data.count, privacy: .public) bytes")

        let log = self.log
        let package: StoreInstall.Package
        do {
            package = try await Task.detached(priority: .userInitiated) {
                let verified = try CRX3.verify(data, expectedID: id, publisherKeyHashes: [CRX3.webStorePublisherKeyHash])
                log.info("store install \(id, privacy: .public): publisher signature verified")
                let entries = try ZipSafety.entries(in: verified.zip)
                return try StoreInstall.unpack(
                    zip: verified.zip, entries: entries, store: .chromeWebStore, id: id, into: staging, scratch: scratch
                )
            }.value
        } catch let error as LocalizedError {
            throw Refusal("\(error.errorDescription ?? "the package failed a check").")
        }
        return Checked(store: .chromeWebStore, id: id, slug: nil, package: package, verified: true)
    }

    /// Looks `slug` up on addons.mozilla.org: one request, answered with the add-on's guid and its current file
    /// (`AMO.decodeAddon`). Installs and updates both use the answer, so the store is asked once per check.
    func lookupAddon(slug: String) async throws -> AMO.Addon {
        guard let lookup = AMO.apiURL(storeID: slug) else { throw AMO.Failure.badID }
        log.info("store install \(slug, privacy: .public): lookup start")
        let answer = try await download(lookup, maxBytes: AMO.maxLookupSize, site: .addonsMozilla)
        let addon = try AMO.decodeAddon(answer, requested: slug)
        log.info("store install \(slug, privacy: .public): lookup answered for \(addon.guid, privacy: .public)")
        return addon
    }

    /// Downloads the file `addon` names (from `lookupAddon`). The file must match the lookup's size and SHA-256, pass the
    /// ZIP checks, carry a signature that checks out (`AMO.verifySignature`, against the bundled root when there is one),
    /// and name the add-on's guid as its gecko id. `slug` is the slug the install link named, recorded with the install
    /// (nil when there is none). The signature check reads unpacked bytes, so the file is unpacked into `staging` first;
    /// nothing in `extensions/` changes until the install is recorded.
    func fetchAddon(_ addon: AMO.Addon, slug: String?, staging: URL, scratch: URL) async throws -> Checked {
        let file = try await download(addon.fileURL, maxBytes: CRX3.maxFileSize, site: .addonsMozilla)
        log.info("store install \(addon.guid, privacy: .public): download finished, \(file.count, privacy: .public) bytes")
        try AMO.checkDownload(file, for: addon)
        let entries = try ZipSafety.entries(in: file)

        let log = self.log
        let guid = addon.guid
        let (package, trust) = try await Task.detached(priority: .userInitiated) {
            let package = try StoreInstall.unpack(
                zip: file, entries: entries, store: .mozillaAddons, id: guid, into: staging, scratch: scratch
            )
            let signed = try AMO.verifySignature(
                files: try AMO.readFiles(in: package.folder), guid: guid, anchor: AMO.bundledRootCertificate()
            )
            let manifestData = try Data(contentsOf: package.folder.appending(path: "manifest.json"))
            guard let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
                  AMO.manifestNamesGUID(manifest, guid: guid) else { throw AMO.Failure.manifestID }
            log.info("store install \(guid, privacy: .public): signature checked, certificate chain \(signed.trust == .verified ? "verified" : "not verified", privacy: .public)")
            return (package, signed.trust)
        }.value
        return Checked(store: .mozillaAddons, id: guid, slug: slug, package: package, verified: trust == .verified)
    }

    /// `StoreDownload.fetch`, with its failure as the refusal it reads as.
    func download(_ url: URL, maxBytes: Int, site: StoreSite) async throws -> Data {
        do {
            return try await StoreDownload.fetch(url, maxBytes: maxBytes, site: site)
        } catch let failure as StoreDownload.Failure {
            throw Refusal("\(failure.message).")
        }
    }

    /// Files in `folder` that differ from what was installed there, off the main actor.
    func changedFiles(in folder: String) async -> [String] {
        let recorded = sources.records[folder]?.fileHashes ?? [:]
        guard !recorded.isEmpty else { return [] }
        let url = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        let current = await Task.detached(priority: .userInitiated) { try? StoreInstall.fileHashes(in: url) }.value
        guard let current else { return [] }
        return StoreInstall.changedFiles(recorded: recorded, current: current)
    }

    private func confirmReplace(
        _ checked: Checked, name: String, oldVersion: String?, newVersion: String?, changed: [String], window: NSWindow?
    ) async -> Bool {
        let old = ExtensionPermissionText.sanitize(oldVersion ?? "(no version)", max: 30)
        let new = ExtensionPermissionText.sanitize(newVersion ?? "(no version)", max: 30)
        let alert = NSAlert()
        alert.messageText = "Replace \(name) \(old) with \(new)?"
        let checks = checked.verified
            ? "passed its signature checks"
            : "passed its hash and signature checks, but Mozilla's certificate isn't confirmed yet"
        var info = "The new version comes from \(checked.site.name) and \(checks). "
            + "Its settings and saved data stay."
        if !changed.isEmpty {
            info += " You changed \(changed.count) file\(changed.count == 1 ? "" : "s") in its folder; they will be replaced."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return await respond(alert, window: window) == .alertFirstButtonReturn
    }

    /// The question before an older version replaces a newer one: it may still have a flaw the newer one fixed.
    private func confirmOlder(name: String, oldVersion: String?, newVersion: String?, window: NSWindow?) async -> Bool {
        let installed = ExtensionPermissionText.sanitize(oldVersion ?? "(no version)", max: 30)
        let older = ExtensionPermissionText.sanitize(newVersion ?? "(no version)", max: 30)
        let alert = NSAlert()
        alert.messageText = "Replace \(name) \(installed) with the older \(older)?"
        alert.informativeText = "The version you have is newer. Older versions can still have security problems that newer ones fixed."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return await respond(alert, window: window) == .alertFirstButtonReturn
    }

    /// The question before an add-on whose certificate chain couldn't be checked installs: Paddle checked its file hash
    /// and signature, not Mozilla's certificate. Nothing is installed unless the user agrees.
    private func confirmUnverified(name: String, version: String?, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = version.map { "\(name) \(ExtensionPermissionText.sanitize($0, max: 30)) from addons.mozilla.org" }
            ?? "\(name) from addons.mozilla.org"
        alert.informativeText = "Paddle checked Mozilla's file hash and signature but can't yet confirm Mozilla's certificate. Install anyway?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return await respond(alert, window: window) == .alertFirstButtonReturn
    }

    /// Shows `alert` as a sheet on `window` when the window has no sheet showing, else as a modal alert.
    private func respond(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

/// The store sites a download may use: each one's own hosts, and the names its messages give.
nonisolated enum StoreSite: Sendable {
    case chromeWebStore, addonsMozilla

    /// What the messages call the site.
    var name: String { self == .chromeWebStore ? "the Chrome Web Store" : "addons.mozilla.org" }

    /// What the messages call the servers that `allows` accepts.
    var servers: String { self == .chromeWebStore ? "Google's download servers" : "Mozilla's download servers" }

    /// Whether a download may use `url`: the answer's own address, and each redirect's.
    func allows(_ url: URL) -> Bool {
        self == .chromeWebStore ? StoreLink.isAllowedChromeDownloadRedirect(url) : AMO.isAllowedAMODownload(url)
    }
}

/// One store download: an ephemeral session (no cookies, cache or credentials), a 60 s limit, a size cap enforced
/// while the bytes arrive, and redirects only to the site's own download servers over https.
nonisolated final class StoreDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: Error {
        let message: String
    }

    private let maxBytes: Int
    private let site: StoreSite
    private let lock = NSLock()
    private var received = Data()
    private var failure: Failure?
    private var redirects = 0
    private var continuation: CheckedContinuation<Data, any Error>?
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    private init(maxBytes: Int, site: StoreSite) {
        self.maxBytes = maxBytes
        self.site = site
    }

    static func fetch(_ url: URL, maxBytes: Int, site: StoreSite) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure(message: "the download address isn't https") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        let delegate = StoreDownload(maxBytes: maxBytes, site: site)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: URLRequest(url: url))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Records the first failure and stops the task.
    private func fail(_ message: String, _ task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = Failure(message: message) } }
        task.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let count = lock.withLock { redirects += 1; return redirects }
        guard let url = request.url, count <= 5, site.allows(url) else {
            let host = request.url?.host ?? "an unknown address"
            log.error("store download: redirect to \(host, privacy: .public) refused")
            completionHandler(nil)
            fail(count > 5 ? "too many redirects" : "the download was redirected to \(host), which isn't one of \(site.servers)", task)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let url = http.url, site.allows(url) else {
            completionHandler(.cancel)
            fail("the answer didn't come from \(site.servers)", dataTask)
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            let nothing = site == .chromeWebStore
                ? "the Chrome Web Store has no download for this extension (it may be removed or not offered for this browser)"
                : "addons.mozilla.org has nothing at that address (the add-on may be removed or not listed for Firefox)"
            fail(http.statusCode == 204 || http.statusCode == 404 ? nothing : "\(site.name) answered with error \(http.statusCode)", dataTask)
            return
        }
        guard response.expectedContentLength <= Int64(maxBytes) else {
            completionHandler(.cancel)
            fail("the download is over \(maxBytes / 1_048_576) MB", dataTask)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock {
            guard received.count + data.count <= maxBytes else { return true }
            received.append(data)
            return false
        }
        if tooLarge { fail("the download is over \(maxBytes / 1_048_576) MB", dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        session.finishTasksAndInvalidate()
        let (continuation, failure, data) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.failure, self.received)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            let message = (error as? URLError)?.code == .timedOut ? "the download took over 60 seconds" : "the download failed (\(error.localizedDescription))"
            continuation?.resume(throwing: Failure(message: message))
        } else if data.isEmpty {
            continuation?.resume(throwing: Failure(message: "the download was empty"))
        } else {
            continuation?.resume(returning: data)
        }
    }
}
