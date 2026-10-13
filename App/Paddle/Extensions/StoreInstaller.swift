import AppKit
import os
import PaddleCore

/// Installs extensions from the Chrome Web Store (Extensions > Install from Link…, or the bar on a store page):
/// downloads the CRX3 from Google's update service, checks Google's Web Store signature and the developer's key
/// (`CRX3.verify`), checks the ZIP (`ZipSafety`), unpacks and checks it (`StoreInstall.unpack`), swaps it into
/// `extensions/`, records it in `extension-sources.json`, and hands over to `ExtensionHost`, which loads it and asks
/// for its permissions as for any folder. Anything that fails a check is refused and nothing is left behind.
@Observable
final class StoreInstaller {
    static let shared = StoreInstaller()

    enum Outcome: Equatable {
        case installed(name: String, version: String?)
        case updated(name: String, version: String?)
        case alreadyInstalled(name: String, version: String?)
        case cancelled
        case failed(String)

        /// A sentence for the panel, the bar and VoiceOver.
        var message: String {
            switch self {
            case .installed(let name, let version):
                "Installed \(Self.label(name, version)). It will ask for its permissions next."
            case .updated(let name, let version):
                "Updated \(Self.label(name, version)). It will ask again if it wants more permissions."
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
    }

    /// A refusal with text the user can read.
    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// `extension-sources.json` as last read or written.
    private(set) var sources = ExtensionSources()
    /// The file is unreadable: installs are refused, the host ignores it, and it is never overwritten.
    private(set) var sourcesError: String?
    /// The Chrome id being installed now; one install at a time.
    private(set) var installing: String?
    /// The last outcome's message per Chrome id, for the store-page bar.
    private(set) var lastMessage: [String: String] = [:]

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

    /// Whether a folder holds this Chrome Web Store id.
    func isInstalled(chromeID id: String) -> Bool {
        sources.folder(forStoreID: id, store: .chromeWebStore) != nil
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
        try updated.encoded().write(to: Paths.extensionSources, options: .atomic)
        sources = updated
    }

    // MARK: - Install

    /// Installs the extension `link` names. `window` hosts the replace question, if any.
    func install(_ link: StoreLink, window: NSWindow?) async -> Outcome {
        guard case .chromeWebStore(let id) = link else {
            return .failed("Firefox add-on installs aren't available yet.")
        }
        guard installing == nil else {
            return .failed("Another extension is being installed. Try again when it's done.")
        }
        installing = id
        defer { installing = nil }
        let outcome: Outcome
        do {
            outcome = try await run(id: id, window: window)
        } catch _ where Task.isCancelled {
            log.info("store install \(id, privacy: .public): cancelled")
            outcome = .cancelled
        } catch let refusal as Refusal {
            log.error("store install \(id, privacy: .public) refused: \(refusal.message, privacy: .public)")
            outcome = .failed(refusal.message)
        } catch {
            log.error("store install \(id, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            outcome = .failed("Not installed: \(error.localizedDescription).")
        }
        lastMessage[id] = outcome.message
        return outcome
    }

    private func run(id: String, window: NSWindow?) async throws -> Outcome {
        reloadSources()
        if let sourcesError { throw Refusal(sourcesError) }
        guard let url = StoreLink.chromeDownloadURL(id: id) else {
            throw Refusal("Paddle couldn't make the download address for this extension.")
        }

        log.info("store install \(id, privacy: .public): download start")
        let data: Data
        do {
            data = try await StoreDownload.fetch(url, maxBytes: CRX3.maxFileSize)
        } catch let failure as StoreDownload.Failure {
            throw Refusal("Not installed: \(failure.message).")
        }
        log.info("store install \(id, privacy: .public): download finished, \(data.count, privacy: .public) bytes")

        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.extensions, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8).lowercased()
        // Names starting with "." are skipped by the folder scan, so a half-made folder never loads.
        let staging = Paths.extensions.appending(path: ".installing-\(id)-\(token)", directoryHint: .isDirectory)
        let scratch = fm.temporaryDirectory.appending(path: "Paddle-store-\(token)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: scratch)
        }

        let log = self.log
        let package: StoreInstall.Package
        do {
            package = try await Task.detached(priority: .userInitiated) {
                let verified = try CRX3.verify(data, expectedID: id, publisherKeyHashes: [CRX3.webStorePublisherKeyHash])
                log.info("store install \(id, privacy: .public): publisher signature verified")
                let entries = try ZipSafety.entries(in: verified.zip)
                return try StoreInstall.unpack(zip: verified.zip, entries: entries, id: id, into: staging, scratch: scratch)
            }.value
        } catch let error as LocalizedError {
            throw Refusal("Not installed: \(error.errorDescription ?? "the package failed a check").")
        }

        // Cancelled while it downloaded or unpacked: stop before anything in extensions/ changes.
        try Task.checkCancellation()
        // Read again: the file may have changed during the download.
        reloadSources()
        if let sourcesError { throw Refusal(sourcesError) }
        let existing = Set((try? fm.contentsOfDirectory(atPath: Paths.extensions.path)) ?? [])
        let name = ExtensionPermissionText.sanitize(package.displayName)
        let folder: String
        var replacing = false
        switch StoreInstall.plan(
            id: id, store: .chromeWebStore, version: package.version, displayName: package.displayName,
            sources: sources, existingFolders: existing
        ) {
        case .alreadyInstalled(_, let version):
            log.info("store install \(id, privacy: .public): same version already installed")
            return .alreadyInstalled(name: name, version: version)
        case .install(let newFolder):
            folder = newFolder
        case .replace(let oldFolder, let oldVersion, let newVersion):
            let changed = await changedFiles(in: oldFolder)
            guard await confirmReplace(name: name, oldVersion: oldVersion, newVersion: newVersion, changed: changed, window: window) else {
                return .cancelled
            }
            try Task.checkCancellation()
            folder = oldFolder
            replacing = true
        }

        // From here to the record, nothing awaits: no load or reconcile can see the folder half-swapped.
        let destination = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        let aside = Paths.extensions.appending(path: ".replaced-\(folder)-\(token)", directoryHint: .isDirectory)
        let hadOld: Bool
        do {
            hadOld = try StoreInstall.swapIn(staged: package.folder, destination: destination, aside: aside)
        } catch {
            throw Refusal("Not installed: the extension couldn't be moved into place (\(error.localizedDescription)). Nothing was changed.")
        }
        var updated = sources
        updated.recordInstall(
            folder: folder, store: .chromeWebStore, id: id, version: package.version, fileHashes: package.fileHashes, now: Date()
        )
        do {
            try writeSources(updated)
        } catch {
            do {
                try StoreInstall.rollBack(destination: destination, aside: aside, hadOld: hadOld)
            } catch {
                log.fault("store install \(id, privacy: .public): rollback failed: \(error.localizedDescription, privacy: .public)")
                throw Refusal("Not installed: extension-sources.json couldn't be written, and undoing the install failed. Check extensions/\(folder) (the previous copy may be in extensions/.replaced-\(folder)-\(token)).")
            }
            throw Refusal("Not installed: extension-sources.json couldn't be written (\(error.localizedDescription)). Nothing was changed.")
        }
        if hadOld {
            do {
                try fm.removeItem(at: aside)
            } catch {
                log.error("store install \(id, privacy: .public): old copy not deleted: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("store install \(id, privacy: .public): \(replacing ? "updated" : "installed", privacy: .public) into \(folder, privacy: .public), version \(package.version ?? "none", privacy: .public)")

        // The normal flow takes over: the host scans, loads it and asks for its permissions. A replaced folder that
        // was running is unloaded first so the new files load.
        let reload: Set<String> = replacing ? [folder] : []
        Task { await AppModel.shared.extensions.reconcile(config: AppModel.shared.config, reloading: reload) }
        return replacing ? .updated(name: name, version: package.version) : .installed(name: name, version: package.version)
    }

    /// Files in `folder` that differ from what was installed there, off the main actor.
    private func changedFiles(in folder: String) async -> [String] {
        let recorded = sources.records[folder]?.fileHashes ?? [:]
        guard !recorded.isEmpty else { return [] }
        let url = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        let current = await Task.detached(priority: .userInitiated) { try? StoreInstall.fileHashes(in: url) }.value
        guard let current else { return [] }
        return StoreInstall.changedFiles(recorded: recorded, current: current)
    }

    private func confirmReplace(name: String, oldVersion: String?, newVersion: String?, changed: [String], window: NSWindow?) async -> Bool {
        let old = ExtensionPermissionText.sanitize(oldVersion ?? "(no version)", max: 30)
        let new = ExtensionPermissionText.sanitize(newVersion ?? "(no version)", max: 30)
        let alert = NSAlert()
        alert.messageText = "Replace \(name) \(old) with \(new)?"
        var info = "The new version comes from the Chrome Web Store and passed its signature checks. "
            + "Its settings and saved data stay."
        if !changed.isEmpty {
            info += " You changed \(changed.count) file\(changed.count == 1 ? "" : "s") in its folder; they will be replaced."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}

/// One store download: an ephemeral session (no cookies, cache or credentials), a 60 s limit, a size cap enforced
/// while the bytes arrive, and redirects only to Google's download hosts over https.
nonisolated final class StoreDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: Error {
        let message: String
    }

    private let maxBytes: Int
    private let lock = NSLock()
    private var received = Data()
    private var failure: Failure?
    private var redirects = 0
    private var continuation: CheckedContinuation<Data, any Error>?
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    private init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    static func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
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
        let delegate = StoreDownload(maxBytes: maxBytes)
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
        guard let url = request.url, count <= 5, StoreLink.isAllowedChromeDownloadRedirect(url) else {
            let host = request.url?.host ?? "an unknown address"
            log.error("store download: redirect to \(host, privacy: .public) refused")
            completionHandler(nil)
            fail(count > 5 ? "too many redirects" : "the download was redirected to \(host), which isn't one of Google's download servers", task)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let url = http.url, StoreLink.isAllowedChromeDownloadRedirect(url) else {
            completionHandler(.cancel)
            fail("the answer didn't come from Google's download servers", dataTask)
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            fail(http.statusCode == 204 || http.statusCode == 404
                 ? "the Chrome Web Store has no download for this extension (it may be removed or not offered for this browser)"
                 : "the Chrome Web Store answered with error \(http.statusCode)", dataTask)
            return
        }
        guard response.expectedContentLength <= Int64(maxBytes) else {
            completionHandler(.cancel)
            fail("the package is over 100 MB", dataTask)
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
        if tooLarge { fail("the package is over 100 MB", dataTask) }
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
