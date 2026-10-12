import AppKit
import os
import PaddleCore
import WebKit

/// A weak reference for registries of windows and tabs the host must not keep alive.
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// One extension that is running.
@Observable
final class LoadedExtension: Identifiable {
    /// Folder name under `extensions/`: the key in config.json and the permissions file.
    let name: String
    /// Stable per-install id: `runtime.id` and the host of the extension's `webkit-extension://` URLs.
    let id: String
    let entry: ExtensionEntry
    let manifest: ExtensionManifest
    let webExtension: WKWebExtension
    let context: WKWebExtensionContext
    /// Permission names and match-pattern strings the manifest asks for; the keys of its permission record.
    let requested: (permissions: Set<String>, hosts: Set<String>)
    /// The manifest declares a toolbar action (`action`, or MV2's `browser_action` / `page_action`), so it gets a
    /// toolbar button. WebKit hands back an action object for every extension, so the manifest decides. Read once:
    /// the manifest doesn't change while the extension is loaded.
    let hasAction: Bool
    var problems: [String]
    /// Bumped when WebKit reports a change to this extension's action as the toolbar shows it; only its own
    /// buttons redraw.
    var actionGeneration = 0

    init(name: String, id: String, entry: ExtensionEntry, manifest: ExtensionManifest, webExtension: WKWebExtension,
         context: WKWebExtensionContext, requested: (permissions: Set<String>, hosts: Set<String>), problems: [String]) {
        self.name = name
        self.id = id
        self.entry = entry
        self.manifest = manifest
        self.webExtension = webExtension
        self.context = context
        self.requested = requested
        self.problems = problems
        let manifest = webExtension.manifest
        hasAction = manifest["action"] != nil || manifest["browser_action"] != nil || manifest["page_action"] != nil
    }

    var displayName: String { ExtensionPermissionText.sanitize(webExtension.displayName ?? name) }
    var version: String { ExtensionPermissionText.sanitize(webExtension.displayVersion ?? webExtension.version ?? "", max: 24) }
}

/// Runs WebExtensions from `extensions/` on WebKit's own extension support: scanning, permission decisions,
/// the shared `WKWebExtensionController`, and the window and tab bookkeeping WebKit needs. The controller exists
/// only once some extension is allowed to run; an empty folder starts none of WebKit's extension machinery.
@Observable
final class ExtensionHost {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    /// Running extensions, sorted by folder name.
    private(set) var loaded: [LoadedExtension] = []
    /// One line per folder for the Reload Config alert and the Extensions menu.
    private(set) var statusLines: [String] = []
    /// Load failures at startup, for a banner in the window.
    private(set) var bannerText: String?

    @ObservationIgnored private(set) var controller: WKWebExtensionController?
    /// The controller holds its delegate weakly; the host keeps it alive.
    @ObservationIgnored private let controllerDelegate = ExtensionControllerDelegate()
    /// Shows action popups, one at a time.
    @ObservationIgnored let popups = ExtensionPopupPresenter()
    @ObservationIgnored private var decisions = ExtensionDecisions()
    /// The permissions file is unreadable: nothing loads and the file is never overwritten.
    @ObservationIgnored private var decisionsError: String?
    @ObservationIgnored private var salt = ""
    @ObservationIgnored private var entries: [ExtensionEntry] = []
    @ObservationIgnored private var scanProblems: [String: String] = [:]
    /// Folder name to status text, from the last load, reconcile or reload.
    @ObservationIgnored private var status: [String: String] = [:]
    /// Folder name to the compat overlay it was loaded from (none: loaded from its own folder).
    @ObservationIgnored private var overlays: [String: ExtensionOverlayResult] = [:]
    /// Windows the host knows about, oldest first. Tracked even while there is no controller, so a controller made
    /// later can be told about them.
    @ObservationIgnored private var registeredWindows: [Weak<BrowserWindowController>] = []
    /// Extension-page tabs that tried to wake while their extension wasn't loaded yet.
    @ObservationIgnored private var deferredTabs: [Weak<Tab>] = []
    /// A load, reconcile or reload (prompts included) is in progress, or none has happened yet.
    @ObservationIgnored private var loadInProgress = true
    /// Folder name to items the user refused at runtime this session; not asked again until relaunch.
    @ObservationIgnored private var deniedThisSession: [String: Set<String>] = [:]
    /// Serializes every alert, one at a time.
    @ObservationIgnored private var promptQueue: Task<Void, Never>?
    /// Loads, reconciles, reloads and Ask Again run one at a time, their prompts included. Overlapping runs would
    /// prompt twice for one folder, load it twice, and end each other's deferral of extension-page tabs.
    @ObservationIgnored private var operationQueue: Task<Void, Never>?
    /// The window last reported to WebKit as focused; WebKit fires `windows.onFocusChanged` for every report, even
    /// a repeat. `reportedNoFocus`: nil (no window) was the last report.
    @ObservationIgnored private weak var reportedFocus: BrowserWindowController?
    @ObservationIgnored private var reportedNoFocus = false
    @ObservationIgnored private var permissionObservers: [any NSObjectProtocol] = []
    /// Runs extension commands before the page sees the key.
    @ObservationIgnored private var keyMonitor: Any?
    /// Extensions (context ids) whose toolbar buttons redraw on the next run-loop turn.
    @ObservationIgnored private var pendingActionRedraws: Set<String> = []

    private var web: WebEnvironment { AppModel.shared.web }

    // MARK: - Startup

    /// Reads the salt, the permissions file and the folder. Makes the controller only when some enabled extension
    /// was already allowed to run; otherwise it waits for the first prompt (or never comes to exist).
    func prepare(config: PaddleConfig) {
        #if DEBUG
        controllerDelegate.verifySelectors()
        #endif
        salt = loadOrCreateSalt()
        readDecisions()
        rescan()
        observePermissionChanges()
        installKeyMonitor()
        let allowed = entries.filter { config.isExtensionEnabled($0.name) && decisionsAllowRunning($0) }
        if allowed.isEmpty {
            log.info("extensions: none enabled, controller not created")
        } else {
            ensureController()
        }
    }

    /// An entry whose record says the user allowed something.
    private func decisionsAllowRunning(_ entry: ExtensionEntry) -> Bool {
        guard decisionsError == nil, let snapshot = decisions.byFolder[entry.name] else { return false }
        return !snapshot.isFullyDeclined
    }

    private func loadOrCreateSalt() -> String {
        if let existing = try? String(contentsOf: Paths.extensionSalt, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 32, trimmed.allSatisfy({ $0.isHexDigit }) { return trimmed.lowercased() }
            log.error("extension-id-salt is not 32 hex characters; making a new one (extension ids change)")
        }
        let salt = ExtensionIdentity.makeSalt()
        do {
            try Data(salt.utf8).write(to: Paths.extensionSalt, options: .atomic)
        } catch {
            log.error("extension-id-salt could not be written: \(error.localizedDescription, privacy: .public)")
        }
        return salt
    }

    private func readDecisions() {
        guard FileManager.default.fileExists(atPath: Paths.extensionPermissions.path) else {
            decisions = ExtensionDecisions()
            decisionsError = nil
            return
        }
        do {
            decisions = try ExtensionDecisions.decode(Data(contentsOf: Paths.extensionPermissions))
            decisionsError = nil
        } catch {
            decisions = ExtensionDecisions()
            decisionsError = "extension-permissions.json: \(error.localizedDescription) (fix or delete it)"
            log.error("\(self.decisionsError ?? "", privacy: .public)")
        }
    }

    private func writeDecisions() {
        guard decisionsError == nil else { return }
        do {
            try decisions.encoded().write(to: Paths.extensionPermissions, options: .atomic)
        } catch {
            log.error("extension-permissions.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rescan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = ExtensionScan.scan(Paths.extensions, forbiddenRoots: [home, Paths.support])
        entries = result.entries
        scanProblems = result.problems
        for (name, problem) in scanProblems { log.notice("\(name, privacy: .public): \(problem, privacy: .public)") }
    }

    // MARK: - Controller

    /// Makes the shared controller. Made late (after a first prompt, or by Reload Config), it is told about the
    /// windows and tabs that already exist; their web views were made without it, so `reloadTabsForController`
    /// must follow.
    @discardableResult
    private func ensureController() -> Bool {
        guard controller == nil else { return false }
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.webViewConfiguration = web.makeExtensionPageBaseConfiguration()
        configuration.defaultWebsiteDataStore = web.dataStore
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = controllerDelegate
        self.controller = controller
        web.extensionController = controller
        log.info("extension controller created")

        for window in registeredWindows.compactMap(\.value) {
            controller.didOpenWindow(window.extensionWindow)
            for tab in window.model.tabs { controller.didOpenTab(tab.extensionTab) }
            if let selected = window.model.selectedTab { controller.didActivateTab(selected.extensionTab) }
        }
        reportedFocus = nil
        reportedNoFocus = false
        if let front = AppModel.shared.frontWindow, isRegistered(front), NSApp.isActive {
            reportFocus(front)
        }
        return true
    }

    /// Web views made before the controller existed don't carry it. Background tabs that aren't busy go to
    /// sleep (they wake with it); selected tabs are slept and woken at once, keeping their history. Tabs playing
    /// media or capturing, and sign-in popups with their openers (sleeping either side breaks window.opener),
    /// pick it up on their next wake.
    private func reloadTabsForController() async {
        var reloaded = 0
        let paired = AppModel.shared.liveOpenerPairs()
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.tabs where tab.isAwake && tab.extensionPageID == nil && !paired.contains(tab.id) {
                if tab.id == window.model.selectedID {
                    tab.sleep()
                    tab.wake()
                    reloaded += 1
                } else if await !tab.isBusy(), tab.isAwake, tab.id != window.model.selectedID {
                    // Checked again after the await: the user may have selected it meanwhile.
                    tab.sleep()
                    reloaded += 1
                }
            }
        }
        if reloaded > 0 {
            log.info("open tabs reloaded to run extensions: \(reloaded)")
            notes.append("Open tabs reloaded to run extensions.")
        }
    }

    /// The configuration a tab must use to show `url` (an extension page), or nil when that extension isn't running.
    func pageConfiguration(for url: URL) -> WKWebViewConfiguration? {
        controller?.extensionContext(for: url)?.webViewConfiguration
    }

    /// A tab tried to show an extension page whose extension isn't running. True while a load is in progress (the
    /// tab is woken once it ends); false when nothing is coming, so the tab should show an error page instead.
    func deferWake(_ tab: Tab) -> Bool {
        guard loadInProgress else { return false }
        if !deferredTabs.contains(where: { $0.value === tab }) { deferredTabs.append(Weak(tab)) }
        return true
    }

    /// Only tabs that are showing wake: into their extension's page, or the "Extension not loaded" page when it
    /// didn't load. The rest stay asleep, keeping their URL and history, and wake the same way when selected.
    /// Tabs left on that error page come back once their extension runs again.
    private func resolveDeferredTabs() {
        let tabs = deferredTabs.compactMap(\.value)
        deferredTabs = []
        for tab in tabs where tab.browser != nil && !tab.isAwake && tab.browser?.selectedID == tab.id {
            tab.wake()
        }
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.tabs where tab.showsExtensionUnavailable {
                guard let id = ExtensionIdentity.identifier(of: tab.url), loaded.contains(where: { $0.id == id }) else { continue }
                tab.sleep()
                if window.model.selectedID == tab.id { tab.wake() }
            }
        }
    }

    // MARK: - Loading

    /// Runs `body` after every operation queued before it, and returns the task that runs it.
    @discardableResult
    private func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = operationQueue
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        operationQueue = task
        return task
    }

    /// Loads every enabled extension. Returns once the loads are done; prompts for undecided ones follow in the
    /// same operation without blocking startup.
    func loadAll(config: PaddleConfig) async {
        await withCheckedContinuation { (loadsDone: CheckedContinuation<Void, Never>) in
            enqueue { [self] in
                loadInProgress = true
                log.info("loadAll start: \(self.entries.count) entries")
                status = [:]
                notes = []
                pruneOverlays()
                let hadController = controller != nil
                let pending = await loadEntries(entries, config: config)
                loadsDone.resume()
                for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
                if !hadController, controller != nil { await reloadTabsForController() }
                finishLoad()
            }
        }
    }

    /// Paddle > Reload Config: picks up added, removed, enabled and disabled folders and a changed permissions
    /// file. Edited extension files need Reload Extensions.
    func reconcile(config: PaddleConfig) async {
        await enqueue { [self] in
            loadInProgress = true
            readDecisions()
            rescan()
            status = [:]
            notes = []
            pruneOverlays()
            let hadController = controller != nil

            for ext in loaded {
                let entry = entries.first { $0.name == ext.name }
                if entry == nil || entry?.root != ext.entry.root || !config.isExtensionEnabled(ext.name) {
                    unload(ext, closingTabs: true)  // removed or turned off: its pages close
                    continue
                }
                if decisionsError != nil {
                    unload(ext, closingTabs: false)  // unreadable permissions file: its pages sleep until it is fixed
                    continue
                }
                // The user deleted or edited its record (or a new version asks for more): unload, ask, load again.
                let needsPrompt = decisions.needsPrompt(folder: ext.name, name: ext.displayName, permissions: ext.requested.permissions, hosts: ext.requested.hosts)
                if needsPrompt || decisions.byFolder[ext.name]?.isFullyDeclined == true {
                    unload(ext, closingTabs: false)
                    continue
                }
                // A hand edit of its answers (allow to deny or back): load again with the file's answers.
                let edited = editedItems(ext)
                if !edited.isEmpty {
                    log.info("\(ext.name, privacy: .public): permissions file differs from the running extension (\(edited.joined(separator: ", "), privacy: .public)); reloading it")
                    unload(ext, closingTabs: false)
                    continue
                }
                ext.context.isInspectable = config.developerTools
            }

            let running = Set(loaded.map(\.name))
            let pending = await loadEntries(entries.filter { !running.contains($0.name) }, config: config)
            for ext in loaded where running.contains(ext.name) { status[ext.name] = loadedStatus(ext) }
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            if !hadController, controller != nil { await reloadTabsForController() }
            finishLoad()
        }.value
    }

    /// Extensions > Reload Extensions: unloads everything, then loads the folder again. Open extension pages sleep
    /// and come back once their extension is running again.
    func reloadAll(config: PaddleConfig) async {
        await enqueue { [self] in
            loadInProgress = true
            readDecisions()
            rescan()
            status = [:]
            notes = []
            pruneOverlays()
            for ext in loaded { unload(ext, closingTabs: false) }
            let hadController = controller != nil
            let pending = await loadEntries(entries, config: config)
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            if !hadController, controller != nil { await reloadTabsForController() }
            finishLoad()
        }.value
    }

    /// Forgets the user's answers for one extension and asks again, reloading it with the new answers. Also the
    /// way to take access away while Paddle runs.
    func askAgain(_ ext: LoadedExtension) async {
        await enqueue { [self] in
            // A run queued before this one may have unloaded it already.
            guard let current = loaded.first(where: { $0.name == ext.name }) else { return }
            loadInProgress = true
            decisions.forget(folder: current.name)
            writeDecisions()
            deniedThisSession[current.name] = nil
            unload(current, closingTabs: false)
            let config = AppModel.shared.config
            let pending = await loadEntries([current.entry], config: config)
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            finishLoad()
        }.value
    }

    /// Items whose answer in the permissions file differs from what the running context holds: a hand edit since it
    /// loaded. Grants with an expiry (`activeTab` on a click) don't count, nativeMessaging is always denied, and
    /// unknown permission names and patterns WebKit can't parse are skipped, as loading skips them.
    private func editedItems(_ ext: LoadedExtension) -> [String] {
        guard let file = decisions.byFolder[ext.name] else { return [] }
        let live = liveSnapshot(ext)
        let native = WKWebExtension.Permission.nativeMessaging.rawValue
        var fileHosts: [String: PermissionDecision] = [:]
        for (string, decision) in file.hosts {
            guard let pattern = try? WKWebExtension.MatchPattern(string: string) else { continue }
            fileHosts[pattern.string] = fileHosts[pattern.string] == .deny ? .deny : decision
        }
        var edited: [String] = []
        // Names WebKit doesn't know are dropped when loading, so they never show up live.
        let known = Set(ext.webExtension.requestedPermissions.union(ext.webExtension.optionalPermissions).map(\.rawValue))
        for (name, decision) in file.permissions where name != native && known.contains(name) && live.permissions[name] != decision {
            edited.append(name)
        }
        for (name, decision) in live.permissions where decision == .allow && file.permissions[name] == nil { edited.append(name) }
        for (pattern, decision) in fileHosts where live.hosts[pattern] != decision { edited.append(pattern) }
        for (pattern, decision) in live.hosts where decision == .allow && fileHosts[pattern] == nil { edited.append(pattern) }
        return edited.sorted()
    }

    /// The context's lasting permission state, in the permissions file's form.
    private func liveSnapshot(_ ext: LoadedExtension) -> ExtensionSnapshot {
        let context = ext.context
        let current = decisions.byFolder[ext.name]
        // Only When I Click hosts are in neither of WebKit's sets; carried over from the file (in WebKit's spelling,
        // as `editedItems` compares them) so a save doesn't drop them and re-prompt.
        let clickHosts = Set((current?.hosts ?? [:]).filter { $0.value == .click }.keys.compactMap {
            (try? WKWebExtension.MatchPattern(string: $0))?.string
        })
        return ExtensionSnapshot.from(
            name: ext.displayName, version: ext.version, run: current != nil ? current?.run : .allow,
            granted: Dictionary(uniqueKeysWithValues: context.grantedPermissions.map { ($0.key.rawValue, $0.value) }),
            denied: Dictionary(uniqueKeysWithValues: context.deniedPermissions.map { ($0.key.rawValue, $0.value) }),
            grantedHosts: Dictionary(context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) }, uniquingKeysWith: { a, _ in a }),
            deniedHosts: Dictionary(context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) }, uniquingKeysWith: { a, _ in a }),
            clickHosts: clickHosts, now: Date()
        )
    }

    /// Lines for the alert that aren't about one folder (tabs reloaded for a late controller).
    @ObservationIgnored private var notes: [String] = []

    private func finishLoad() {
        loadInProgress = false
        resolveDeferredTabs()
        var lines: [String] = []
        if let decisionsError { lines.append(ExtensionPermissionText.sanitize(decisionsError, max: 240)) }
        // Folder names and WebKit's error text (which can quote the path) are shown as one line each.
        lines += status.keys.sorted().map { ExtensionPermissionText.sanitize("\($0): \(status[$0] ?? "")", max: 240) }
        if lines.isEmpty { lines = ["none (put unpacked extensions in extensions/)"] }
        lines += notes
        statusLines = lines
        log.info("load end: \(self.loaded.count) loaded\n\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// An extension waiting for the user's answer.
    private struct PendingPrompt {
        let entry: ExtensionEntry
        let webExtension: WKWebExtension
        let manifest: ExtensionManifest
        let problems: [String]
        let requested: (permissions: Set<String>, hosts: Set<String>)
        let undecided: (permissions: Set<String>, hosts: Set<String>)
        /// Requested patterns WebKit says match every host, whatever their spelling.
        let allSites: Set<String>
    }

    /// Steps 1 to 6 of the load pipeline for each entry. Returns the entries that need a prompt before loading.
    private func loadEntries(_ entries: [ExtensionEntry], config: PaddleConfig) async -> [PendingPrompt] {
        var pending: [PendingPrompt] = []
        var failures: [String] = []
        for (name, problem) in scanProblems { status[name] = problem }

        for entry in entries {
            guard config.isExtensionEnabled(entry.name) else {
                status[entry.name] = "off in config.json"
                continue
            }
            if let decisionsError {
                status[entry.name] = "not loaded: \(decisionsError)"
                continue
            }
            // A relative URL traps WKWebExtension.init; the scan makes roots absolute, this is the last guard.
            guard entry.root.isFileURL, entry.root.path.hasPrefix("/") else {
                status[entry.name] = "failed: extension path is not absolute"
                continue
            }
            // Step 0: extensions not built for Safari load from a patched clone that runs the compat prelude first.
            let (loadRoot, overlayProblem) = await prepareOverlay(for: entry)
            let webExtension: WKWebExtension
            do {
                webExtension = try await WKWebExtension(resourceBaseURL: loadRoot)
            } catch {
                let reason = error.localizedDescription
                status[entry.name] = "failed: \(reason)"
                failures.append(ExtensionPermissionText.sanitize("Extension “\(entry.name)” didn't load: \(reason)", max: 240))
                log.error("\(entry.name, privacy: .public) failed to load: \(reason, privacy: .public)")
                continue
            }
            let displayName = ExtensionPermissionText.sanitize(webExtension.displayName ?? entry.name)

            let manifest: ExtensionManifest
            do {
                manifest = try ExtensionManifest(data: JSONSerialization.data(withJSONObject: webExtension.manifest))
            } catch {
                status[entry.name] = "failed: manifest unreadable (\(error.localizedDescription))"
                failures.append(ExtensionPermissionText.sanitize("Extension “\(displayName)” didn't load: manifest unreadable", max: 240))
                continue
            }

            let missing = manifest.missingFiles(in: loadRoot)
            if let first = missing.background.first {
                // A missing service worker hangs the background with no error, so it never gets that far.
                status[entry.name] = "background file \(first) missing, not loaded"
                // `first` comes from the manifest: one sanitized line, like every banner line.
                failures.append(ExtensionPermissionText.sanitize("Extension “\(displayName)” didn't load: background file \(first) missing", max: 240))
                log.error("\(entry.name, privacy: .public): background file \(first, privacy: .public) missing")
                continue
            }

            var problems = webExtension.errors.map(\.localizedDescription).filter { !isPreludeNoise($0, extension: entry.name) }
            if let overlayProblem { problems.append(overlayProblem) }
            problems += missing.other.map { "file \($0) missing" }
            let supported = Set((webExtension.requestedPermissions.union(webExtension.optionalPermissions)).map(\.rawValue))
            let dropped = manifest.unsupportedPermissions(supported: supported)
            if !dropped.isEmpty { problems.append("Dropped by WebKit: \(dropped.joined(separator: ", "))") }
            for problem in problems { log.notice("\(entry.name, privacy: .public): \(problem, privacy: .public)") }

            let requested = (
                permissions: Set(webExtension.requestedPermissions.map(\.rawValue)),
                hosts: Set(webExtension.allRequestedMatchPatterns.map(\.string))
            )
            // Asked before its first load, even when it asks for nothing (the record then says only that it may run).
            if decisions.needsPrompt(folder: entry.name, name: displayName, permissions: requested.permissions, hosts: requested.hosts) {
                status[entry.name] = "waiting for permission answer"
                let undecided = decisions.undecided(folder: entry.name, name: displayName, permissions: requested.permissions, hosts: requested.hosts)
                let allSites = Set(webExtension.allRequestedMatchPatterns.filter { $0.matchesAllHosts || $0.matchesAllURLs }.map(\.string))
                pending.append(PendingPrompt(
                    entry: entry, webExtension: webExtension, manifest: manifest, problems: problems,
                    requested: requested, undecided: undecided, allSites: allSites
                ))
                continue
            }
            if decisions.byFolder[entry.name]?.isFullyDeclined == true {
                status[entry.name] = "permissions declined"
                continue
            }
            activate(entry, webExtension, manifest: manifest, problems: problems, requested: requested, config: config)
        }
        bannerText = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return pending
    }

    /// Step 6: a context with the recorded permissions, loaded into the controller (made now if it doesn't exist).
    private func activate(
        _ entry: ExtensionEntry, _ webExtension: WKWebExtension, manifest: ExtensionManifest, problems: [String],
        requested: (permissions: Set<String>, hosts: Set<String>), config: PaddleConfig
    ) {
        let id = ExtensionIdentity.identifier(forFolder: entry.name, salt: salt)
        let displayName = ExtensionPermissionText.sanitize(webExtension.displayName ?? entry.name)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        context.baseURL = ExtensionIdentity.baseURL(for: id)
        context.isInspectable = config.developerTools
        context.inspectionName = "\(displayName) — Paddle"

        if let snapshot = decisions.byFolder[entry.name] {
            var granted: [WKWebExtension.Permission: Date] = [:]
            var denied: [WKWebExtension.Permission: Date] = [:]
            for (name, decision) in snapshot.permissions {
                let permission = WKWebExtension.Permission(rawValue: name)
                if decision == .allow { granted[permission] = .distantFuture } else { denied[permission] = .distantFuture }
            }
            var grantedHosts: [WKWebExtension.MatchPattern: Date] = [:]
            var deniedHosts: [WKWebExtension.MatchPattern: Date] = [:]
            for (string, decision) in snapshot.hosts {
                guard let pattern = try? WKWebExtension.MatchPattern(string: string) else {
                    log.error("\(entry.name, privacy: .public): ignoring invalid pattern \(string, privacy: .public) in extension-permissions.json")
                    continue
                }
                switch decision {
                case .allow: grantedHosts[pattern] = .distantFuture
                case .deny: deniedHosts[pattern] = .distantFuture
                // Only When I Click: neither, so the pattern stays requested and WebKit's `activeTab` grant on a
                // click can reach the page. An explicit denial would block that grant.
                case .click: break
                }
            }
            context.grantedPermissions = granted
            context.deniedPermissions = denied
            context.grantedPermissionMatchPatterns = grantedHosts
            context.deniedPermissionMatchPatterns = deniedHosts
        }
        // Never, whatever the file says: Paddle launches no native app for an extension.
        context.setPermissionStatus(.deniedExplicitly, for: .nativeMessaging)

        ensureController()
        guard let controller else { return }
        do {
            try controller.load(context)
        } catch {
            status[entry.name] = "failed: \(error.localizedDescription)"
            log.error("\(entry.name, privacy: .public): controller.load failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let ext = LoadedExtension(
            name: entry.name, id: id, entry: entry, manifest: manifest, webExtension: webExtension,
            context: context, requested: requested, problems: problems
        )
        loaded.append(ext)
        loaded.sort { $0.name < $1.name }
        status[entry.name] = loadedStatus(ext)
        log.info("loaded \(entry.name, privacy: .public) (\(displayName, privacy: .public) \(ext.version, privacy: .public)) as \(id, privacy: .public)")
    }

    private func loadedStatus(_ ext: LoadedExtension) -> String {
        var line = "\(ext.displayName) \(ext.version), loaded"
        if let overlay = overlays[ext.name] { line += ", \(overlay.statusText)" }
        if !ext.problems.isEmpty { line += ", \(ext.problems.count) problem\(ext.problems.count == 1 ? "" : "s")" }
        return line
    }

    // MARK: - Compat overlay

    /// Step 0 of the load pipeline: an extension not built for Safari loads from a patched clone of its folder
    /// under `extension-overlays/` (the prelude first in its background scripts and its own content scripts), kept
    /// while the folder is unchanged. The file work runs off the main actor: a folder on another volume is copied in
    /// full. Returns the folder to load from, plus a problem line when the overlay couldn't be made and the original
    /// folder is used. Identity, permissions and storage are keyed by the folder name, so the overlay changes none
    /// of them.
    private func prepareOverlay(for entry: ExtensionEntry) async -> (root: URL, problem: String?) {
        overlays[entry.name] = nil
        let overlaysFolder = Paths.extensionOverlays
        // A folder that is itself an overlay (a symlink into extension-overlays/) can't be cloned over itself.
        guard !entry.root.path.hasPrefix(overlaysFolder.path + "/") else { return (entry.root, nil) }
        let source = entry.root
        let name = entry.name
        let made = await Task.detached(priority: .userInitiated) {
            Result { try ExtensionOverlay.make(from: source, name: name, in: overlaysFolder) }
        }.value
        switch made {
        case .success(nil):
            return (entry.root, nil)
        case .success(let overlay?):
            overlays[entry.name] = overlay
            let how = overlay.reused ? "kept" : (overlay.copiedBytes == nil ? "cloned" : "copied")
            log.info("\(entry.name, privacy: .public): overlay \(how, privacy: .public), \(overlay.statusText, privacy: .public)")
            return (overlay.root, nil)
        case .failure(let error):
            log.error("\(entry.name, privacy: .public): compat overlay not made: \(error.localizedDescription, privacy: .public)")
            return (entry.root, "compat overlay not made (\(error.localizedDescription)); loaded unpatched")
        }
    }

    /// A read-only assignment error from an extension that runs the compat prelude: its pinned `browser` / `chrome`
    /// globals cause these on purpose. JavaScriptCore's message doesn't name the property, so extensions without the
    /// prelude keep every such error.
    func isPreludeNoise(_ error: String, extension name: String) -> Bool {
        overlays[name]?.runsPrelude == true && ExtensionCompat.isHarmlessError(error)
    }

    /// Overlays of folders that are gone from `extensions/` are deleted; the rest are checked against their source
    /// when their extension loads again.
    private func pruneOverlays() {
        ExtensionOverlay.prune(in: Paths.extensionOverlays, keeping: Set(entries.map(\.name)))
    }

    /// Unloads one extension. Its open pages close (removed or turned off) or sleep until it is back (reload).
    private func unload(_ ext: LoadedExtension, closingTabs: Bool) {
        // The popup on screen is usually the tab's own action's (a click runs `performAction(for: tab)`), not the
        // default action's; the presenter knows which one it showed.
        popups.close(for: ext.context)
        ext.context.action(for: nil)?.closePopup()
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.tabs where ExtensionIdentity.identifier(of: tab.url) == ext.id {
                if closingTabs {
                    window.model.close(tab, remember: false)
                } else if tab.isAwake {
                    tab.sleep()
                    _ = deferWake(tab)
                }
            }
        }
        if let controller {
            do {
                try controller.unload(ext.context)
            } catch {
                log.error("\(ext.name, privacy: .public): unload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        loaded.removeAll { $0 === ext }
        log.info("unloaded \(ext.name, privacy: .public)")
    }

    // MARK: - Permissions

    /// The install alert for one extension, then the load if anything was allowed.
    private func promptAndLoad(_ item: PendingPrompt, config: PaddleConfig) async {
        let entry = item.entry
        let displayName = ExtensionPermissionText.sanitize(item.webExtension.displayName ?? entry.name)
        let version = item.webExtension.displayVersion ?? item.webExtension.version ?? ""
        // Keep earlier answers for the same extension; a different extension in the folder starts over.
        let existing = decisions.byFolder[entry.name].flatMap { $0.name == displayName ? $0 : nil }
        let lines = ExtensionPermissionText.lines(
            permissions: item.undecided.permissions, hosts: item.undecided.hosts, allSites: item.allSites
        )
        let answer = ExtensionPrompts.install(
            name: displayName, icon: item.webExtension.icon(for: CGSize(width: 64, height: 64)), lines: lines,
            folder: entry.name, isUpgrade: existing.map { !$0.isFullyDeclined } ?? false
        )

        var snapshot = existing ?? ExtensionSnapshot(name: displayName, version: version, decided: Date())
        snapshot.version = version
        snapshot.decided = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        snapshot.apply(answer, requested: item.requested, undecided: item.undecided,
                       alwaysDenied: [WKWebExtension.Permission.nativeMessaging.rawValue])
        decisions.set(folder: entry.name, snapshot)
        writeDecisions()
        log.info("\(entry.name, privacy: .public): permission prompt answered \(String(describing: answer), privacy: .public)")

        if snapshot.isFullyDeclined {
            status[entry.name] = "permissions declined"
            return
        }
        activate(entry, item.webExtension, manifest: item.manifest, problems: item.problems, requested: item.requested, config: config)
    }

    /// A running extension asking for more. Items refused earlier this session are refused again without asking.
    /// Returns what the user allowed; the caller hands those back to WebKit, which records them, and the
    /// observer below persists the result.
    /// `allSites`: asked-for patterns WebKit says match every host.
    func promptAtRuntime(
        permissions: Set<String>, hosts: Set<String>, allSites: Set<String> = [], in tab: ExtensionTab?, for context: WKWebExtensionContext
    ) async -> (permissions: Set<String>, hosts: Set<String>) {
        guard let ext = loaded.first(where: { $0.context === context }) else { return ([], []) }
        let refused = deniedThisSession[ext.name] ?? []
        let askPermissions = permissions.subtracting(refused)
        let askHosts = hosts.subtracting(refused)
        guard !askPermissions.isEmpty || !askHosts.isEmpty else { return ([], []) }

        let allowed: Bool = await serialized {
            let targetTab = tab?.tab
            let alert = ExtensionPrompts.runtime(
                name: ext.displayName, icon: ext.webExtension.icon(for: CGSize(width: 64, height: 64)),
                lines: ExtensionPermissionText.lines(permissions: askPermissions, hosts: askHosts, allSites: allSites),
                host: targetTab?.url?.host()
            )
            // The popup that asked would close when the alert takes focus; keep it until the answer is in.
            // (`popups.shownPopover`, not `action.popupPopover`: reading that creates a popup web view.)
            let popover = self.popups.shownPopover
            let behavior = popover?.behavior
            if popover?.isShown == true { popover?.behavior = .applicationDefined }
            defer { if let behavior, popover?.isShown == true { popover?.behavior = behavior } }
            // A sheet on the tab that asked only if it is showing now, with no other sheet up; otherwise app-modal.
            // Waiting for the tab to be selected would hold every later alert (install prompts included) for as
            // long as the user stays away from it.
            let response: NSApplication.ModalResponse
            if let targetTab, let window = targetTab.window, targetTab.browser?.selectedID == targetTab.id, window.attachedSheet == nil {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            return response == .alertFirstButtonReturn
        }
        if allowed {
            log.info("\(ext.name, privacy: .public): runtime request allowed: \(askPermissions.union(askHosts).sorted().joined(separator: ", "), privacy: .public)")
            return (askPermissions, askHosts)
        }
        deniedThisSession[ext.name, default: []].formUnion(askPermissions.union(askHosts))
        log.info("\(ext.name, privacy: .public): runtime request refused: \(askPermissions.union(askHosts).sorted().joined(separator: ", "), privacy: .public)")
        return ([], [])
    }

    /// Runs `body` after every alert queued before it.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = promptQueue
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await body()
        }
        promptQueue = Task { _ = await task.value }
        return await task.value
    }

    /// WebKit posts these when a grant or denial is added or removed, including `permissions.remove()` from the
    /// extension itself and the delegate prompts' results; each one persists the context's current state.
    private func observePermissionChanges() {
        guard permissionObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        for name in names {
            permissionObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue (`queue: .main`), so the context is used on its actor.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let context = object as? WKWebExtensionContext else { return }
                    AppModel.shared.extensions.saveSnapshot(for: context)
                }
            })
        }
    }

    /// Writes the context's permission state (WebKit's own patterns, not coarsened) to the permissions file.
    /// Grants with an expiry (`activeTab` on a click) are not kept, so they are asked for again next time.
    func saveSnapshot(for context: WKWebExtensionContext) {
        guard decisionsError == nil, let ext = loaded.first(where: { $0.context === context }) else { return }
        let snapshot = liveSnapshot(ext)
        // `decided` is always "now"; only a change in the answers is worth a write.
        if let current = decisions.byFolder[ext.name], current.name == snapshot.name, current.version == snapshot.version,
           current.permissions == snapshot.permissions, current.hosts == snapshot.hosts, current.run == snapshot.run {
            return
        }
        decisions.set(folder: ext.name, snapshot)
        writeDecisions()
        log.info("\(ext.name, privacy: .public): permission record saved")
    }

    // MARK: - Windows

    func windowOpened(_ window: BrowserWindowController) {
        registeredWindows.removeAll { $0.value == nil }
        guard !isRegistered(window) else { return }
        registeredWindows.append(Weak(window))
        guard let controller else { return }
        controller.didOpenWindow(window.extensionWindow)
        for tab in window.model.tabs { controller.didOpenTab(tab.extensionTab) }
        if let selected = window.model.selectedTab { controller.didActivateTab(selected.extensionTab) }
        if window.window?.isKeyWindow == true { reportFocus(window) }
    }

    func windowClosing(_ window: BrowserWindowController) {
        guard isRegistered(window) else { return }
        if let controller {
            for tab in window.model.tabs { controller.didCloseTab(tab.extensionTab, windowIsClosing: true) }
            controller.didCloseWindow(window.extensionWindow)
        }
        if reportedFocus === window { reportedFocus = nil }
        registeredWindows.removeAll { $0.value == nil || $0.value === window }
    }

    /// App activation and the window becoming key both report the same window, and so does a window taking key back
    /// from a sheet or popover; only a change reaches WebKit.
    func windowFocused(_ window: BrowserWindowController?) {
        guard controller != nil else { return }
        if let window, !isRegistered(window) { return }
        reportFocus(window)
    }

    private func reportFocus(_ window: BrowserWindowController?) {
        guard let controller else { return }
        if let window {
            guard reportedFocus !== window else { return }
            reportedFocus = window
            reportedNoFocus = false
            controller.didFocusWindow(window.extensionWindow)
        } else {
            guard !reportedNoFocus else { return }
            reportedFocus = nil
            reportedNoFocus = true
            controller.didFocusWindow(nil)
        }
    }

    func isRegistered(_ window: BrowserWindowController) -> Bool {
        registeredWindows.contains { $0.value === window }
    }

    /// `windows` filtered to the registered ones, order kept.
    func registered(_ windows: [BrowserWindowController]) -> [BrowserWindowController] {
        windows.filter(isRegistered)
    }

    private func isRegistered(_ tab: Tab) -> Bool {
        guard let window = tab.browser?.controller else { return false }
        return isRegistered(window)
    }

    // MARK: - Tabs

    func tabOpened(_ tab: Tab) {
        guard let controller, isRegistered(tab) else { return }
        controller.didOpenTab(tab.extensionTab)
    }

    /// `windowIsClosing`: it was the window's last tab, so the window closes with it.
    func tabClosed(_ tab: Tab, windowIsClosing: Bool) {
        guard let controller, isRegistered(tab) else { return }
        controller.didCloseTab(tab.extensionTab, windowIsClosing: windowIsClosing)
    }

    func tabActivated(_ tab: Tab, previous: Tab?) {
        guard let controller, isRegistered(tab) else { return }
        controller.didActivateTab(tab.extensionTab, previousActiveTab: previous?.extensionTab)
    }

    func tabMoved(_ tab: Tab, from index: Int) {
        guard let controller, isRegistered(tab) else { return }
        controller.didMoveTab(tab.extensionTab, from: index, in: tab.browser?.controller?.extensionWindow)
    }

    func tabChanged(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        guard let controller, isRegistered(tab) else { return }
        controller.didChangeTabProperties(properties, for: tab.extensionTab)
    }

    // MARK: - Actions and commands

    /// The toolbar button or the Extensions menu. WebKit grants `activeTab` for the tab on this click
    /// (`shouldGrantPermissionsOnUserGesture`), then fires the action's event or asks the delegate to show the
    /// popup, which the presenter shows because Paddle noted the user action first.
    func performAction(_ ext: LoadedExtension, in tab: Tab?) {
        popups.noteUserAction(for: ext.context)
        ext.context.performAction(for: tab?.extensionTab)
    }

    /// An extension command chosen from the Extensions menu.
    func performCommand(_ command: WKWebExtension.Command, of ext: LoadedExtension) {
        popups.noteUserAction(for: ext.context)
        ext.context.performCommand(command)
    }

    /// Extension commands run before the page and the window see the key, as in Chrome, so a page that handles
    /// the same key (Google Docs and ⌘⇧L) can't swallow them. A key one of Paddle's menu items uses is left to
    /// the menu. Only in browser windows, and not while a sheet is up.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, inside the app's event dispatch.
            nonisolated(unsafe) let keyEvent = event
            let handled = MainActor.assumeIsolated { AppModel.shared.extensions.performCommandBeforeDispatch(keyEvent) }
            return handled ? nil : event
        }
    }

    private func performCommandBeforeDispatch(_ event: NSEvent) -> Bool {
        guard controller != nil, !loaded.isEmpty, let window = event.window as? BrowserWindow,
              window.isKeyWindow, window.attachedSheet == nil else { return false }
        for ext in loaded {
            guard let command = ext.context.command(for: event) else { continue }
            if MainMenu.usesKeyEquivalent(command.activationKey, modifiers: command.modifierFlags) {
                log.debug("command \(command.id, privacy: .public) of \(ext.name, privacy: .public): key taken by Paddle's menu")
                return false
            }
            popups.noteUserAction(for: ext.context)
            ext.context.performCommand(command)
            return true
        }
        return false
    }

    /// `didUpdate action`: redraws that extension's buttons on the next run-loop turn, once however many updates
    /// arrive (a blocker's badge count changes per blocked request). Updates to a tab's action are skipped unless
    /// that tab is selected in its window; the toolbar fetches it fresh when the tab is selected.
    func actionUpdated(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) {
        if action.associatedTab != nil {
            guard let tab = (action.associatedTab as? ExtensionTab)?.tab, tab.browser?.selectedID == tab.id else { return }
        }
        let wasEmpty = pendingActionRedraws.isEmpty
        pendingActionRedraws.insert(context.uniqueIdentifier)
        guard wasEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ids = pendingActionRedraws
            pendingActionRedraws = []
            for ext in loaded where ids.contains(ext.id) { ext.actionGeneration += 1 }
        }
    }

    /// `runtime.openOptionsPage()`, the menus and the button's right-click: the options page in a tab of the front
    /// window, selecting an existing one.
    func openOptionsPage(for context: WKWebExtensionContext) throws {
        guard let url = context.optionsPageURL else { throw PaddleExtensionError.noOptions }
        let app = AppModel.shared
        for window in app.windows {
            if let tab = window.model.tabs.first(where: { $0.url == url }) {
                window.model.select(tab)
                window.window?.makeKeyAndOrderFront(nil)
                return
            }
        }
        guard let front = app.frontWindow else {
            app.openWindow(url: url)
            return
        }
        front.model.newTab(url: url, select: true)
        front.window?.makeKeyAndOrderFront(nil)
    }

    /// The background page's web view, through WebKit's private `_backgroundWebView` (personal build; nil when the
    /// API is gone or the background isn't running).
    func backgroundWebView(of ext: LoadedExtension) -> WKWebView? {
        let key = "_backgroundWebView"
        guard ext.context.responds(to: NSSelectorFromString(key)) else { return nil }
        return ext.context.value(forKey: key) as? WKWebView
    }

    /// The window banner's close button. The lines stay in the Extensions menu.
    func dismissBanner() {
        bannerText = nil
    }
}
