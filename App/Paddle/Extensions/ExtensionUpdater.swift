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

    /// The last result per folder, shown in the Extensions menu. Replaced as each folder is checked; reloaded from
    /// `extension-sources.json` on `refreshStatusesFromDisk()`.
    private(set) var statuses: [String: String] = [:]
    private(set) var checking = false
    /// The folders being checked now (a subset of a running check), for the progress indicator on their rows.
    private(set) var checkingFolders: Set<String> = []
    /// An adoption offer or an adoption is in progress (a question may be open).
    private(set) var adopting = false
    /// The result of the last Check All Now, persisted in `extension-update-last.json` for Settings.
    private(set) var note: String?
    /// Parsed batch summary backing `note`.
    private(set) var lastBatch: ExtensionUpdateBatchSummary?
    @ObservationIgnored private var lastSweep = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    private init() { loadBatchSummary() }

    /// Reloads per-folder status lines from `extension-sources.json` (after Settings opens or sources reload).
    func refreshStatusesFromDisk() {
        let installer = StoreInstaller.shared
        guard installer.sourcesError == nil else { return }
        for (folder, record) in installer.allRecords where Self.fromUpdatableStore(record) {
            if let outcome = record.lastOutcome {
                statuses[folder] = outcome.legacyStatusLine(installedVersion: record.version)
            }
        }
    }

    /// The note in the update alert for an add-on whose certificate chain wasn't checked, as the install alert says.
    private static let unverifiedNotice =
        "Paddle checked addons.mozilla.org's file hash and signature, but can't yet confirm Mozilla's certificate."

    /// The note in the first update alert of a hand-installed add-on the user chose to keep updated.
    private static let adoptedNotice =
        "This copy was installed by hand, so Paddle can't tell whether you changed its files; updating replaces them."

    // MARK: - Entry points

    /// The hourly gate, called at launch and from the sweep timer: checks the folders that are due, when `extensionUpdates`
    /// is on. Does nothing within an hour of its last run, while a check runs, or while an install runs; with the setting
    /// off it does nothing and doesn't use up the hour, so turning it on is noticed at the next sweep.
    func checkIfDue(config: PaddleConfig) async {
        guard config.extensionUpdates, !busy, Date().timeIntervalSince(lastSweep) >= 3_600 else { return }
        let now = Date()
        lastSweep = now
        // Hand-installed add-ons are offered once (after the first window is up: this runs well after launch); the ones
        // the user keeps are checked right away, the rest of the due folders after.
        let adopted = await offerAdoptions()
        guard !busy else { return }
        let folders = Set(dueFolders(now: now, enabled: config.extensionUpdates)).union(adopted).sorted()
        guard !folders.isEmpty else { return }
        _ = await check(folders)
    }

    /// Whether a check, an adoption question or an install is running.
    var busy: Bool { checking || adopting || StoreInstaller.shared.installing != nil }

    /// Why nothing can start now, as a sentence, or nil when idle.
    private var busyReason: String? {
        if checking { return "another update check is running" }
        if adopting { return "a question about updates is open" }
        if StoreInstaller.shared.installing != nil { return "an extension is being installed" }
        return nil
    }

    /// What a manual sweep checks: the store folders, or why there is nothing to check.
    private enum Sweep {
        case folders([String])
        case problem(title: String, lines: [String])
    }

    /// Offers hand-installed add-ons (`offerAdoptions`), then lists every folder that came from a store. Shared by
    /// `checkAll` and `checkAllNow`; nothing is offered or listed while something else runs.
    private func manualSweep() async -> Sweep {
        guard !checking else { return .problem(title: "An update check is already running", lines: []) }
        let installer = StoreInstaller.shared
        guard installer.installing == nil else {
            return .problem(title: "An extension is being installed", lines: ["Check for updates again when it's done."])
        }
        guard !adopting else { return .problem(title: "A question about updates is open", lines: ["Answer it, then check again."]) }
        await offerAdoptions()
        guard !checking, installer.installing == nil, !adopting else {
            return .problem(title: "Another check or install started", lines: ["Check for updates again when it's done."])
        }
        installer.reloadSources()
        if let problem = installer.sourcesError {
            return .problem(title: "Extension updates can't be checked", lines: [problem])
        }
        let folders = installer.sources.records.filter { Self.fromUpdatableStore($0.value) }.keys.sorted()
        guard !folders.isEmpty else {
            return .problem(title: "No extension from a store is installed", lines: ["Install one with Extensions > Install from Link…"])
        }
        return .folders(folders)
    }

    /// Extensions > Check for Extension Updates: every folder that came from a store, now, whatever `extensionUpdates`
    /// says. Ends with a summary alert.
    func checkAll() async {
        switch await manualSweep() {
        case .problem(let title, let lines):
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = lines.joined(separator: "\n")
            alert.runModal()
        case .folders(let folders):
            let results = await check(folders)
            showSummary(
                title: "Checked \(folders.count) store extension\(folders.count == 1 ? "" : "s")",
                folders: folders, outcomes: results
            )
        }
    }

    /// Settings > Extensions > Check All Now: the same sweep as `checkAll` without the alert; `note` and persisted
    /// outcomes show the outcome.
    func checkAllNow() async {
        switch await manualSweep() {
        case .problem(let title, let lines):
            note = ([title] + lines).joined(separator: " ")
        case .folders(let folders):
            let results = await check(folders)
            saveBatch(ExtensionUpdateBatchSummary.build(at: Date(), folderCount: folders.count, outcomes: results))
        }
    }

    /// Settings > Extensions > Check for Update: one folder now, ignoring the once-a-day gate, without an alert. The
    /// result is in `statuses[folder]`. Refused (with a line on the row) while another check or an install runs.
    func checkNow(folder: String) async {
        if let reason = busyReason {
            let outcome = ExtensionUpdateOutcome(kind: .notChecked, at: Date(), detail: reason)
            remember(folder: folder, outcome: outcome, touchLastCheck: false)
            return
        }
        _ = await check([folder])
    }

    /// Settings > Extensions > Keep Updated: the user's explicit choice, so no question. The add-on is looked up on
    /// addons.mozilla.org and must be the manifest's own id; then it is recorded (and cleared from `declinedAdoption`)
    /// and checked right away. The outcome is in `statuses[folder]`.
    func adoptNow(folder: String) async {
        if let reason = busyReason {
            remember(folder: folder, outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: reason), touchLastCheck: false)
            return
        }
        adopting = true
        let installer = StoreInstaller.shared
        let adopted: Bool
        do {
            adopted = try await adoptWithoutAsking(folder: folder)
        } catch {
            remember(
                folder: folder,
                outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: Self.reason(error)),
                touchLastCheck: false
            )
            adopting = false
            return
        }
        adopting = false
        guard adopted else { return }
        installer.reloadSources()
        if !busy { _ = await check([folder]) }
    }

    /// The lookup and the record for `adoptNow`. False (with `statuses[folder]` set) when it isn't possible.
    private func adoptWithoutAsking(folder: String) async throws -> Bool {
        let installer = StoreInstaller.shared
        installer.reloadSources()
        if let problem = installer.sourcesError {
            remember(folder: folder, outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: problem), touchLastCheck: false)
            return false
        }
        let manifest = Paths.extensions.appending(path: folder, directoryHint: .isDirectory).appending(path: "manifest.json")
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/"), installer.sources.records[folder] == nil,
              let data = try? Data(contentsOf: manifest), let gecko = ExtensionAdoption.geckoID(manifest: data) else {
            remember(
                folder: folder,
                outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: "it has no add-on id, or it is already tracked"),
                touchLastCheck: false
            )
            return false
        }
        let addon = try await installer.lookupAddon(slug: gecko)
        guard ExtensionAdoption.acceptsLookup(guid: addon.guid, geckoID: gecko) else {
            remember(
                folder: folder,
                outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: "addons.mozilla.org's add-on has a different id"),
                touchLastCheck: false
            )
            return false
        }
        if let problem = await installer.adopt(folder: folder, guid: addon.guid, slug: nil) {
            remember(folder: folder, outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: problem), touchLastCheck: false)
            return false
        }
        return true
    }

    // MARK: - Adoption of hand-installed add-ons

    /// The offers (called from the hourly gate, which is how launch reaches it, and from the manual checks, which then
    /// check everything): for each folder in `extensions/` with a gecko id and no record that wasn't declined, look the add-on up on
    /// addons.mozilla.org and, when it is that add-on, ask once. Returns the folders adopted. One question at a time, none
    /// while an install or check runs or the front window is private; a failed lookup asks nothing and is tried at the next
    /// sweep; a folder that is gone is skipped.
    @discardableResult
    func offerAdoptions() async -> [String] {
        let installer = StoreInstaller.shared
        guard !busy, !frontWindowIsPrivate else { return [] }
        adopting = true
        defer { adopting = false }
        installer.reloadSources()
        guard installer.sourcesError == nil else { return [] }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Paths.extensions.path)) ?? []).sorted()
        var adopted: [String] = []
        for folder in names {
            // The things that start during the awaits below end the sweep.
            guard !checking, installer.installing == nil, !frontWindowIsPrivate else { break }
            let directory = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // The tests `candidateGeckoID` makes before it needs the manifest: a folder with a record or a declined answer
            // is skipped without reading manifest.json. `sources` was reloaded above the loop.
            guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/"), folder != ExtensionSources.declinedKey,
                  installer.sources.records[folder] == nil, !installer.sources.hasDeclinedAdoption(folder),
                  let data = try? Data(contentsOf: directory.appending(path: "manifest.json")) else { continue }
            guard installer.sourcesError == nil,
                  let gecko = ExtensionAdoption.candidateGeckoID(folder: folder, manifest: data, sources: installer.sources) else { continue }
            let addon: AMO.Addon
            do {
                addon = try await installer.lookupAddon(slug: gecko)
            } catch {
                log.info("extension adoption \(folder, privacy: .public): lookup failed, will try at the next sweep")
                continue
            }
            guard ExtensionAdoption.acceptsLookup(guid: addon.guid, geckoID: gecko) else { continue }
            // The lookup took time: ask only if the folder is still an untouched candidate and nothing else began.
            installer.reloadSources()
            guard !checking, installer.installing == nil, !frontWindowIsPrivate, fm.fileExists(atPath: directory.path),
                  installer.sourcesError == nil,
                  ExtensionAdoption.candidateGeckoID(folder: folder, manifest: data, sources: installer.sources) == gecko else { continue }
            let name = ExtensionPermissionText.sanitize(addon.name, max: 60)
            let icon = LoadedExtension.icon(in: directory, side: 64)
            let keep = await ExtensionShared.shared.serialized {
                let alert = NSAlert()
                alert.messageText = "Keep \(name) updated?"
                alert.informativeText = "\(name) is installed by hand and matches the add-on on addons.mozilla.org. Paddle can check it daily and update it. A new version that asks for more permissions still waits for your answer."
                if let icon { alert.icon = icon }
                alert.addButton(withTitle: "Keep Updated")
                alert.addButton(withTitle: "Not Now")
                return alert.runModal() == .alertFirstButtonReturn
            }
            guard fm.fileExists(atPath: directory.path) else { continue }
            if keep {
                if let problem = await installer.adopt(folder: folder, guid: addon.guid, slug: nil) {
                    remember(folder: folder, outcome: ExtensionUpdateOutcome(kind: .failed, at: Date(), detail: problem), touchLastCheck: false)
                } else {
                    adopted.append(folder)
                    log.info("extension adoption \(folder, privacy: .public): kept updated")
                }
            } else {
                installer.declineAdoption(folder: folder)
            }
        }
        return adopted
    }

    /// Whether the front window is a private one, when no offer is made.
    private var frontWindowIsPrivate: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return AppModel.shared.windows.contains { $0.model.isPrivate && $0.window === key }
    }

    /// The store-installed folders whose last check is a day old or more (or never happened), when `enabled`.
    private func dueFolders(now: Date, enabled: Bool) -> [String] {
        let installer = StoreInstaller.shared
        installer.reloadSources()
        guard installer.sourcesError == nil else { return [] }
        return installer.sources.records
            .filter {
                Self.fromUpdatableStore($0.value)
                    && ExtensionUpdatePolicy.shouldCheck(lastCheck: $0.value.lastCheck, now: now, enabled: enabled, seed: $0.key)
            }
            .keys.sorted()
    }

    /// Whether a record came from a store this updater asks: the Chrome Web Store or addons.mozilla.org.
    private static func fromUpdatableStore(_ record: ExtensionSources.Record) -> Bool {
        record.store == .chromeWebStore || record.store == .mozillaAddons
    }

    /// Checks each folder in turn and returns each one's outcome, which is persisted on the record and in `statuses`.
    private func check(_ folders: [String]) async -> [String: ExtensionUpdateOutcome] {
        checking = true
        defer { checking = false }
        var results: [String: ExtensionUpdateOutcome] = [:]
        for folder in folders {
            checkingFolders.insert(folder)
            let outcome = await checkFolder(folder)
            checkingFolders.remove(folder)
            results[folder] = outcome
            statuses[folder] = outcome.legacyStatusLine(installedVersion: StoreInstaller.shared.record(forFolder: folder)?.version)
            log.info("extension update \(folder, privacy: .public): \(self.statuses[folder] ?? "", privacy: .public)")
        }
        return results
    }

    // MARK: - One folder

    /// One folder's check. Persists `lastOutcome` (and `lastCheck` when the store was consulted successfully).
    private func checkFolder(_ folder: String) async -> ExtensionUpdateOutcome {
        let now = Date()
        let installer = StoreInstaller.shared
        let fm = FileManager.default
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/") else {
            return recordFailure(folder: folder, now: now, detail: "its folder name isn't a plain name")
        }
        installer.reloadSources()
        if let problem = installer.sourcesError {
            return recordFailure(folder: folder, now: now, detail: problem)
        }
        guard let record = installer.sources.records[folder] else {
            return recordFailure(folder: folder, now: now, detail: "it isn't recorded as a store install")
        }
        let destination = Paths.extensions.appending(path: folder, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: destination.path) else {
            return recordFailure(folder: folder, now: now, detail: "its folder is gone")
        }
        guard let installed = record.version else {
            return recordFailure(folder: folder, now: now, detail: "no installed version is recorded")
        }
        let compare = record.store == .chromeWebStore ? ExtensionVersion.compareChrome : ExtensionVersion.compareToolkit

        func succeed(_ outcome: ExtensionUpdateOutcome) -> ExtensionUpdateOutcome {
            remember(folder: folder, outcome: outcome, touchLastCheck: true)
            return outcome
        }

        let answer: StoreAnswer?
        do {
            answer = try await askStore(record, installed: installed)
        } catch {
            return recordFailure(folder: folder, now: now, detail: Self.reason(error), from: installed)
        }
        guard let answer else {
            return succeed(ExtensionUpdateOutcome(kind: .upToDate, at: now, fromVersion: installed))
        }
        let newest = answer.version
        guard let order = compare(newest, installed) else {
            return succeed(ExtensionUpdateOutcome(kind: .failed, at: now, fromVersion: installed, storeVersion: newest, detail: "version \(newest) isn't in the store's format"))
        }
        guard order == .orderedDescending else {
            return succeed(ExtensionUpdateOutcome(kind: .upToDate, at: now, fromVersion: installed, storeVersion: newest))
        }
        if installer.record(forFolder: folder)?.declinedVersion == newest {
            return succeed(ExtensionUpdateOutcome(kind: .declined, at: now, fromVersion: installed, storeVersion: newest))
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let staging = Paths.extensions.appending(path: ".staged-\(folder)", directoryHint: .isDirectory)
        let scratch = fm.temporaryDirectory.appending(path: "Paddle-update-\(token)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
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
                guard let addon = answer.addon else { throw StoreInstaller.Refusal("the store's answer named no file") }
                checked = try await installer.fetchAddon(addon, slug: record.slug, staging: staging, scratch: scratch)
            case .appex, .folder:
                throw StoreInstaller.Refusal("it didn't come from a store Paddle updates from")
            }
        } catch {
            return recordFailure(folder: folder, now: now, detail: Self.reason(error), from: installed, storeVersion: newest)
        }
        let package = checked.package
        let wantedID = record.store == .chromeWebStore ? record.id.lowercased() : record.id
        guard checked.id == wantedID else {
            return recordFailure(folder: folder, now: now, detail: "the package is for another extension", from: installed, storeVersion: newest)
        }
        guard let version = package.version, version == newest else {
            let pkg = package.version ?? "none"
            return recordFailure(folder: folder, now: now, detail: "the package is version \(pkg), not the \(newest) the store named", from: installed, storeVersion: newest)
        }
        guard compare(version, installed) == .orderedDescending else {
            return recordFailure(folder: folder, now: now, detail: "\(version) isn't newer than the installed \(installed) (downgrades are refused)", from: installed, storeVersion: newest)
        }

        let webExtension: WKWebExtension
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: package.folder)
        } catch {
            return recordFailure(folder: folder, now: now, detail: error.localizedDescription, from: installed, storeVersion: newest)
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
            return recordFailure(folder: folder, now: now, detail: "the manifests can't be compared (\(error.localizedDescription))", from: installed, storeVersion: newest)
        }
        guard let asks = AppModel.shared.extensionUpdateAsks(folder: folder, name: name, requested: requested, added: added) else {
            return recordFailure(folder: folder, now: now, detail: "extension-permissions.json is unreadable", from: installed, storeVersion: newest)
        }

        let unverified = !checked.verified
        let grants = !asks.permissions.isEmpty || !asks.hosts.isEmpty
        let edited = await installer.changedFiles(in: folder)
        let firstOfAdopted = ExtensionAdoption.needsAlertOnFirstUpdate(record: record)
        if grants || unverified || !edited.isEmpty || firstOfAdopted {
            let waiting = ExtensionUpdateOutcome(kind: .waitingPermission, at: now, fromVersion: installed, storeVersion: version)
            remember(folder: folder, outcome: waiting, touchLastCheck: false)
            var notices: [String] = []
            if unverified { notices.append(Self.unverifiedNotice) }
            if firstOfAdopted { notices.append(Self.adoptedNotice) }
            if !edited.isEmpty {
                notices.append("You changed \(edited.count) file\(edited.count == 1 ? "" : "s") in its folder; updating replaces them.")
            }
            let allowed = await AppModel.shared.extensions.confirmUpdate(
                folder: folder, name: name, icon: webExtension.icon(for: CGSize(width: 64, height: 64)),
                lines: ExtensionPermissionText.lines(permissions: asks.permissions, hosts: asks.hosts, allSites: allSites),
                notice: notices.isEmpty ? nil : notices.joined(separator: " "), from: installed, to: version
            )
            guard allowed else {
                installer.changeRecord(folder) { $0.declinedVersion = version }
                return succeed(ExtensionUpdateOutcome(kind: .declined, at: now, fromVersion: installed, storeVersion: version))
            }
        }

        installer.reloadSources()
        if let problem = installer.sourcesError {
            return recordFailure(folder: folder, now: now, detail: problem, from: installed, storeVersion: newest)
        }
        guard let current = installer.sources.records[folder], current.store == record.store, current.id == record.id,
              current.version == installed else {
            return recordFailure(folder: folder, now: now, detail: "the installed copy changed while it was checked", from: installed, storeVersion: newest)
        }
        guard fm.fileExists(atPath: destination.path) else {
            return recordFailure(folder: folder, now: now, detail: "its folder is gone", from: installed, storeVersion: newest)
        }

        do {
            try installer.place(
                package, into: folder, store: checked.store, id: checked.id, slug: checked.slug, verified: checked.verified, token: token
            )
        } catch {
            return recordFailure(folder: folder, now: now, detail: Self.reason(error), from: installed, storeVersion: newest)
        }
        log.info("extension update \(folder, privacy: .public): version \(version, privacy: .public), verified \(checked.verified, privacy: .public)")
        if grants {
            AppModel.shared.recordExtensionUpdateAllowed(folder: folder, name: name, version: version, requested: requested, asks: asks)
        }
        let host = AppModel.shared
        Task { await host.reconcileExtensions(reloading: [folder]) }
        return succeed(ExtensionUpdateOutcome(kind: .updated, at: now, fromVersion: installed, storeVersion: version))
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
    private func showSummary(title: String, folders: [String], outcomes: [String: ExtensionUpdateOutcome]) {
        let installer = StoreInstaller.shared
        let lines = folders.map { folder -> String in
            let record = installer.record(forFolder: folder)
            let outcome = outcomes[folder] ?? record?.lastOutcome
            if let record, let outcome {
                return "\(folder): \(outcome.settingsSummary(record: record))"
            }
            return "\(folder): \(outcomes[folder]?.legacyStatusLine(installedVersion: record?.version) ?? "unknown")"
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = lines.map { ExtensionPermissionText.sanitize($0, max: 240) }.joined(separator: "\n")
        alert.runModal()
        saveBatch(ExtensionUpdateBatchSummary.build(at: Date(), folderCount: folders.count, outcomes: outcomes))
    }

    private func remember(folder: String, outcome: ExtensionUpdateOutcome, touchLastCheck: Bool) {
        StoreInstaller.shared.changeRecord(folder) { record in
            record.lastOutcome = outcome
            if touchLastCheck { record.lastCheck = outcome.at }
        }
        statuses[folder] = outcome.legacyStatusLine(installedVersion: StoreInstaller.shared.record(forFolder: folder)?.version)
    }

    private func recordFailure(
        folder: String, now: Date, detail: String, from: String? = nil, storeVersion: String? = nil
    ) -> ExtensionUpdateOutcome {
        let outcome = ExtensionUpdateOutcome(kind: .failed, at: now, fromVersion: from, storeVersion: storeVersion, detail: detail)
        remember(folder: folder, outcome: outcome, touchLastCheck: false)
        return outcome
    }

    private func loadBatchSummary() {
        guard FileManager.default.fileExists(atPath: Paths.extensionUpdateBatch.path),
              let data = try? Data(contentsOf: Paths.extensionUpdateBatch),
              let batch = try? ExtensionUpdateBatchSummary.decodeFile(data) else { return }
        lastBatch = batch
        note = batch.settingsNote
    }

    private func saveBatch(_ batch: ExtensionUpdateBatchSummary) {
        lastBatch = batch
        note = batch.settingsNote
        do {
            try batch.encoded().write(to: Paths.extensionUpdateBatch.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            log.error("extension-update-last.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
