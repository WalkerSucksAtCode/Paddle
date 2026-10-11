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
    /// Browsing history (history.sqlite); nil when historyDays is 0 or the database can't be opened.
    @ObservationIgnored private(set) var history: HistoryStore?
    /// Bumped whenever history changes, so an open History window refreshes.
    private(set) var historyGeneration = 0
    /// Total footprint of every WebContent process Paddle's tabs use.
    private(set) var totalWebMemory: UInt64 = 0

    /// Per-session answers to permission prompts (camera, microphone, downloads), keyed by site and kind.
    @ObservationIgnored var grantedPermissions: Set<String> = []
    @ObservationIgnored var refusedPermissions: Set<String> = []
    @ObservationIgnored private(set) var windows: [BrowserWindowController] = []
    @ObservationIgnored private var sampleTimer: Timer?
    @ObservationIgnored private var sweepTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var isRestoring = false
    /// False until session.json has been read, so quitting during startup can't overwrite it with no windows.
    @ObservationIgnored private var didRestore = false

    private init() {}

    // MARK: - Lifecycle

    func start(openingURLs urls: [URL]) async {
        Paths.ensure()
        loadConfig()
        openHistory()
        web.apply(config)
        MainMenu.applyShortcuts(config.shortcuts)
        await web.loadContentBlockers()

        restoreSession()
        if windows.isEmpty { openWindow() }
        open(urls)

        startMonitoring()

        if config.contentBlocking, !config.filterLists.isEmpty, !web.hasDownloadedFilters {
            let report = await web.updateFilterLists()
            log.info("first-run filter download:\n\(report, privacy: .public)")
        }
    }

    func willTerminate() {
        downloads.discardRunning()
        saveSessionNow()
    }

    // MARK: - Config

    private func loadConfig() {
        do {
            config = try PaddleConfig.decode(Data(contentsOf: Paths.config))
            configError = nil
        } catch {
            configError = "config.json: \(PaddleConfig.describe(error))"
            log.error("\(self.configError ?? "", privacy: .public)")
        }
    }

    /// Paddle > Reload Config: re-reads config.json, user.css, userscripts/ and block lists.
    func reloadConfig() async {
        loadConfig()
        openHistory()
        web.apply(config)
        MainMenu.applyShortcuts(config.shortcuts)
        await web.loadContentBlockers()
        sweepSleepingTabs()

        let alert = NSAlert()
        if let configError {
            alert.alertStyle = .warning
            alert.messageText = "config.json has an error"
            alert.informativeText = "\(configError)\n\nPaddle kept the previous settings. User CSS, scripts and filters were reloaded."
        } else {
            alert.messageText = "Config reloaded"
            alert.informativeText = (["Content blocking:"] + web.blockerStatus).joined(separator: "\n")
                + "\n\nUser CSS, scripts and site user agents apply when a page next loads. userAgentSuffix applies to new tabs."
        }
        alert.runModal()
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

    /// Opens a history page in the front window: in its current tab, or a new tab. No window: a new one.
    func openFromHistory(_ url: URL, newTab: Bool) {
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

    @discardableResult
    func openWindow(record: WindowRecord? = nil, url: URL? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(record: record)
        windows.append(controller)
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
        sessionChanged()
    }

    /// The browser window the user was last in, even when another kind of window (History) is in front.
    var frontWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
            ?? windows.last
    }

    func open(_ urls: [URL]) {
        for url in urls {
            if let front = frontWindow {
                front.model.newTab(url: url)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(url: url)
            }
        }
    }

    var allTabs: [Tab] { windows.flatMap { $0.model.tabs } }

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
        let session = SessionRecord(windows: windows.map(\.model.record))
        do {
            try JSONEncoder().encode(session).write(to: Paths.session, options: .atomic)
        } catch {
            log.error("session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Memory: sampling, sleeping, pressure

    private func startMonitoring() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.sampleMemory() }
        }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let app = AppModel.shared
                app.sweepSleepingTabs()
                if Date().timeIntervalSince(app.lastHistoryPrune) > 86_400 { app.pruneHistory() }
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppModel.shared.log.info("memory pressure: sleeping background tabs")
                AppModel.shared.sweepSleepingTabs(memoryPressure: true)
            }
        }
        source.resume()
        memoryPressureSource = source
        sampleMemory()
    }

    func sampleMemory() {
        guard config.showTabMemory else { return }
        var pidCounts: [pid_t: Int] = [:]
        var footprints: [pid_t: UInt64] = [:]
        var tabPids: [(Tab, pid_t)] = []
        for tab in allTabs {
            guard let webView = tab.webView, let pid = ProcessMemory.pid(of: webView) else {
                tab.memoryBytes = nil
                continue
            }
            tabPids.append((tab, pid))
            pidCounts[pid, default: 0] += 1
            if footprints[pid] == nil { footprints[pid] = ProcessMemory.footprint(of: pid) }
        }
        for (tab, pid) in tabPids {
            tab.memoryBytes = footprints[pid] ?? nil
            tab.sharesProcess = (pidCounts[pid] ?? 0) > 1
        }
        totalWebMemory = footprints.values.reduce(0, +)
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
            // A sign-in popup and the page that opened it talk through window.opener, which sleeping either side
            // breaks. Under memory pressure freeing memory wins.
            if !memoryPressure {
                for popup in allTabs where popup.hasLiveOpener && popup.isAwake {
                    guard let opener = popup.opener, opener.isAwake, opener.browser != nil else { continue }
                    busy.formUnion([popup.id, opener.id])
                }
            }
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

    func sleepBackgroundTabs() {
        sweepSleepingTabs(memoryPressure: true)
    }
}
