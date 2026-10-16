import AppKit
import os
import PaddleCore
import WebKit

/// Store updates (`extension-sources.json`). Chrome: Google's update check; AMO: the add-on lookup.
/// A newer package is fetched and checked like an install (`StoreInstaller.fetchChrome` / `fetchAddon`),
/// and used only when its manifest names the store's version and that version is newer. Then:
/// - nothing new asked (`ExtensionPermissionDiff.asks`) and the cert chain verified: replace and reload;
/// - otherwise the installed copy keeps running, the new one waits in `extensions/.staged-<folder>/`,
///   and the alert names what it asks. Allow swaps it in; Don't Allow discards it and that version is
///   not asked again (`ExtensionSources.Record.declinedVersion`).
/// Once a day (`ExtensionUpdatePolicy`), at launch and the hourly sweep while `extensionUpdates` is on.
/// Extensions > Check for Extension Updates checks them all now, setting or not.
@Observable
final class ExtensionUpdater {
    static let shared = ExtensionUpdater()

    /// The last result per folder, shown in the Extensions menu. Replaced as each folder is checked.
    private(set) var statuses: [String: String] = [:]
    private(set) var checking = false
    @ObservationIgnored private var lastSweep = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    /// The note in the update alert for an add-on whose certificate chain wasn't checked, as the install alert says.
    private static let unverifiedNotice =
        "Paddle checked addons.mozilla.org's file hash and signature, but can't yet confirm Mozilla's certificate."

    // MARK: - Entry points

    /// The hourly gate, called at launch and from the sweep timer: checks the folders that are due, when `extensionUpdates`
    /// is on. Does nothing within an hour of its last run, while a check runs, or while an install runs; with the setting
    /// off it does nothing and doesn't use up the hour, so turning it on is noticed at the next sweep.
    func checkIfDue(config: PaddleConfig) async {
        guard config.extensionUpdates, !checking, StoreInstaller.shared.installing == nil,
              Date().timeIntervalSince(lastSweep) >= 3_600 else { return }
        let now = Date()
        lastSweep = now
        let folders = dueFolders(now: now, enabled: config.extensionUpdates)
        guard !folders.isEmpty else { return }
        _ = await check(folders)
    }

    /// Extensions > Check for Extension Updates: every folder that came from a store, now, whatever `extensionUpdates`
    /// says. Ends with a summary alert.
    func checkAll() async {
        guard !checking else {
            showSummary(title: "An update check is already running", lines: [])
            return
        }
        let installer = StoreInstaller.shared
        guard installer.installing == nil else {
            showSummary(title: "An extension is being installed", lines: ["Check for updates again when it's done."])
            return
        }
        installer.reloadSources()
        if let problem = installer.sourcesError {
            showSummary(title: "Extension updates can't be checked", lines: [problem])
            return
        }
        let folders = installer.sources.records.filter { Self.fromUpdatableStore($0.value) }.keys.sorted()
        guard !folders.isEmpty else {
            showSummary(title: "No extension from a store is installed", lines: ["Install one with Extensions > Install from Link…"])
            return
        }
        let results = await check(folders)
        showSummary(
            title: "Checked \(folders.count) store extension\(folders.count == 1 ? "" : "s")",
            lines: folders.map { "\($0): \(results[$0] ?? "")" }
        )
    }

    /// The store-installed folders whose last check is a day old or more (or never happened), when `enabled`.
    private func dueFolders(now: Date, enabled: Bool) -> [String] {
        let installer = StoreInstaller.shared
        installer.reloadSources()
        guard installer.sourcesError == nil else { return [] }
        return installer.sources.records
            .filter { Self.fromUpdatableStore($0.value) && ExtensionUpdatePolicy.shouldCheck(lastCheck: $0.value.lastCheck, now: now, enabled: enabled) }
            .keys.sorted()
    }

    /// Whether a record came from a store this updater asks: the Chrome Web Store or addons.mozilla.org.
    private static func fromUpdatableStore(_ record: ExtensionSources.Record) -> Bool {
        record.store == .chromeWebStore || record.store == .mozillaAddons
    }

    /// Checks each folder in turn and returns each one's result line, which `statuses` keeps as well.
    private func check(_ folders: [String]) async -> [String: String] {
        checking = true
        defer { checking = false }
        var results: [String: String] = [:]
        for folder in folders {
            let result = await checkFolder(folder)
            results[folder] = result
            statuses[folder] = result
            log.info("extension update \(folder, privacy: .public): \(result, privacy: .public)")
        }
        return results
    }

    // MARK: - One folder

    /// One folder's check. Returns the line the Extensions menu and the log show.
    private func checkFolder(_ folder: String) async -> String {
        let now = Date()
        let installer = StoreInstaller.shared
        let fm = FileManager.default
        // The folder name comes from extension-sources.json and becomes paths: a plain folder name directly in extensions/.
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/") else { return "not updated: its folder name isn't a plain name" }
        installer.reloadSources()
        if let problem = installer.sourcesError { return problem }
        guard let record = installer.sources.records[folder] else { return "not updated: it isn't recorded as a store install" }
        let destination = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        // Never recreate a folder the user removed: that would bring back an extension they deleted.
        guard fm.fileExists(atPath: destination.path) else { return "not updated: its folder is gone" }
        guard let installed = record.version else { return "not updated: no installed version is recorded" }
        let compare = record.store == .chromeWebStore ? ExtensionVersion.compareChrome : ExtensionVersion.compareToolkit

        // The store's answer is the check. A failed request leaves the folder due for the next run.
        let answer: StoreAnswer?
        do {
            answer = try await askStore(record, installed: installed)
        } catch {
            return "not updated: \(Self.reason(error))"
        }
        installer.changeRecord(folder) { $0.lastCheck = now }
        guard let answer else { return "up to date" }
        let newest = answer.version
        guard let order = compare(newest, installed) else { return "not updated: version \(newest) isn't in the store's format" }
        guard order == .orderedDescending else { return "up to date" }
        if installer.record(forFolder: folder)?.declinedVersion == newest {
            return "update \(newest) declined; not asked again"
        }

        // The same download and checks as an install, into `.staged-<folder>` (names starting with "." never load).
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let staging = Paths.extensions.appending(path: ".staged-\(folder)", directoryHint: .isDirectory)
        let scratch = fm.temporaryDirectory.appending(path: "Paddle-update-\(token)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)  // left behind by a check that never finished
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: scratch)
        }
        let checked: StoreInstaller.Checked
        do {
            switch record.store {
            case .chromeWebStore:
                checked = try await installer.fetchChrome(id: record.id, staging: staging, scratch: scratch)
            case .mozillaAddons:
                // The file named by the lookup `askStore` made, so the store is asked once for this check.
                guard let addon = answer.addon else { throw StoreInstaller.Refusal("the store's answer named no file") }
                checked = try await installer.fetchAddon(addon, slug: record.slug, staging: staging, scratch: scratch)
            case .appex, .folder:
                throw StoreInstaller.Refusal("it didn't come from a store Paddle updates from")
            }
        } catch {
            return "not updated: \(Self.reason(error))"
        }
        let package = checked.package
        let wantedID = record.store == .chromeWebStore ? record.id.lowercased() : record.id
        guard checked.id == wantedID else { return "not updated: the package is for another extension" }
        guard let version = package.version, version == newest else {
            return "not updated: the package is version \(package.version ?? "none"), not the \(newest) the store named"
        }
        guard compare(version, installed) == .orderedDescending else {
            return "not updated: \(version) isn't newer than the installed \(installed) (downgrades are refused)"
        }

        // What the new version asks for, as WebKit reads it, and what the user hasn't granted (the same rule a load uses).
        let webExtension: WKWebExtension
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: package.folder)
        } catch {
            return "not updated: \(error.localizedDescription)"
        }
        let name = ExtensionPermissionText.sanitize(webExtension.displayName ?? folder)
        let patterns = webExtension.allRequestedMatchPatterns
        let requested: ExtensionPermissionDiff.Requests = (
            Set(webExtension.requestedPermissions.map(\.rawValue)), Set(patterns.map(\.string))
        )
        let allSites = Set(patterns.filter { $0.matchesAllHosts || $0.matchesAllURLs }.map(\.string))
        let added: ExtensionPermissionDiff.Requests
        do {
            let before = try Data(contentsOf: destination.appending(path: "manifest.json"))
            let after = try Data(contentsOf: package.folder.appending(path: "manifest.json"))
            added = try ExtensionPermissionDiff.added(from: before, to: after)
        } catch {
            return "not updated: the manifests can't be compared (\(error.localizedDescription))"
        }
        guard let asks = AppModel.shared.extensionUpdateAsks(folder: folder, name: name, requested: requested, added: added) else {
            return "not updated: extension-permissions.json is unreadable"
        }

        // Asks for nothing new and verified: swap in quietly. Otherwise the installed copy keeps running and the alert decides.
        let unverified = !checked.verified
        let grants = !asks.permissions.isEmpty || !asks.hosts.isEmpty
        if grants || unverified {
            statuses[folder] = "update \(version) waiting for permission"
            let allowed = await AppModel.shared.extensions.confirmUpdate(
                folder: folder, name: name, icon: webExtension.icon(for: CGSize(width: 64, height: 64)),
                lines: ExtensionPermissionText.lines(permissions: asks.permissions, hosts: asks.hosts, allSites: allSites),
                notice: unverified ? Self.unverifiedNotice : nil, from: installed, to: version
            )
            guard allowed else {
                installer.changeRecord(folder) { $0.declinedVersion = version }
                return "update \(version) declined; not asked again"
            }
        }

        // The alert and the downloads took time: the record must still say what was checked against (an install of this
        // folder meanwhile would have replaced it), and the folder must still be there.
        installer.reloadSources()
        if let problem = installer.sourcesError { return problem }
        guard let current = installer.sources.records[folder], current.store == record.store, current.id == record.id,
              current.version == installed else { return "not updated: the installed copy changed while it was checked" }
        guard fm.fileExists(atPath: destination.path) else { return "not updated: its folder is gone" }

        // The swap, the record, then the grants: if the grants can't be written, the next load asks as it does for any
        // new request, so the update is never silently widened.
        do {
            try installer.place(
                package, into: folder, store: checked.store, id: checked.id, slug: checked.slug, verified: checked.verified, token: token
            )
        } catch {
            return "not updated: \(Self.reason(error))"
        }
        log.info("extension update \(folder, privacy: .public): version \(version, privacy: .public), verified \(checked.verified, privacy: .public)")
        if grants {
            AppModel.shared.recordExtensionUpdateAllowed(folder: folder, name: name, version: version, requested: requested, asks: asks)
        }
        let host = AppModel.shared
        Task { await host.reconcileExtensions(reloading: [folder]) }
        return "updated to \(version)"
    }

    /// What the store named for an update: the newest version, and for an add-on the lookup it came from.
    private struct StoreAnswer {
        let version: String
        /// The add-on's lookup, which its download uses (nil for Chrome, whose download is made on its own).
        let addon: AMO.Addon?
    }

    /// The newest version the store names for `record`, or nil when the store names none newer. Downloads nothing but the
    /// answer itself: Google's update check, or the add-on's lookup.
    private func askStore(_ record: ExtensionSources.Record, installed: String) async throws -> StoreAnswer? {
        let installer = StoreInstaller.shared
        switch record.store {
        case .chromeWebStore:
            guard let url = ChromeUpdateCheck.url(id: record.id, installedVersion: installed) else {
                throw StoreInstaller.Refusal("Paddle couldn't make the update address for this extension.")
            }
            let data = try await installer.download(url, maxBytes: ChromeUpdateCheck.maxAnswerSize, site: .chromeWebStore)
            switch try ChromeUpdateCheck.parse(data, id: record.id.lowercased()) {
            case .noUpdate: return nil
            case .update(let version): return StoreAnswer(version: version, addon: nil)
            }
        case .mozillaAddons:
            let addon = try await installer.lookupAddon(slug: record.id)
            return StoreAnswer(version: addon.version, addon: addon)
        case .appex, .folder:
            throw StoreInstaller.Refusal("it didn't come from a store Paddle updates from")
        }
    }

    /// The sentence for a failed step: a refusal's, a LocalizedError's description, else the system's.
    private static func reason(_ error: Error) -> String {
        if let refusal = error as? StoreInstaller.Refusal { return refusal.message }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return error.localizedDescription
    }

    /// The summary alert for a manual check: one line per folder.
    private func showSummary(title: String, lines: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = lines.map { ExtensionPermissionText.sanitize($0, max: 240) }.joined(separator: "\n")
        alert.runModal()
    }
}
