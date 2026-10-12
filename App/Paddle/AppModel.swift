import AppKit
import Foundation
import os
import PaddleCore

/// App-wide state: config, shared WebKit environment, windows, session saving,
/// tab sleeping and memory sampling.
@Observable
final class AppModel {
    static let shared = AppModel()

    private let log = Logger(subsystem: "com.walker.Paddle", category: "app")

    private(set) var config = PaddleConfig()
    /// Set when config.json fails to parse; Paddle keeps running on the previous config.
    private(set) var configError: String?
    let web = WebEnvironment()
    let downloads = DownloadStore()
    let bookmarks = BookmarkStore()
    let favicons = FaviconStore()
    let extensions = ExtensionHost()
    /// Bookmarks > Show/Hide Bookmarks Bar. Window state, so it lives in user defaults rather than config.json.
    var showBookmarksBar = UserDefaults.standard.object(forKey: "showBookmarksBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBookmarksBar, forKey: "showBookmarksBar") }
    }
    /// Browsing history (history.sqlite); nil when historyDays is 0 or the database can't be opened.
    @ObservationIgnored private(set) var history: HistoryStore?
    /// Bumped whenever history changes, so an open History window refreshes.
    private(set) var historyGeneration = 0
    /// Footprint of everything Paddle runs: tab, extension and worker WebContent processes, GPU and Networking,
    /// and the app itself (`memoryBreakdown.total`).
    private(set) var totalWebMemory: UInt64 = 0
    /// The same memory split into the Activity popover's rows.
    private(set) var memoryBreakdown = ProcessBreakdown()

    /// Per-session answers to permission prompts (camera, microphone, downloads), keyed by site and kind.
    @ObservationIgnored var grantedPermissions: Set<String> = []
    @ObservationIgnored var refusedPermissions: Set<String> = []
    @ObservationIgnored private(set) var windows: [BrowserWindowController] = []
    @ObservationIgnored private var sampleTimer: Timer?
    @ObservationIgnored private var sweepTimer: Timer?
    /// Open readouts that want the 5 s sampler even with `showTabMemory` off (Activity, Settings' memory pane).
    @ObservationIgnored private var memoryReaders = 0
    /// Activation and window-occlusion observers that start and stop the sampler.
    @ObservationIgnored private var samplerObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var isRestoring = false
    /// False until session.json has been read, so quitting during startup can't overwrite it with no windows.
    @ObservationIgnored private var didRestore = false

    private init() {}

    // MARK: - Lifecycle

    func start(openingURLs urls: [URL]) async {
        Paths.ensure()
        if let loaded = readConfig() { config = loaded }
        openHistory()
        bookmarks.load()
        web.apply(config)
        MainMenu.applyShortcuts(config.shortcuts)
        extensions.prepare(config: config)
        await web.loadContentBlockers()

        restoreSession()
        if windows.isEmpty { openWindow() }
        open(urls)

        startMonitoring()

        // Windows are on screen; extensions find them through the registered windows. Session-restored extension
        // pages wait for this (deferred wake).
        await extensions.loadAll(config: config)

        // After the startup compile and the first windows, and not awaited, so a download never holds up a page.
        Task { await updateFilterListsIfDue() }
    }

    func willTerminate() {
        downloads.discardRunning()
        bookmarks.saveNow()
        saveSessionNow()
    }

    // MARK: - Config

    /// What `writeConfig` did. Success only when the bytes are on disk and Paddle runs with them.
    enum ConfigWriteResult {
        case written(PaddleConfig, data: Data, stamp: ConfigStamp?)
        /// These paths changed on disk since the edit's base was read; nothing was written.
        case conflict([[String]])
        case failed(String)
    }

    /// The bytes and stamp of Paddle's last config.json write, so Settings can tell its own writes from hand edits.
    @ObservationIgnored private(set) var lastConfigWrite: (stamp: ConfigStamp, data: Data)?
    /// The write before this one, so writes run one at a time in order.
    @ObservationIgnored private var configWriteTail: Task<Void, Never>?

    /// config.json decoded, or nil (and `configError` set) when it doesn't load.
    private func readConfig() -> PaddleConfig? {
        do {
            let config = try Self.decodeConfigFile(Self.readConfigFile(Paths.config))
            configError = nil
            return config
        } catch {
            configError = "config.json: \(PaddleConfig.describe(error))"
            log.error("\(self.configError ?? "", privacy: .public)")
            return nil
        }
    }

    /// config.json's bytes; a missing file reads as empty (every key at its default).
    static func readConfigFile(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Data()
        }
    }

    /// Decodes config.json, reading an empty file (or one with only a byte-order mark) as `{}` as ConfigFile does.
    static func decodeConfigFile(_ data: Data) throws -> PaddleConfig {
        let blank = data.drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }.isEmpty
        return try PaddleConfig.decode(blank ? Data("{}".utf8) : data)
    }

    /// Settings' write path: applies `changes` to config.json as it is on disk now, where `base` is the copy the
    /// edit started from (a key changed on disk since then is a conflict and nothing is written), writes
    /// atomically to the symlink's target, then runs Paddle on the result. Unapplied hand edits elsewhere in the
    /// file are applied with it.
    func writeConfig(_ changes: [ConfigChange], base: Data) async -> ConfigWriteResult {
        let previous = configWriteTail
        let write = Task { () -> ConfigWriteResult in
            await previous?.value
            return await self.performConfigWrite(changes, base: base)
        }
        configWriteTail = Task { _ = await write.value }
        return await write.value
    }

    private func performConfigWrite(_ changes: [ConfigChange], base: Data) async -> ConfigWriteResult {
        let url = Paths.config.resolvingSymlinksInPath()
        let disk: Data
        do {
            disk = try Self.readConfigFile(url)
        } catch {
            return .failed(error.localizedDescription)
        }
        let data: Data
        switch ConfigFile.apply(changes: changes, base: base, disk: disk) {
        case .success(let edited):
            data = edited
        case .failure(.conflict(let paths)):
            return .conflict(paths)
        case .failure(let error):
            return .failed(Self.describe(error))
        }
        let new: PaddleConfig
        do {
            new = try Self.decodeConfigFile(data)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("config.json write failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        let stamp = ConfigStamp(url)
        if let stamp { lastConfigWrite = (stamp, data) }
        log.info("config.json written: \(changes.map { $0.path.joined(separator: ".") }.joined(separator: ", "), privacy: .public)")
        configError = nil
        await apply(new)
        return .written(new, data: data, stamp: stamp)
    }

    private static func describe(_ error: ConfigWriteError) -> String {
        switch error {
        case .invalidFile(let text): "it can't be edited (\(text))"
        case .badPath(let path): "Paddle can't make an edit at \(path.joined(separator: "."))"
        case .conflict(let paths): "changed on disk at \(paths.map { $0.joined(separator: ".") }.joined(separator: ", "))"
        case .invalidResult(let text): "the edit would leave it invalid (\(text))"
        }
    }

    /// Runs Paddle with `new`, doing for each key that changed what that key needs. `reloading` (Reload Config)
    /// treats every key as changed, so user scripts, block lists, extension folders and history retention are all
    /// re-read even when config.json itself didn't change.
    func apply(_ new: PaddleConfig, reloading: Bool = false) async {
        let changed = Self.changedKeys(config, new)
        let keys = reloading ? Set(PaddleConfig.CodingKeys.allCases) : changed
        config = new
        guard !keys.isEmpty else { return }

        // Every key: the web environment keeps its own copy (user agents, inspector, block lists). This also
        // re-reads user.css and userscripts/.
        web.apply(new)
        if keys.contains(.historyDays) { openHistory() }
        if keys.contains(.shortcuts) { MainMenu.applyShortcuts(new.shortcuts) }
        if keys.contains(.developerTools) {
            // Remote inspection follows at once; the context-menu item needs a new page (its configuration).
            for tab in allTabs { tab.webView?.isInspectable = new.developerTools }
            for ext in extensions.loaded { ext.context.isInspectable = new.developerTools }
        }
        if keys.contains(.showTabMemory) {
            if new.showTabMemory {
                sampleMemory()
            } else {
                for tab in allTabs {
                    tab.memoryBytes = nil
                    tab.sharesProcess = false
                }
            }
            updateSampler()
        }
        if !keys.isDisjoint(with: [.contentBlocking, .filterLists]) { await web.loadContentBlockers() }
        // A newly listed (or re-enabled) list has no file yet, so it is due now rather than at the hourly check.
        if !changed.isDisjoint(with: [.contentBlocking, .filterLists, .filterUpdateDays]) {
            Task { await updateFilterListsIfDue() }
        }
        if !keys.isDisjoint(with: [.extensions, .extensionsInPrivate]) { await extensions.reconcile(config: new) }
        if keys.contains(.extensionsInPrivate) {
            for ext in extensions.loaded { ext.context.hasAccessToPrivateData = new.extensionsInPrivate }
            // Turning extensionsInPrivate off takes extensions out of private windows already open (turning it on
            // applies to new private windows only).
            if !new.extensionsInPrivate {
                for controller in windows where controller.model.isPrivate && controller.model.extensionsAllowed {
                    extensions.windowClosing(controller)
                    controller.model.withdrawExtensions()
                }
            }
        }
        if !keys.isDisjoint(with: [.tabSleepAfterMinutes, .maxAwakeTabs, .sleepPinnedTabs]) { sweepSleepingTabs() }
    }

    /// The keys whose values differ. The switch is exhaustive, so a new key must say how it compares.
    private static func changedKeys(_ old: PaddleConfig, _ new: PaddleConfig) -> Set<PaddleConfig.CodingKeys> {
        Set(PaddleConfig.CodingKeys.allCases.filter { key in
            switch key {
            case .homepage: old.homepage != new.homepage
            case .newTabPage: old.newTabPage != new.newTabPage
            case .searchTemplate: old.searchTemplate != new.searchTemplate
            case .searchSuggestTemplate: old.searchSuggestTemplate != new.searchSuggestTemplate
            case .historyDays: old.historyDays != new.historyDays
            case .tabSleepAfterMinutes: old.tabSleepAfterMinutes != new.tabSleepAfterMinutes
            case .maxAwakeTabs: old.maxAwakeTabs != new.maxAwakeTabs
            case .sleepPinnedTabs: old.sleepPinnedTabs != new.sleepPinnedTabs
            case .contentBlocking: old.contentBlocking != new.contentBlocking
            case .filterLists: old.filterLists != new.filterLists
            case .filterUpdateDays: old.filterUpdateDays != new.filterUpdateDays
            case .userAgentSuffix: old.userAgentSuffix != new.userAgentSuffix
            case .siteUserAgents: old.siteUserAgents != new.siteUserAgents
            case .sites: old.sites != new.sites
            case .showTabMemory: old.showTabMemory != new.showTabMemory
            case .developerTools: old.developerTools != new.developerTools
            case .shortcuts: old.shortcuts != new.shortcuts
            case .extensions: old.extensions != new.extensions
            case .extensionsInPrivate: old.extensionsInPrivate != new.extensionsInPrivate
            }
        })
    }

    /// Paddle > Reload Config: re-reads config.json, user.css, userscripts/, block lists, extension folders and
    /// bookmarks. A config.json that doesn't load keeps the previous settings; everything else is still re-read.
    /// Settings' Apply Now runs the same path without the alert.
    func reloadConfig(showAlert: Bool = true) async {
        await apply(readConfig() ?? config, reloading: true)
        bookmarks.load()
        guard showAlert else { return }

        let alert = NSAlert()
        if let configError {
            alert.alertStyle = .warning
            alert.messageText = "config.json has an error"
            alert.informativeText = "\(configError)\n\nPaddle kept the previous settings. User CSS, scripts and filters were reloaded."
        } else {
            alert.messageText = "Config reloaded"
            alert.informativeText = (["Content blocking:"] + web.blockerStatus).joined(separator: "\n")
                + "\n\n" + (["Extensions:"] + extensions.statusLines).joined(separator: "\n")
                + "\n\nUser CSS, scripts and site user agents apply when a page next loads. userAgentSuffix applies to new tabs."
        }
        alert.runModal()
    }

    /// Extensions > Reload Extensions: unloads every extension and loads the folder again, edited files included.
    func reloadExtensions() async {
        await extensions.reloadAll(config: config)
        let alert = NSAlert()
        alert.messageText = "Extensions reloaded"
        alert.informativeText = extensions.statusLines.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Filter lists

    @ObservationIgnored private var lastFilterCheck = Date.distantPast

    /// Automatic filter-list update: the same download as Paddle > Update Filter Lists, but only for lists that are
    /// due (file missing, or older than `filterUpdateDays`), and without an alert. Runs at launch and at most hourly
    /// from the sweep timer. A failed list writes nothing, so it is due again at the next hourly check; the failure
    /// shows under Content blocking in the Activity popover (`WebEnvironment.filterUpdateProblems`) and in the log.
    func updateFilterListsIfDue() async {
        let now = Date()
        lastFilterCheck = now
        guard config.contentBlocking, !web.isUpdatingFilters else { return }
        let due = web.filterListsDue(now: now)
        guard !due.isEmpty else { return }
        let report = await web.updateFilterLists(due)
        if report.skipped { return }
        if report.failures == 0 {
            log.info("automatic filter update:\n\(report.text, privacy: .public)")
        } else {
            log.error("automatic filter update, \(report.failures) failed:\n\(report.text, privacy: .public)")
        }
    }

    // MARK: - History

    /// Opens history.sqlite and drops visits older than `historyDays`. With historyDays 0 nothing is recorded
    /// (the file is left as it is; Clear History still empties it).
    private func openHistory() {
        defer { historyGeneration += 1 }
        guard config.historyDays > 0 else {
            history = nil
            return
        }
        if history == nil {
            do {
                history = try HistoryStore(path: Paths.history.path)
            } catch {
                log.error("history unavailable: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        pruneHistory()
    }

    @ObservationIgnored private var lastHistoryPrune = Date.distantPast

    /// Retention: drops visits older than `historyDays`. Runs at launch, on Reload Config and daily from the sweep timer.
    private func pruneHistory() {
        guard let history else { return }
        lastHistoryPrune = Date()
        do {
            try history.prune(olderThan: Date().addingTimeInterval(-Double(config.historyDays) * 86_400))
        } catch {
            log.error("history prune failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordVisit(_ url: URL, title: String, typed: Bool) {
        guard let history, HistoryStore.isRecordable(url) else { return }
        do {
            try history.recordVisit(url: url, title: title, typed: typed, at: Date())
            historyGeneration += 1
        } catch {
            log.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateHistoryTitle(_ url: URL, _ title: String) {
        guard let history, !title.isEmpty, HistoryStore.isRecordable(url) else { return }
        try? history.updateTitle(url: url, title: title)
        historyGeneration += 1
    }

    func removeFromHistory(_ url: String) {
        guard let history else { return }
        try? history.remove(url: url)
        historyGeneration += 1
    }

    /// Opens a page from history or bookmarks in the front window: in its current tab, or a background tab.
    /// No window: a new one.
    func openInFrontWindow(_ url: URL, newTab: Bool) {
        guard let front = frontWindow else {
            openWindow(url: url)
            return
        }
        if newTab {
            front.model.newTab(url: url, select: false)
        } else {
            front.model.go(to: url, typed: false)
        }
        front.window?.makeKeyAndOrderFront(nil)
    }

    /// Clears visits since `date`, or everything when nil, plus recently closed tabs. Works with history turned
    /// off too: the file from before is cleared, or deleted when clearing everything.
    func clearHistory(since date: Date?) {
        defer { historyGeneration += 1 }
        windows.forEach { $0.model.forgetClosedTabs() }
        saveSessionNow()
        favicons.forget(since: date, keeping: bookmarks.siteKeys)
        do {
            if let history {
                if let date { try history.removeVisits(since: date) } else { try history.removeAll() }
            } else if FileManager.default.fileExists(atPath: Paths.history.path) {
                if let date {
                    try HistoryStore(path: Paths.history.path).removeVisits(since: date)
                } else {
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(atPath: Paths.history.path + suffix)
                    }
                }
            }
        } catch {
            log.error("clear history failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "History couldn't be cleared"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Windows

    /// `isPrivate`: File > New Private Window. Private windows are never restored, so they never have a `record`.
    /// Extensions are told about a window only when they may see it (private ones need `extensionsInPrivate`).
    @discardableResult
    func openWindow(record: WindowRecord? = nil, url: URL? = nil, isPrivate: Bool = false) -> BrowserWindowController {
        let controller = BrowserWindowController(
            record: isPrivate ? nil : record, isPrivate: isPrivate, extensionsAllowed: !isPrivate || config.extensionsInPrivate
        )
        windows.append(controller)
        if controller.model.extensionsAllowed { extensions.windowOpened(controller) }
        if record == nil {
            if let url {
                controller.model.newTab(url: url)
            } else {
                let home = URL(string: config.homepage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
                controller.model.newTab(url: home)
                if home == nil { controller.model.focusAddress() }
            }
        }
        controller.showWindow(nil)
        return controller
    }

    func windowClosed(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        updateSampler()
        if controller.model.isPrivate, !windows.contains(where: { $0.model.isPrivate }) {
            // The private session ends: a new private window starts with an empty data store.
            web.endPrivateSession()
            downloads.forgetPrivate()
            log.info("last private window closed: private data store released")
        }
        sessionChanged()
    }

    /// The browser window the user was last in, even when another kind of window (History) is in front.
    var frontWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
            ?? windows.last
    }

    /// The front window extensions may see and open things in: the front browser window when the extension host
    /// knows it, else the frontmost one it knows. Private windows aren't known unless `extensionsInPrivate`.
    var frontExtensionWindow: BrowserWindowController? {
        if let front = frontWindow, extensions.isRegistered(front) { return front }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first { self.extensions.isRegistered($0) }
            ?? extensions.registered(windows).last
    }

    /// The browser window the user is in is a private one extensions can't see. Extension actions and commands
    /// started from the menu then do nothing rather than act on a window behind it.
    var frontWindowIsHiddenFromExtensions: Bool {
        guard let front = frontWindow else { return false }
        return !extensions.isRegistered(front)
    }

    /// The front normal (non-private) window, for links from other apps.
    var frontNormalWindow: BrowserWindowController? {
        if let front = frontWindow, !front.model.isPrivate { return front }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first { !$0.model.isPrivate }
            ?? windows.last { !$0.model.isPrivate }
    }

    /// Links from other apps open in a normal window, never a private one, as in Safari and Chrome.
    func open(_ urls: [URL]) {
        for url in urls {
            if let front = frontNormalWindow {
                front.model.newTab(url: url)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(url: url)
            }
        }
    }

    var allTabs: [Tab] { windows.flatMap { $0.model.tabs } }

    /// `newTabPage` from config.json; nil for about:blank (an empty tab).
    var newTabPageURL: URL? {
        URL(string: config.newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
    }

    // MARK: - Session

    private func restoreSession() {
        defer { didRestore = true }
        guard let data = try? Data(contentsOf: Paths.session),
              let session = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return }
        isRestoring = true
        defer { isRestoring = false }
        for record in session.windows where !record.tabs.isEmpty {
            openWindow(record: record)
        }
    }

    /// Debounced save; called on every tab change.
    func sessionChanged() {
        guard !isRestoring else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSessionNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveSessionNow() {
        saveWork?.cancel()
        guard didRestore else { return }
        let session = SessionRecord.saving(windows, isPrivate: \.model.isPrivate, record: \.model.record)
        do {
            try JSONEncoder().encode(session).write(to: Paths.session, options: .atomic)
        } catch {
            log.error("session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Memory: sampling, sleeping, pressure

    private func startMonitoring() {
        // The sampler runs only while its numbers can be seen; these notifications start and stop it.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didChangeOcclusionStateNotification] {
            samplerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.updateSampler() }
            })
        }
        updateSampler()
        let sweep = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let app = AppModel.shared
                app.sweepSleepingTabs()
                if Date().timeIntervalSince(app.lastHistoryPrune) > 86_400 { app.pruneHistory() }
                if Date().timeIntervalSince(app.lastFilterCheck) > 3_600 { Task { await app.updateFilterListsIfDue() } }
            }
        }
        // Nothing in the sweep needs to-the-second timing; tolerance lets macOS batch its wakeup with others.
        sweep.tolerance = 10
        sweepTimer = sweep

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppModel.shared.log.info("memory pressure: sleeping background tabs")
                AppModel.shared.sweepSleepingTabs(memoryPressure: true)
            }
        }
        source.resume()
        memoryPressureSource = source
        measureMemory()
    }

    /// Refreshes the readout when it is shown; UI actions (sleeping a tab) call this.
    func sampleMemory() {
        guard config.showTabMemory || memoryReaders > 0 else { return }
        measureMemory()
    }

    /// A readout that shows memory appeared (Activity popover, Settings' memory pane): samples now and keeps the
    /// sampler running, with `showTabMemory` off too, until the matching `endMemoryReadout()`.
    func beginMemoryReadout() {
        memoryReaders += 1
        measureMemory()
        updateSampler()
    }

    func endMemoryReadout() {
        memoryReaders = max(0, memoryReaders - 1)
        updateSampler()
    }

    /// Runs the 5 s sampler only while Paddle is the active app and a number it feeds can be seen: the toolbar
    /// readout in a browser window that isn't fully covered or minimized, or an open readout. A sampler that
    /// (re)starts samples at once, so returning to Paddle never shows a stale figure.
    private func updateSampler() {
        let windowVisible = windows.contains { $0.window?.occlusionState.contains(.visible) == true }
        let wanted = NSApp.isActive && (memoryReaders > 0 || (config.showTabMemory && windowVisible))
        if wanted, sampleTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { AppModel.shared.measureMemory() }
            }
            timer.tolerance = 1
            sampleTimer = timer
            measureMemory()
        } else if !wanted, let timer = sampleTimer {
            timer.invalidate()
            sampleTimer = nil
        }
    }

    /// Measures every process regardless of `showTabMemory` (the sampler and, later, Settings need the breakdown
    /// either way); the per-tab numbers are only written while the readout is on. Each WebContent process goes to
    /// the tabs whose views it hosts, else to Extensions, Service workers or Other; GPU, Networking, the app
    /// itself and helpers WebKit doesn't list are added on top.
    func measureMemory() {
        let tabs = allTabs
        var owners: [ObjectIdentifier: ViewOwner] = [:]
        for tab in tabs {
            if let webView = tab.webView { owners[ObjectIdentifier(webView)] = .tab(tab.id) }
        }
        for ext in extensions.loaded {
            if let background = extensions.backgroundWebView(of: ext) { owners[ObjectIdentifier(background)] = .extensionView }
        }

        // Helpers outside WebKit's list (AutoFill, audio): a fresh process scan whenever a readout is open.
        let helpers = ProcessMemory.responsibleFootprints(rescan: memoryReaders > 0)
        let breakdown: ProcessBreakdown
        if let snapshot = ProcessMemory.snapshot() {
            // Popups (and anything else the host didn't hand us) are extension views by their URL scheme.
            for (id, view) in snapshot.webViews where owners[id] == nil && view.url?.scheme == ExtensionIdentity.scheme {
                owners[id] = .extensionView
            }
            breakdown = ProcessBreakdown.aggregate(
                processes: snapshot.webContent, owners: owners,
                gpu: snapshot.gpu, networking: snapshot.networking, app: ProcessMemory.selfFootprint(),
                helpers: helpers, reported: snapshot.reported
            )
        } else {
            // Without the process list: each tab's main-frame process only, as before, plus the app itself.
            var views: [pid_t: [ObjectIdentifier]] = [:]
            for tab in tabs {
                guard let webView = tab.webView, let pid = ProcessMemory.pid(of: webView) else { continue }
                views[pid, default: []].append(ObjectIdentifier(webView))
            }
            let processes = views.map { pid, views in
                WebContentProcess(pid: pid, footprint: ProcessMemory.footprint(of: pid) ?? 0, views: views)
            }
            // GPU, Networking and unclaimed WebContent processes then show up under Helpers.
            breakdown = ProcessBreakdown.aggregate(
                processes: processes, owners: owners, app: ProcessMemory.selfFootprint(), helpers: helpers
            )
        }

        // Whole MB, assigned only when they change: footprints move by a few pages every sample, and each
        // assignment would redraw every view that shows one.
        let rounded = breakdown.rounded()
        if memoryBreakdown != rounded { memoryBreakdown = rounded }
        if totalWebMemory != rounded.total { totalWebMemory = rounded.total }
        // With the readout off, leave the per-tab numbers alone so the sampler doesn't show memory the user
        // turned off.
        guard config.showTabMemory else { return }
        for tab in tabs {
            let bytes = rounded.perTab[tab.id], shares = rounded.sharedTabs.contains(tab.id)
            if tab.memoryBytes != bytes { tab.memoryBytes = bytes }
            if tab.sharesProcess != shares { tab.sharesProcess = shares }
        }
    }

    /// Applies the sleep policy across all windows. Visible tabs, pinned tabs (by default),
    /// and tabs playing media or using the camera/mic stay awake.
    func sweepSleepingTabs(memoryPressure: Bool = false) {
        let policy = TabSleepPolicy(config: config)
        Task {
            // Asking each page whether it is playing media is a round trip, and the user can switch tabs
            // meanwhile, so the snapshots are taken from live state after the last await.
            var busy: Set<UUID> = []
            for tab in allTabs where tab.isAwake {
                if await tab.isBusy() { busy.insert(tab.id) }
            }
            // Under memory pressure freeing memory wins over keeping sign-in popups working.
            if !memoryPressure { busy.formUnion(liveOpenerPairs()) }
            let now = Date()
            let selected = Set(windows.compactMap { $0.model.selectedID })
            let tabs = allTabs
            let snapshots = tabs.map { tab in
                // The idle clock starts when playback, capture or the popup ends, not when the tab was last viewed.
                if busy.contains(tab.id) { tab.lastActive = now }
                return TabSnapshot(
                    id: tab.id, lastActive: tab.lastActive, isAwake: tab.isAwake,
                    isSelected: selected.contains(tab.id), isPinned: tab.isPinned, isBusy: busy.contains(tab.id)
                )
            }
            let ids = Set(policy.tabsToSleep(snapshots, now: now, memoryPressure: memoryPressure))
            guard !ids.isEmpty else { return }
            for tab in tabs where ids.contains(tab.id) { tab.sleep() }
            log.info("slept \(ids.count) tab(s)\(memoryPressure ? " under memory pressure" : "", privacy: .public)")
            sampleMemory()
        }
    }

    /// Awake sign-in popups and the awake pages that opened them. They talk through window.opener, which sleeping
    /// either side breaks.
    func liveOpenerPairs() -> Set<UUID> {
        var ids: Set<UUID> = []
        for popup in allTabs where popup.hasLiveOpener && popup.isAwake {
            guard let opener = popup.opener, opener.isAwake, opener.browser != nil else { continue }
            ids.formUnion([popup.id, opener.id])
        }
        return ids
    }

    func sleepBackgroundTabs() {
        sweepSleepingTabs(memoryPressure: true)
    }
}
