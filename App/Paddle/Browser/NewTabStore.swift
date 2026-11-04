import AppKit
import os
import PaddleCore

/// The New Tab page's pinned sites in newtab.json: a plain file you can edit by hand (Paddle > Reload Config
/// re-reads it, and an in-app edit re-reads it first when it changed on disk, so hand edits are never overwritten).
@Observable
final class NewTabStore {
    private var data = NewTabSites()
    /// Set when newtab.json exists but can't be read. Paddle then never writes the file, so nothing is lost.
    private(set) var loadError: String?
    /// An in-app edit not yet written to disk.
    @ObservationIgnored private var dirty = false
    /// newtab.json's modification date and size as last read or written; nil when there was no file.
    @ObservationIgnored private var diskStamp: DiskStamp?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Frequent sites per profile as of the last finished query, shown at once while the next one runs.
    @ObservationIgnored private var frequentCache: [ProfileID: [HistoryEntry]] = [:]
    /// Bumped whenever the cache is dropped (history cleared or off, profile deleted): a query that was already
    /// running then lands nowhere, so it can't put back what was just cleared.
    @ObservationIgnored private var frequentEpoch = 0
    private let log = Logger(subsystem: "com.walker.Paddle", category: "newtab")

    private struct DiskStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    var sites: [NewTabSite] { data.sites }
    var hiddenFrequent: [String] { data.hiddenFrequent }

    /// Reads newtab.json. An in-app edit still waiting to be saved is written first, unless the file changed
    /// on disk since, in which case the hand edit wins.
    func load() {
        saveWork?.cancel()
        saveWork = nil
        if dirty, !diskChanged { saveNow() }
        dirty = false
        diskStamp = Self.stamp()
        guard FileManager.default.fileExists(atPath: Paths.newTab.path) else {
            data = NewTabSites()
            loadError = nil
            return
        }
        do {
            data = try NewTabSites.decode(Data(contentsOf: Paths.newTab))
            loadError = nil
        } catch {
            loadError = "newtab.json: \(PaddleConfig.describe(error))"
            log.error("\(self.loadError ?? "", privacy: .public)")
        }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, loadError == nil else { return }
        do {
            // Through a symlink, so a newtab.json linked from elsewhere stays a link.
            try data.encoded().write(to: Paths.newTab.resolvingSymlinksInPath(), options: .atomic)
            dirty = false
            diskStamp = Self.stamp()
        } catch {
            log.error("newtab save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading

    /// Whether a tile for this address (compared without case in scheme and host, ignoring a trailing slash) is pinned.
    func contains(url: String) -> Bool { id(forURL: url) != nil }

    func id(forURL url: String) -> UUID? {
        guard let key = NewTabSites.normalized(url) else { return nil }
        return data.sites.first { NewTabSites.normalized($0.url) == key }?.id
    }

    /// The frequent sites last computed for `profile`, minus anything pinned or hidden since. Instant: no database access.
    func cachedFrequentSites(profile: ProfileID) -> [HistoryEntry] {
        guard AppModel.shared.historyEnabled(for: profile) else { return [] }
        let excluded = excludedFrequentHosts
        return (frequentCache[profile] ?? []).filter { NewTabSites.siteHost($0.url).map { !excluded.contains($0) } ?? false }
    }

    /// The most visited sites of the last 30 days that aren't pinned or hidden: one page per host. Empty when
    /// history is off. Read from `profile`'s history on a separate connection off the main thread (the app's own
    /// `HistoryStore` is main-actor only), one query at a time. Nil when the calling task was cancelled, so a
    /// superseded request never lands. The result is also kept for `cachedFrequentSites`.
    func loadFrequentSites(limit: Int = 8, profile: ProfileID = ProfileStore.defaultID) async -> [HistoryEntry]? {
        // Asking the app model opens the main connection on first use and applies the history-off and removed-profile rules.
        guard AppModel.shared.history(for: profile) != nil else {
            frequentCache[profile] = nil
            return []
        }
        let path = AppModel.shared.historyPath(for: profile).path
        let epoch = frequentEpoch
        guard let found = await FrequentSitesQuery.shared.run(path: path, limit: limit, excluding: excludedFrequentHosts),
              epoch == frequentEpoch else { return nil }
        frequentCache[profile] = found
        return cachedFrequentSites(profile: profile)
    }

    /// History was cleared (one profile's) or turned off (every profile's, `profile` nil): drop the cached row.
    func forgetFrequentSites(profile: ProfileID? = nil) {
        frequentEpoch += 1
        if let profile {
            frequentCache[profile] = nil
            let path = AppModel.shared.historyPath(for: profile).path
            Task { await FrequentSitesQuery.shared.forget(path: path) }
        } else {
            frequentCache.removeAll()
            Task { await FrequentSitesQuery.shared.forgetAll() }
        }
    }

    /// Icon cache keys (`FaviconPicker.cacheKey`) of the sites New Tab shows as tiles for `profile`: pinned ones and
    /// the last Frequently visited row. Only these get the large icon (`FaviconStore.largeImage`).
    func tileIconKeys(profile: ProfileID) -> Set<String> {
        let urls = data.sites.map(\.url) + cachedFrequentSites(profile: profile).map(\.url)
        return Set(urls.compactMap { URL(string: $0).flatMap(FaviconPicker.cacheKey(for:)) })
    }

    private var excludedFrequentHosts: Set<String> {
        Set(data.sites.compactMap { NewTabSites.siteHost($0.url) }).union(data.hiddenFrequent)
    }

    // MARK: - Editing

    /// Pins a page at the end. False when refused: not a web address, already pinned, a full page or an unreadable file.
    @discardableResult
    func add(title: String, url: String) -> Bool {
        var accepted = false
        update("Add to New Tab Page") { accepted = $0.add(title: title, url: url) }
        return accepted
    }

    func remove(_ id: UUID) {
        update("Remove from New Tab Page") { $0.remove(id: id) }
    }

    /// Drags a tile to sit before `target`, or to the end when `target` is nil.
    func move(_ id: UUID, before target: UUID?) {
        update("Move Tile") { sites in
            guard let from = sites.sites.firstIndex(where: { $0.id == id }), target != id else { return }
            if let target {
                guard let targetIndex = sites.sites.firstIndex(where: { $0.id == target }) else { return }
                sites.move(from: from, to: targetIndex > from ? targetIndex - 1 : targetIndex)
            } else {
                sites.move(from: from, to: sites.sites.count - 1)
            }
        }
    }

    /// Changes a tile's title and address. False when refused (not a web address, or another tile has it).
    @discardableResult
    func update(_ id: UUID, title: String, url: String) -> Bool {
        var accepted = false
        update("Edit Tile") { accepted = $0.update(id: id, title: title, url: url) }
        return accepted
    }

    func hideFrequent(host: String) {
        update("Remove from Frequently Visited") { $0.hideFrequent(host: host) }
    }

    // MARK: - Private

    /// Applies an edit, makes it undoable (Edit > Undo in the window where it happened) and saves shortly after.
    /// Refused while newtab.json is unreadable.
    private func update(_ actionName: String, _ change: (inout NewTabSites) -> Void) {
        if diskChanged { load() }
        guard loadError == nil else {
            NSSound.beep()
            return
        }
        let before = data
        change(&data)
        guard data != before else { return }
        if let undoManager = (NSApp.keyWindow ?? NSApp.mainWindow)?.undoManager {
            registerUndo(undoManager, restoring: before, actionName)
        }
        scheduleSave()
    }

    private var diskChanged: Bool { Self.stamp() != diskStamp }

    private static func stamp() -> DiskStamp? {
        guard let values = try? Paths.newTab.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return DiskStamp(modified: values.contentModificationDate, size: values.fileSize)
    }

    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Undo swaps the whole list back; redo is registered the same way.
    private func registerUndo(_ undoManager: UndoManager, restoring old: NewTabSites, _ actionName: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard store.loadError == nil else { return }
                let current = store.data
                store.data = old
                store.registerUndo(undoManager, restoring: current, actionName)
                store.scheduleSave()
            }
        }
        undoManager.setActionName(actionName)
    }
}

/// Runs the Frequently visited query off the main thread. An actor, so queries run one after another and
/// requests cancelled while waiting are skipped instead of piling up. `HistoryStore` is not shared across threads,
/// so each history file gets one connection, opened on first use and kept here for later queries. It is closed by
/// `forget(path:)` / `forgetAll()` (history cleared, turned off or profile deleted), and dropped when its file is gone.
private actor FrequentSitesQuery {
    static let shared = FrequentSitesQuery()

    private var stores: [String: HistoryStore] = [:]

    /// Nil when the caller was cancelled or the database can't be read.
    func run(path: String, limit: Int, excluding: Set<String>) -> [HistoryEntry]? {
        guard FileManager.default.fileExists(atPath: path) else {
            stores[path] = nil
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let history: HistoryStore
        if let open = stores[path] {
            history = open
        } else {
            guard let opened = try? HistoryStore(path: path) else { return nil }
            stores[path] = opened
            history = opened
        }
        return try? history.topSites(limit: limit, days: 30, now: Date(), excludingHosts: excluding)
    }

    func forget(path: String) {
        stores[path] = nil
    }

    func forgetAll() {
        stores.removeAll()
    }
}
