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
    /// `runtime.id` and the context's `uniqueIdentifier` (its storage is keyed by it).
    let id: String
    let persona: Persona
    /// `ExtensionIdentity.identifier(forFolder:salt:)`: the private id every persona starts from.
    let saltedID: String
    /// Scheme and host of its pages (`moz-extension://<uuid>/` for Firefox, else the id as host).
    let baseURL: URL
    /// The host of its pages: the UUID for Firefox, else `id`.
    let urlHost: String
    /// Its public Chrome id is in use (store id or manifest key).
    let isPublicID: Bool
    /// The user agent its own views send (`Persona.userAgent`); nil for WebKit's own.
    let userAgent: String?
    /// The `extensionCompat` entry it was loaded with. A change to its reload key reloads it; `private` is applied
    /// live (`ExtensionHost.applyPrivateAccess`), so this copy's `inPrivate` can be stale.
    let compat: ExtensionCompatConfig
    /// "v2", "4b", "none" or "off (fallback)", for the log and status.
    let preludeMode: String
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
    /// Whether it runs in private windows: `context.hasAccessToPrivateData`, kept in step by `ExtensionHost.applyPrivateAccess`.
    /// Observed, so the toolbars of private windows redraw when it changes.
    var allowedInPrivate: Bool
    var problems: [String]
    /// Bumped when WebKit reports a change to this extension's action as the toolbar shows it; only its own
    /// buttons redraw.
    var actionGeneration = 0
    @ObservationIgnored weak var host: ExtensionHost?

    init(name: String, setup: ExtensionHost.CompatSetup, entry: ExtensionEntry, manifest: ExtensionManifest, webExtension: WKWebExtension,
         context: WKWebExtensionContext, requested: (permissions: Set<String>, hosts: Set<String>), problems: [String]) {
        self.name = name
        self.id = setup.identity.runtimeID
        self.persona = setup.persona
        self.saltedID = setup.saltedID
        self.baseURL = setup.identity.baseURL
        self.urlHost = setup.identity.urlHost
        self.isPublicID = setup.identity.isPublic
        self.userAgent = setup.userAgent
        self.compat = setup.compat
        self.preludeMode = setup.preludeMode
        self.entry = entry
        self.manifest = manifest
        self.webExtension = webExtension
        self.context = context
        self.requested = requested
        self.problems = problems
        let manifest = webExtension.manifest
        hasAction = manifest["action"] != nil || manifest["browser_action"] != nil || manifest["page_action"] != nil
        allowedInPrivate = context.hasAccessToPrivateData
    }

    var displayName: String { ExtensionPermissionText.sanitize(webExtension.displayName ?? name) }

    /// `url` is one of its pages: its current scheme and host, or (a saved tab from before a persona change) any
    /// host its private id has had.
    func owns(_ url: URL?) -> Bool {
        guard let host = ExtensionIdentity.identifier(of: url)?.lowercased() else { return false }
        return host == urlHost.lowercased() || ExtensionIdentity.privateHosts(saltedID: saltedID).contains(host)
    }
    var version: String { ExtensionPermissionText.sanitize(webExtension.displayVersion ?? webExtension.version ?? "", max: 24) }

    /// Returns a sized, non-template copy of this extension's icon for menus, toolbars, and settings.
    /// Prefers a 2x Retina representation from `action` or `webExtension`, falling back to `manifest.json` on disk.
    func icon(side: CGFloat = 16, action: WKWebExtension.Action? = nil) -> NSImage? {
        let retina = CGSize(width: side * 2, height: side * 2)
        let points = CGSize(width: side, height: side)
        let raw = action?.icon(for: retina)
            ?? action?.icon(for: points)
            ?? webExtension.icon(for: retina)
            ?? webExtension.icon(for: points)
            ?? Self.icon(in: Paths.extensions.appendingPathComponent(name, isDirectory: true), side: side)
        guard let raw else { return nil }
        let image = (raw.copy() as? NSImage) ?? raw
        image.size = NSSize(width: side, height: side)
        image.isTemplate = false
        return image
    }

    /// Loads an extension's icon directly from its unpacked folder on disk by inspecting `manifest.json`.
    static func icon(in root: URL, side: CGFloat = 16) -> NSImage? {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func extractPaths(from value: Any?) -> [(Int, String)] {
            if let path = value as? String, !path.isEmpty {
                return [(Int(side * 2), path)]
            }
            if let dict = value as? [String: Any] {
                return dict.compactMap { k, v in
                    guard let path = v as? String, !path.isEmpty else { return nil }
                    return (Int(k) ?? Int(side * 2), path)
                }
            }
            return []
        }

        var candidates = extractPaths(from: json["icons"])
        for actionKey in ["action", "browser_action", "page_action"] {
            if let actionDict = json[actionKey] as? [String: Any] {
                candidates.append(contentsOf: extractPaths(from: actionDict["default_icon"]))
            }
        }
        guard !candidates.isEmpty else { return nil }
        let target = Int(side * 2)
        let sorted = candidates.sorted { a, b in
            let aGe = a.0 >= target
            let bGe = b.0 >= target
            if aGe != bGe { return aGe }
            return aGe ? (a.0 < b.0) : (a.0 > b.0)
        }
        for (_, relPath) in sorted {
            let clean = relPath.hasPrefix("/") ? String(relPath.dropFirst()) : relPath
            let url = root.appendingPathComponent(clean)
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: side, height: side)
                image.isTemplate = false
                return image
            }
        }
        return nil
    }
}

/// WebExtensions from `extensions/` for one profile: permission decisions, that profile's
/// `WKWebExtensionController`, and the window/tab bookkeeping WebKit needs. Each profile has its own
/// host (`AppModel.extensions(for:)`), so storage, sign-ins, answers, popups and backgrounds are
/// per-profile; folders, updates, overlays and salt are shared (`ExtensionShared`). No controller
/// until some extension is allowed; an empty folder starts none of WebKit's extension machinery.
@Observable
final class ExtensionHost {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    /// The profile this host runs extensions for. Private windows use the default profile's host.
    let profileID: ProfileID
    var isDefaultProfile: Bool { profileID == ProfileStore.defaultID }

    /// Running extensions, sorted by folder name.
    private(set) var loaded: [LoadedExtension] = []
    /// One line per folder for the Reload Config alert and the Extensions menu.
    private(set) var statusLines: [String] = []
    /// Load failures at startup, for a banner in the window.
    private(set) var bannerText: String?
    /// The banner's lines by folder, so loading one extension again doesn't clear another's failure.
    @ObservationIgnored private var bannerFailures: [String: String] = [:]

    @ObservationIgnored private(set) var controller: WKWebExtensionController?
    /// The controller holds its delegate weakly; the host keeps it alive.
    @ObservationIgnored private let controllerDelegate = ExtensionControllerDelegate()
    /// Shows action popups, one at a time.
    @ObservationIgnored let popups = ExtensionPopupPresenter()
    @ObservationIgnored private var decisions = ExtensionDecisions()
    /// The permissions file is unreadable: nothing loads and the file is never overwritten.
    @ObservationIgnored private var decisionsError: String?
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
    /// Folder name to items the user refused at runtime this session; not asked again until relaunch. Permission
    /// names and match patterns as asked; URLs as their site (`ExtensionAccessPolicy.denialKey`).
    @ObservationIgnored private var deniedThisSession: [String: Set<String>] = [:]
    /// Folder name to site requests answered "no" without asking (no tab, no recent user action) this session.
    @ObservationIgnored private(set) var autoDenied: [String: AutoDenials] = [:]
    struct AutoDenials {
        var requests = 0
        /// `ExtensionAccessPolicy.denialKey`s, each with how many requests named it.
        var sites: [String: Int] = [:]
    }
    /// Context id to when the user last acted on that extension: toolbar button, menu item, key command, popup.
    @ObservationIgnored private var lastUserAction: [String: Date] = [:]
    /// Context id of the extension whose popup was shown last; it counts as acting on it while it stays open.
    @ObservationIgnored private var popupContextID: String?
    /// Loads, reconciles, reloads and Ask Again run one at a time, their prompts included. Overlapping runs would
    /// prompt twice for one folder, load it twice, and end each other's deferral of extension-page tabs.
    @ObservationIgnored private var operationQueue: Task<Void, Never>?
    /// The window last reported to WebKit as focused; WebKit fires `windows.onFocusChanged` for every report, even
    /// a repeat. `reportedNoFocus`: nil (no window) was the last report.
    @ObservationIgnored private weak var reportedFocus: BrowserWindowController?
    @ObservationIgnored private var reportedNoFocus = false
    /// Extensions (context ids) whose toolbar buttons redraw on the next run-loop turn.
    @ObservationIgnored private var pendingActionRedraws: Set<String> = []
    /// Native messaging for `ExtensionCompat.busID`.
    @ObservationIgnored let bus = CompatBus()
    /// Folders whose background failed to load with the v2 prelude this session; they run from their own folder
    /// until Reload Extensions or relaunch (E24).
    @ObservationIgnored private var compatOff: Set<String> = []
    /// Folder name to its `errorsDidUpdateNotification` observer, while it runs the v2 prelude.
    @ObservationIgnored private var backgroundObservers: [String: any NSObjectProtocol] = [:]
    /// The profile was deleted: nothing loads again and no controller is made.
    @ObservationIgnored private var isShutDown = false

    private var web: WebEnvironment { AppModel.shared.web }
    private var shared: ExtensionShared { .shared }
    private var salt: String { shared.salt }
    private var entries: [ExtensionEntry] { shared.entries }
    private var scanProblems: [String: String] { shared.scanProblems }
    private var installs: ExtensionInstalls? { shared.installs }
    /// This profile's answers: `extension-permissions.json` for the default profile, `profiles/<id>/` for the others.
    private var decisionsURL: URL {
        isDefaultProfile ? Paths.extensionPermissions : Paths.profileFolder(profileID).appending(path: "extension-permissions.json")
    }

    init(profile: ProfileID = ProfileStore.defaultID) {
        profileID = profile
        controllerDelegate.host = self
    }

    // MARK: - Startup

    /// Reads the salt, the permissions file and the folder. Makes the controller only when some enabled extension
    /// was already allowed to run; otherwise it waits for the first prompt (or never comes to exist).
    func prepare(config: PaddleConfig) {
        #if DEBUG
        if isDefaultProfile { controllerDelegate.verifySelectors() }
        #endif
        shared.prepare()
        readDecisions()
        let allowed = entries.filter { isEnabled($0.name, config: config) && decisionsAllowRunning($0) }
        if allowed.isEmpty {
            log.info("extensions: none enabled, controller not created")
        } else {
            ensureController()
        }
    }

    /// Whether `folder` runs in this profile: config.json `extensions` (folders not listed are on) for the default
    /// profile, the profile's own list in profiles.json (folders not listed are off) for the others.
    func isEnabled(_ folder: String, config: PaddleConfig) -> Bool {
        isDefaultProfile ? config.isExtensionEnabled(folder) : AppModel.shared.profiles.profile(id: profileID).extensions[folder] == true
    }

    /// Why a folder that is turned off doesn't run, for its status line.
    private var offStatus: String { isDefaultProfile ? "off in config.json" : "off in this profile" }

    /// This profile has an answer on record for `folder` (and its permissions file is readable).
    func hasAnswers(for folder: String) -> Bool {
        decisionsError == nil && decisions.byFolder[folder] != nil
    }

    /// An entry whose record says the user allowed something.
    private func decisionsAllowRunning(_ entry: ExtensionEntry) -> Bool {
        guard decisionsError == nil, let snapshot = decisions.byFolder[entry.name] else { return false }
        return !snapshot.isFullyDeclined
    }

    private func readDecisions() {
        guard FileManager.default.fileExists(atPath: decisionsURL.path) else {
            decisions = ExtensionDecisions()
            decisionsError = nil
            return
        }
        do {
            decisions = try ExtensionDecisions.decode(Data(contentsOf: decisionsURL))
            decisionsError = nil
        } catch {
            decisions = ExtensionDecisions()
            decisionsError = "extension-permissions.json: \(error.localizedDescription) (fix or delete it)"
            log.error("\(self.decisionsError ?? "", privacy: .public)")
        }
    }

    private func writeDecisions() {
        guard decisionsError == nil, !isShutDown else { return }
        do {
            if !isDefaultProfile {
                try FileManager.default.createDirectory(at: Paths.profileFolder(profileID), withIntermediateDirectories: true)
            }
            try decisions.encoded().write(to: decisionsURL, options: .atomic)
        } catch {
            log.error("extension-permissions.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The shared first-run records, seeded from this profile's answers if they don't exist yet. Waits while the
    /// permissions file is unreadable.
    private func ensureInstalls() {
        guard decisionsError == nil else { return }
        shared.ensureInstalls(seed: decisions.byFolder.keys)
    }

    private func rescan() {
        shared.rescan()
    }

    // MARK: - Controller

    /// Makes the shared controller. Made late (after a first prompt, or by Reload Config), it is told about the
    /// windows and tabs that already exist; their web views were made without it, so `renewTabsForLoadedContexts`
    /// must follow.
    @discardableResult
    private func ensureController() -> Bool {
        guard controller == nil, !isShutDown else { return false }
        // The default profile keeps WebKit's default configuration, so the extension storage it always had stays;
        // another profile's storage is filed under its own id.
        let configuration: WKWebExtensionController.Configuration
        if isDefaultProfile {
            configuration = .default()
        } else if let uuid = UUID(uuidString: profileID) {
            configuration = WKWebExtensionController.Configuration(identifier: uuid)
        } else {
            log.error("extension controller not created: the profile id is not a UUID")
            return false
        }
        configuration.webViewConfiguration = web.makeExtensionPageBaseConfiguration(profile: profileID)
        configuration.defaultWebsiteDataStore = web.dataStore(for: profileID)
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = controllerDelegate
        self.controller = controller
        web.setExtensionController(controller, for: profileID)
        log.info("extension controller created (\(self.isDefaultProfile ? "default profile" : "another profile", privacy: .public))")

        for window in registeredWindows.compactMap(\.value) {
            controller.didOpenWindow(window.extensionWindow)
            for tab in window.model.extensionTabs { controller.didOpenTab(tab.extensionTab) }
            if let selected = window.model.selectedTab { controller.didActivateTab(selected.extensionTab) }
        }
        reportedFocus = nil
        reportedNoFocus = false
        if let front = AppModel.shared.frontWindow, isRegistered(front), NSApp.isActive {
            reportFocus(front)
        }
        return true
    }

    /// Web views made before an extension context loaded can't be reached by it: its background's `tabs.sendMessage`
    /// to them resolves to nothing, even after the page reloads, though their content scripts run (WebKit; seen live
    /// with Proton Pass, whose autofill click then filled nothing). Web views made before the controller existed
    /// don't carry it at all. So after any context loads, background tabs that aren't busy go to sleep (they wake
    /// with a fresh web view); selected tabs are slept and woken at once, keeping their history. Tabs playing media
    /// or capturing, and sign-in popups with their openers (sleeping either side breaks window.opener), pick it up
    /// on their next wake.
    private func renewTabsForLoadedContexts() async {
        var reloaded = 0
        let paired = AppModel.shared.liveOpenerPairs()
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.allTabs where tab.isAwake && tab.extensionPageID == nil && !paired.contains(tab.id) {
                if window.model.isVisible(tab) {
                    tab.sleep()
                    tab.wake()
                    reloaded += 1
                } else if await !tab.isBusy(), tab.isAwake, !window.model.isVisible(tab) {
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
        guard let config = controller?.extensionContext(for: url)?.webViewConfiguration else { return nil }
        WebEnvironment.configureProcessIdentity(config, displayName: "Paddle Extension")
        return config
    }

    /// A saved extension-page URL from before the folder's persona changed (`webkit-extension://<hex>/` for a
    /// folder now on `moz-extension://<uuid>/`), moved to the running extension's base URL. Nil when `url` is
    /// already current or belongs to no running extension.
    func currentURL(forStale url: URL) -> URL? {
        guard let host = ExtensionIdentity.identifier(of: url)?.lowercased(),
              let ext = loaded.first(where: { $0.owns(url) }) else { return nil }
        if host == ext.urlHost.lowercased(), url.scheme?.lowercased() == ext.baseURL.scheme { return nil }
        let moved = ExtensionIdentity.rebased(url, onto: ext.baseURL)
        if moved != nil { log.info("\(ext.name, privacy: .public): saved tab moved to \(ext.baseURL.absoluteString, privacy: .public)") }
        return moved
    }

    /// The user agent an extension page's web view sends: its extension's persona agent, matched by URL host.
    func userAgent(forPageHost host: String) -> String? {
        loaded.first { $0.urlHost.lowercased() == host.lowercased() }?.userAgent
    }

    /// The persona user agent of the extension that owns `context`.
    func userAgent(for context: WKWebExtensionContext) -> String? {
        loaded.first { $0.context === context }?.userAgent
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
        for tab in tabs where tab.browser != nil && !tab.isAwake && tab.browser?.isVisible(tab) == true {
            tab.wake()
        }
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.allTabs where tab.showsExtensionUnavailable {
                guard loaded.contains(where: { $0.owns(tab.url) }) else { continue }
                tab.sleep()
                if window.model.isVisible(tab) { tab.wake() }
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
                let contextsBefore = Set(loaded.map { ObjectIdentifier($0.context) })
                let pending = await loadEntries(entries, config: config)
                loadsDone.resume()
                for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
                if loaded.contains(where: { !contextsBefore.contains(ObjectIdentifier($0.context)) }) { await renewTabsForLoadedContexts() }
                finishLoad()
            }
        }
    }

    /// Paddle > Reload Config: picks up added, removed, enabled and disabled folders and a changed permissions
    /// file. Edited extension files need Reload Extensions. Folders in `reloading` (a store update just replaced
    /// them) are unloaded and loaded again.
    func reconcile(config: PaddleConfig, reloading: Set<String> = []) async {
        await enqueue { [self] in
            loadInProgress = true
            readDecisions()
            rescan()
            status = [:]
            notes = []
            pruneOverlays()
            let contextsBefore = Set(loaded.map { ObjectIdentifier($0.context) })

            for ext in loaded {
                let entry = entries.first { $0.name == ext.name }
                if entry == nil || entry?.root != ext.entry.root || !isEnabled(ext.name, config: config) {
                    unload(ext, closingTabs: true)  // removed or turned off: its pages close
                    continue
                }
                if decisionsError != nil {
                    unload(ext, closingTabs: false)  // unreadable permissions file: its pages sleep until it is fixed
                    continue
                }
                if reloading.contains(ext.name) {
                    log.info("\(ext.name, privacy: .public): replaced by a store update; reloading it")
                    unload(ext, closingTabs: false)
                    continue
                }
                // The user deleted or edited its record (or a new version asks for more): unload, ask, load again.
                let needsPrompt = decisions.needsPrompt(folder: ext.name, name: ext.displayName, permissions: ext.requested.permissions, hosts: ext.requested.hosts)
                if needsPrompt || decisions.byFolder[ext.name]?.isFullyDeclined == true {
                    unload(ext, closingTabs: false)
                    continue
                }
                // A changed `extensionCompat` entry reloads it: persona, shims and publicID. `private` applies live
                // (`applyPrivateAccess`), so a change to it alone doesn't.
                if ext.compat.reloadKey != config.compat(forFolder: ext.name).reloadKey {
                    log.info("\(ext.name, privacy: .public): extensionCompat changed; reloading it")
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
            if loaded.contains(where: { !contextsBefore.contains(ObjectIdentifier($0.context)) }) { await renewTabsForLoadedContexts() }
            finishLoad()
        }.value
    }

    /// Sets each running extension's private-window access (`extensionAllowedInPrivate`) on its context, live: no
    /// reload. An extension turned off also leaves the private windows already open: its pages there sleep, and a
    /// selected one wakes again into the unavailable page (`Tab.wake` checks `allowsPrivatePage`).
    /// Only the default profile's host: private windows run its extensions.
    func applyPrivateAccess(config: PaddleConfig) {
        guard isDefaultProfile else { return }
        for ext in loaded {
            let allowed = config.extensionAllowedInPrivate(folder: ext.name)
            guard allowed != ext.context.hasAccessToPrivateData else { continue }
            ext.context.hasAccessToPrivateData = allowed
            ext.allowedInPrivate = allowed
            log.info("\(ext.name, privacy: .public): private windows \(allowed ? "on" : "off", privacy: .public)")
            guard !allowed else { continue }
            for window in AppModel.shared.windows where window.model.isPrivate {
                for tab in window.model.allTabs where ext.owns(tab.url) {
                    if tab.isAwake { tab.sleep() }
                    if window.model.isVisible(tab) { tab.wake() }
                }
            }
        }
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
            compatOff = []
            let contextsBefore = Set(loaded.map { ObjectIdentifier($0.context) })
            let pending = await loadEntries(entries, config: config)
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            if loaded.contains(where: { !contextsBefore.contains(ObjectIdentifier($0.context)) }) { await renewTabsForLoadedContexts() }
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
            autoDenied[current.name] = nil
            unload(current, closingTabs: false)
            let config = AppModel.shared.config
            let pending = await loadEntries([current.entry], config: config)
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            finishLoad()
        }.value
    }

    /// Settings > Extensions' Ask About Permissions Again: the same as `askAgain(_:)` for a running extension, and
    /// for one that isn't running (declined, or waiting) it forgets the answers and asks before loading. Does
    /// nothing for a folder turned off in config.json or while the permissions file is unreadable, and the answers
    /// are only erased from the file once the folder has loaded far enough to show the prompt that replaces them.
    func askAgain(folder: String) async {
        await enqueue { [self] in
            let config = AppModel.shared.config
            guard decisionsError == nil, isEnabled(folder, config: config) else { return }
            let current = loaded.first { $0.name == folder }
            guard let entry = current?.entry ?? entries.first(where: { $0.name == folder }) else { return }
            loadInProgress = true
            // Forgotten in memory only so the load pipeline asks; written once a prompt is actually pending, and
            // put back if the folder fails to load first.
            let saved = decisions.byFolder[folder]
            decisions.forget(folder: folder)
            deniedThisSession[folder] = nil
            autoDenied[folder] = nil
            if let current { unload(current, closingTabs: false) }
            let contextsBefore = Set(loaded.map { ObjectIdentifier($0.context) })
            let pending = await loadEntries([entry], config: config)
            if pending.contains(where: { $0.entry.name == folder }) {
                writeDecisions()
            } else if let saved {
                decisions.set(folder: folder, saved)
            }
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            if loaded.contains(where: { !contextsBefore.contains(ObjectIdentifier($0.context)) }) { await renewTabsForLoadedContexts() }
            finishLoad()
        }.value
    }

    /// Items whose answer in the permissions file differs from what the running context holds: a hand edit since it
    /// loaded. Grants with an expiry (`activeTab` on a click) don't count, nativeMessaging is Paddle's to grant, and
    /// unknown permission names and patterns WebKit can't parse are skipped, as loading skips them.
    private func editedItems(_ ext: LoadedExtension) -> [String] {
        guard let file = decisions.byFolder[ext.name] else { return [] }
        let live = liveSnapshot(ext)
        var fileHosts: [String: PermissionDecision] = [:]
        for (string, decision) in file.hosts {
            guard let pattern = try? WKWebExtension.MatchPattern(string: string) else { continue }
            fileHosts[pattern.string] = fileHosts[pattern.string] == .deny ? .deny : decision
        }
        var edited: [String] = []
        // Names WebKit doesn't know are dropped when loading, so they never show up live.
        let known = Set(ext.webExtension.requestedPermissions.union(ext.webExtension.optionalPermissions).map(\.rawValue))
        for (name, decision) in file.permissions where !ExtensionSnapshot.unrecorded.contains(name) && known.contains(name) && live.permissions[name] != decision {
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
        let setup: CompatSetup
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
        // This load's failures replace only these folders' lines in the banner; other folders' lines stay.
        var failures: [String: String] = [:]
        for (name, problem) in scanProblems { status[name] = problem }
        ensureInstalls()

        for entry in entries {
            guard isEnabled(entry.name, config: config) else {
                status[entry.name] = offStatus
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
            // Step 0: persona and identity, then (unless it is a Safari build or compat is off) a patched clone that
            // runs the compat prelude first.
            let setup = compatSetup(for: entry, config: config)
            let (loadRoot, overlayProblem) = await prepareOverlay(for: entry, setup: setup)
            let webExtension: WKWebExtension
            do {
                webExtension = try await WKWebExtension(resourceBaseURL: loadRoot)
            } catch {
                let reason = error.localizedDescription
                status[entry.name] = "failed: \(reason)"
                failures[entry.name] = ExtensionPermissionText.sanitize("Extension “\(entry.name)” didn't load: \(reason)", max: 240)
                log.error("\(entry.name, privacy: .public) failed to load: \(reason, privacy: .public)")
                continue
            }
            let displayName = ExtensionPermissionText.sanitize(webExtension.displayName ?? entry.name)

            let manifest: ExtensionManifest
            do {
                manifest = try ExtensionManifest(data: JSONSerialization.data(withJSONObject: webExtension.manifest))
            } catch {
                status[entry.name] = "failed: manifest unreadable (\(error.localizedDescription))"
                failures[entry.name] = ExtensionPermissionText.sanitize("Extension “\(displayName)” didn't load: manifest unreadable", max: 240)
                continue
            }

            let missing = manifest.missingFiles(in: loadRoot)
            if let first = missing.background.first {
                // A missing service worker hangs the background with no error, so it never gets that far.
                status[entry.name] = "background file \(first) missing, not loaded"
                // `first` comes from the manifest: one sanitized line, like every banner line.
                failures[entry.name] = ExtensionPermissionText.sanitize("Extension “\(displayName)” didn't load: background file \(first) missing", max: 240)
                log.error("\(entry.name, privacy: .public): background file \(first, privacy: .public) missing")
                continue
            }

            // Once per load: webRequestBlocking answers are ignored in WebKit, so this extension can't block requests.
            if let notice = ExtensionBlocking(manifest: manifest).notice {
                log.info("\(entry.name, privacy: .public): \(notice, privacy: .public)")
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
                    entry: entry, setup: setup, webExtension: webExtension, manifest: manifest, problems: problems,
                    requested: requested, undecided: undecided, allSites: allSites
                ))
                continue
            }
            if decisions.byFolder[entry.name]?.isFullyDeclined == true {
                status[entry.name] = "permissions declined"
                continue
            }
            activate(entry, setup, webExtension, manifest: manifest, problems: problems, requested: requested, config: config)
        }
        for entry in entries { bannerFailures[entry.name] = failures[entry.name] }
        bannerText = bannerFailures.isEmpty ? nil : bannerFailures.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
        return pending
    }

    /// Step 6: a context with the recorded permissions, loaded into the controller (made now if it doesn't exist).
    private func activate(
        _ entry: ExtensionEntry, _ setup: CompatSetup, _ webExtension: WKWebExtension, manifest: ExtensionManifest, problems: [String],
        requested: (permissions: Set<String>, hosts: Set<String>), config: PaddleConfig
    ) {
        let identity = setup.identity
        let displayName = ExtensionPermissionText.sanitize(webExtension.displayName ?? entry.name)
        // Two folders resolving to one id (a sideloaded key, the same store id twice) would share storage and pages.
        if let other = loaded.first(where: { $0.name != entry.name && ($0.id == identity.runtimeID || $0.urlHost == identity.urlHost) }) {
            status[entry.name] = "not loaded: same id as \(other.name)"
            log.error("\(entry.name, privacy: .public): refused, resolves to the same id as \(other.name, privacy: .public) (\(identity.runtimeID, privacy: .public))")
            return
        }
        let context = WKWebExtensionContext(for: webExtension)
        // Identifier first, then the base URL (its scheme is registered in `prepare`).
        context.uniqueIdentifier = identity.runtimeID
        context.baseURL = identity.baseURL
        context.isInspectable = config.developerTools
        context.inspectionName = "\(displayName) — Paddle"
        // Private windows the extension may see: its `private` setting, else `extensionsInPrivate`. Kept live by
        // `applyPrivateAccess`. Private windows run the default profile's extensions, so another profile's never do.
        context.hasAccessToPrivateData = isDefaultProfile && config.extensionAllowedInPrivate(folder: entry.name)

        if let snapshot = decisions.byFolder[entry.name] {
            var granted: [WKWebExtension.Permission: Date] = [:]
            var denied: [WKWebExtension.Permission: Date] = [:]
            for (name, decision) in snapshot.permissions where !ExtensionSnapshot.unrecorded.contains(name) {
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
        // nativeMessaging reaches only Paddle's bus (`CompatBus`), so it is granted on the context, never written to the
        // manifest or the permissions file: always under the v2 prelude (which hides it from `permissions.getAll`
        // unless declared), otherwise only when the manifest asks for it.
        let grantsBus = setup.runsV2Prelude || webExtension.requestedPermissions.contains(.nativeMessaging)
            || webExtension.optionalPermissions.contains(.nativeMessaging)
        // Otherwise denied outright: a grant from an earlier v2 run (WebKit may keep it) must not outlive the prelude
        // that hides it, and no native app is ever launched.
        context.setPermissionStatus(grantsBus ? .grantedExplicitly : .deniedExplicitly, for: .nativeMessaging)

        moveStorage(for: entry.name, setup: setup, manifestKey: webExtension.manifest["key"] as? String)
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
            name: entry.name, setup: setup, entry: entry, manifest: manifest, webExtension: webExtension,
            context: context, requested: requested, problems: problems
        )
        ext.host = self
        loaded.append(ext)
        loaded.sort { $0.name < $1.name }
        status[entry.name] = loadedStatus(ext)
        log.info("loaded \(entry.name, privacy: .public) (\(displayName, privacy: .public) \(ext.version, privacy: .public)): persona \(setup.persona.rawValue, privacy: .public), base \(identity.baseURL.absoluteString, privacy: .public), runtime.id \(identity.runtimeID, privacy: .public), \(identity.isPublic ? "public" : "private", privacy: .public) id, prelude \(setup.preludeMode, privacy: .public), nativeMessaging \(grantsBus ? "granted (Paddle bus only)" : "not granted", privacy: .public)")

        if setup.runsV2Prelude { watchBackground(ext) }
        if let reason = setup.plan?.installReason, let plan = setup.plan, installs?.installReason(folder: entry.name) != nil {
            log.info("\(entry.name, privacy: .public): first run in Paddle; runtime.onInstalled gets \(reason, privacy: .public)")
            clearInstallReason(ext, plan: plan)
        }
    }

    /// WebKit files an extension's storage under its context `uniqueIdentifier`. When a persona or `publicID` change
    /// gives a folder a new id, the storage from its earlier id moves to the new one before the context loads, so the
    /// extension keeps its data (sign-ins included). Only when the new id has none yet and exactly one earlier id has
    /// some, and never while a loaded context still uses that id.
    private func moveStorage(for folder: String, setup: CompatSetup, manifestKey: String?) {
        let current = setup.identity.runtimeID
        let root = Paths.webExtensionStorage(profile: profileID)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appending(path: current).path) else { return }
        let keyID = manifestKey.flatMap(ExtensionIdentity.chromeID(manifestKey:))
        let candidates = ExtensionIdentity.priorStorageIDs(saltedID: setup.saltedID, publicIDs: [keyID].compactMap { $0 }, current: current)
            .filter { id in fm.fileExists(atPath: root.appending(path: id).path) && !loaded.contains { $0.id == id } }
        guard let old = candidates.first else { return }
        guard candidates.count == 1 else {
            log.error("\(folder, privacy: .public): storage under more than one earlier id (\(candidates.joined(separator: ", "), privacy: .public)); left as is, starting empty under \(current, privacy: .public)")
            return
        }
        do {
            try fm.moveItem(at: root.appending(path: old), to: root.appending(path: current))
            log.info("\(folder, privacy: .public): storage moved from id \(old, privacy: .public) to \(current, privacy: .public)")
        } catch {
            log.error("\(folder, privacy: .public): storage could not move from \(old, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadedStatus(_ ext: LoadedExtension) -> String {
        var line = "\(ext.displayName) \(ext.version), loaded"
        if let overlay = overlays[ext.name] { line += ", \(overlay.statusText)" }
        if ext.persona == .chrome { line += ", \(ext.isPublicID ? "public" : "private") id" }
        if compatOff.contains(ext.name) { line += ", compat off (its background failed with the prelude)" }
        if !ext.problems.isEmpty { line += ", \(ext.problems.count) problem\(ext.problems.count == 1 ? "" : "s")" }
        return line
    }

    // MARK: - Persona and compat overlay

    /// What one folder runs as: persona, identity, and the prelude plan (nil: no overlay).
    struct CompatSetup {
        let persona: Persona
        let saltedID: String
        let identity: ExtensionIdentity.Resolved
        let compat: ExtensionCompatConfig
        /// The overlay's plan: v2 for chrome/firefox, the 4b prelude for `none`; nil for `native` and compat off.
        let plan: CompatPlan?
        let compatOff: Bool

        var runsV2Prelude: Bool { plan?.persona.runsPersonaPrelude == true }
        var preludeMode: String {
            if compatOff { return "off (fallback)" }
            switch plan?.persona {
            case .chrome, .firefox: return "v2"
            case .none?: return "4b"
            default: return "none"
            }
        }
        /// The persona's user agent, compat off included (the wire identity doesn't depend on the prelude).
        var userAgent: String? { persona.userAgent(plan?.versions ?? .current) }
    }

    /// Detects the persona (`extensionCompat` first, then the manifest), resolves the id and base URL, and builds
    /// the prelude plan. A manifest Paddle can't parse runs as `none` (the 4b path, which then loads it unpatched).
    private func compatSetup(for entry: ExtensionEntry, config: PaddleConfig) -> CompatSetup {
        let salted = ExtensionIdentity.identifier(forFolder: entry.name, salt: salt)
        let compat = config.compat(forFolder: entry.name)
        let data = try? Data(contentsOf: entry.root.appending(path: "manifest.json"))
        let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let manifest = parsed ?? [:]
        // A store install (extension-sources.json) runs as that store's browser and may use its public id.
        let source = StoreInstaller.shared.record(forFolder: entry.name)
        let persona = parsed == nil ? (compat.persona ?? .none) : Persona.detect(manifest: manifest, source: source?.store, override: compat.persona)
        let storeID = source?.store == .chromeWebStore ? source?.id : nil
        let identity = ExtensionIdentity.resolve(persona: persona, saltedID: salted, manifest: manifest, storeID: storeID, publicID: compat.wantsPublicID)
        let off = compatOff.contains(entry.name)
        var plan: CompatPlan?
        if !off {
            switch persona {
            case .chrome, .firefox:
                if let data {
                    do {
                        plan = try CompatPlan.make(
                            manifestData: data, persona: persona, runtimeID: identity.runtimeID, compat: compat,
                            installReason: installs?.installReason(folder: entry.name)
                        )
                    } catch {
                        log.error("\(entry.name, privacy: .public): no compat plan (\(error.localizedDescription, privacy: .public))")
                    }
                }
            case .none:
                plan = CompatPlan(persona: .none, runtimeID: identity.runtimeID)
            case .native:
                plan = nil
            }
        }
        return CompatSetup(persona: persona, saltedID: salted, identity: identity, compat: compat, plan: plan, compatOff: off)
    }

    /// Step 0 of the load pipeline: the patched clone under `extension-overlays/` for the folder's plan (v2 prelude,
    /// worker wrapper and page tags for chrome/firefox; the 4b prelude for `none`), kept while the folder is
    /// unchanged; its generated prelude files are rewritten at every load. The file work runs off the main actor:
    /// a folder on another volume is copied in full. Returns the folder to load from, plus a problem line when the
    /// overlay couldn't be made and the original folder is used. Identity, permissions and storage don't depend on
    /// where it loads from.
    private func prepareOverlay(for entry: ExtensionEntry, setup: CompatSetup) async -> (root: URL, problem: String?) {
        // One writer per overlay folder: a pending install-reason rewrite finishes before the folder is remade.
        if let pending = shared.overlayWrites.removeValue(forKey: entry.name) { await pending.value }
        overlays[entry.name] = nil
        let overlaysFolder = Paths.extensionOverlays
        if setup.compatOff {
            log.notice("\(entry.name, privacy: .public): compat off this session; loading its own folder")
            return (entry.root, nil)
        }
        // A folder that is itself an overlay (a symlink into extension-overlays/) can't be cloned over itself.
        guard !entry.root.path.hasPrefix(overlaysFolder.path + "/") else { return (entry.root, nil) }
        let source = entry.root
        let name = entry.name
        let plan = setup.plan ?? CompatPlan(persona: .native, runtimeID: setup.identity.runtimeID)
        let made = await shared.overlayWork(name) {
            await Task.detached(priority: .userInitiated) {
                Result { try ExtensionOverlay.make(from: source, name: name, in: overlaysFolder, plan: plan) }
            }.value
        }
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

    /// Rewrites the overlay's prelude without the install reason once the first background run has had it, so a
    /// restarted service worker doesn't hear "install" again. The background is woken for this one time (a new
    /// install); the rewrite follows its completion or 10 s, whichever comes first.
    private func clearInstallReason(_ ext: LoadedExtension, plan: CompatPlan) {
        let cleared: CompatPlan = {
            var copy = plan
            copy.installReason = nil
            return copy
        }()
        let name = ext.name
        let source = ext.entry.root
        let overlaysFolder = Paths.extensionOverlays
        let context = ext.context
        let write = Task { @MainActor [weak self, log] in
            // Recorded as seen only once the background has run with the install reason (and not fallen back to
            // compat off), so a crash or a failed first run gets "install" again next time.
            let started = await Self.backgroundStarted(context, timeout: .seconds(10))
            guard let self, started, !self.compatOff.contains(name) else {
                log.notice("\(name, privacy: .public): first background run didn't finish; install reason kept for next time")
                return
            }
            self.shared.markSeen(folder: name)
            let result = await self.shared.overlayWork(name) {
                await Task.detached(priority: .utility) {
                    Result { try ExtensionOverlay.make(from: source, name: name, in: overlaysFolder, plan: cleared) }
                }.value
            }
            if case .failure(let error) = result {
                log.error("\(name, privacy: .public): prelude not rewritten after install: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("\(name, privacy: .public): install reason cleared from the prelude")
            }
        }
        shared.overlayWrites[name] = write
    }

    /// Returns when `loadBackgroundContent` completes or after `timeout`, whichever is first (E24: a failing
    /// background never calls the completion).
    /// True when the load completed without an error, false on an error or the timeout.
    private static func backgroundStarted(_ context: WKWebExtensionContext, timeout: Duration) async -> Bool {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.loadBackgroundContent { error in
                MainActor.assumeIsolated {
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: error == nil)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: false)
            }
        }
    }

    /// E24: a background that fails to load under the v2 prelude (WebKit error 6, `backgroundContentFailedToLoad`;
    /// its load completion is never called) is unloaded and loaded once more from its own folder, compat off, for the
    /// rest of the session. Watched for as long as it runs, so a background WebKit starts late is covered too.
    private func watchBackground(_ ext: LoadedExtension) {
        let name = ext.name
        if let old = backgroundObservers.removeValue(forKey: name) { NotificationCenter.default.removeObserver(old) }
        backgroundObservers[name] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: ext.context, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBackgroundFailure(name) }
        }
        checkBackgroundFailure(name)
        // The user agent goes on the background page's web view once WebKit has made it (polled for 10 s; the
        // memory sampler and the menus apply it later too).
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let current = loaded.first(where: { $0.name == name }), current === ext else { return }
                if backgroundWebView(of: current) != nil { return }
            }
        }
    }

    private func checkBackgroundFailure(_ name: String) {
        guard let ext = loaded.first(where: { $0.name == name }), ext.preludeMode == "v2", !compatOff.contains(name) else { return }
        let failed = ext.context.errors.contains { error in
            let error = error as NSError
            return error.domain == WKWebExtensionContext.errorDomain && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
        }
        guard failed else { return }
        compatOff.insert(name)
        log.error("\(name, privacy: .public): background failed to load with the compat prelude (WebKit error 6); compat off, loading it again from its own folder")
        let config = AppModel.shared.config
        enqueue { [self] in
            guard let current = loaded.first(where: { $0.name == name }) else { return }
            loadInProgress = true
            unload(current, closingTabs: false)
            let pending = await loadEntries([current.entry], config: config)
            for item in pending { await serialized { await self.promptAndLoad(item, config: config) } }
            finishLoad()
        }
    }

    /// A read-only assignment error from an extension that runs the compat prelude: its pinned `browser` / `chrome`
    /// globals cause these on purpose. JavaScriptCore's message doesn't name the property, so extensions without the
    /// prelude keep every such error.
    func isPreludeNoise(_ error: String, extension name: String) -> Bool {
        overlays[name]?.runsPrelude == true && ExtensionCompat.isHarmlessError(error)
    }

    /// Overlays of folders that are gone from `extensions/` are deleted (`ExtensionShared.pruneOverlays`). Only the
    /// default profile's host does it, so the shared files have one writer.
    private func pruneOverlays() {
        guard isDefaultProfile else { return }
        shared.pruneOverlays()
    }

    /// Unloads one extension. Its open pages close (removed or turned off) or sleep until it is back (reload).
    private func unload(_ ext: LoadedExtension, closingTabs: Bool) {
        // The popup on screen is usually the tab's own action's (a click runs `performAction(for: tab)`), not the
        // default action's; the presenter knows which one it showed.
        popups.close(for: ext.context)
        ext.context.action(for: nil)?.closePopup()
        for window in registeredWindows.compactMap(\.value) {
            for tab in window.model.allTabs where ext.owns(tab.url) {
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
        bus.forget(ext.context)
        if let observer = backgroundObservers.removeValue(forKey: ext.name) { NotificationCenter.default.removeObserver(observer) }
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
            notice: ExtensionBlocking(manifest: item.manifest).notice,
            folder: entry.name, isUpgrade: existing.map { !$0.isFullyDeclined } ?? false,
            profile: AppModel.shared.profiles.hasSeveral ? AppModel.shared.profiles.profile(id: profileID).name : nil
        )

        var snapshot = existing ?? ExtensionSnapshot(name: displayName, version: version, decided: Date())
        snapshot.version = version
        snapshot.decided = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        snapshot.apply(answer, requested: item.requested, undecided: item.undecided)
        decisions.set(folder: entry.name, snapshot)
        writeDecisions()
        log.info("\(entry.name, privacy: .public): permission prompt answered \(String(describing: answer), privacy: .public)")

        if snapshot.isFullyDeclined {
            status[entry.name] = "permissions declined"
            return
        }
        activate(entry, item.setup, item.webExtension, manifest: item.manifest, problems: item.problems, requested: item.requested, config: config)
    }

    // MARK: - Store updates (`ExtensionUpdater`)

    /// What a newer version of `folder` asks about before it may replace the copy that runs (`ExtensionPermissionDiff.asks`).
    /// Nil while the permissions file is unreadable, when nothing can be decided.
    func updateAsks(
        folder: String, name: String, requested: ExtensionPermissionDiff.Requests, added: ExtensionPermissionDiff.Requests
    ) -> ExtensionPermissionDiff.Requests? {
        guard decisionsError == nil else { return nil }
        return ExtensionPermissionDiff.asks(requested: requested, added: added, decisions: decisions, folder: folder, name: name)
    }

    /// The update alert, in the queue the install alerts use so that two never overlap. True when the user allowed it.
    func confirmUpdate(
        folder: String, name: String, icon: NSImage?, lines: [String], notice: String?, from current: String, to version: String
    ) async -> Bool {
        await serialized {
            ExtensionPrompts.update(
                name: name, icon: icon, lines: lines, notice: notice, folder: folder, from: current, to: version
            )
        }
    }

    /// Records what an allowed update grants: `asks` become allowed, so the new version loads without asking. Called once the
    /// new copy is in place. If the answers can't be written, the next load asks, as it does for any new request.
    func recordUpdateAllowed(
        folder: String, name: String, version: String, requested: ExtensionPermissionDiff.Requests, asks: ExtensionPermissionDiff.Requests
    ) {
        guard decisionsError == nil else { return }
        var snapshot = decisions.byFolder[folder].flatMap { $0.name == name ? $0 : nil }
            ?? ExtensionSnapshot(name: name, version: version, decided: Date())
        snapshot.version = version
        snapshot.decided = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        snapshot.apply(.allow, requested: requested, undecided: asks)
        decisions.set(folder: folder, snapshot)
        writeDecisions()
        log.info("\(folder, privacy: .public): update to \(version, privacy: .public) allowed; its new requests are granted")
    }

    /// WebKit asking whether an extension may see these URLs. Without a tab (`tabs.query`, a CORS failure) and with
    /// no recent user action on the extension, the answer is "no" at once, counted for the Extensions menu's
    /// Review…; otherwise the user is asked, about sites not refused earlier this session.
    func promptForURLs(_ urls: Set<URL>, in tab: ExtensionTab?, for context: WKWebExtensionContext) async -> Set<URL> {
        guard let ext = loaded.first(where: { $0.context === context }) else { return [] }
        let decision = ExtensionAccessPolicy.classify(kind: .urls, hasTab: tab != nil, recentGesture: userActedRecently(on: context))
        if decision == .autoDeny {
            var denials = autoDenied[ext.name, default: AutoDenials()]
            denials.requests += 1
            for url in urls { denials.sites[ExtensionAccessPolicy.denialKey(url), default: 0] += 1 }
            autoDenied[ext.name] = denials
            // URLs are `.private`: they can be a private window's pages.
            let list = urls.map(\.absoluteString).sorted().joined(separator: ", ")
            log.info("\(ext.name, privacy: .public): site request without a tab or user action auto-denied (\(denials.requests, privacy: .public) so far): \(list, privacy: .private)")
            return []
        }
        let refused = deniedThisSession[ext.name] ?? []
        let ask = urls.filter { !refused.contains(ExtensionAccessPolicy.denialKey($0)) }
        let byString = Dictionary(ask.map { ($0.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        let granted = await promptAtRuntime(permissions: [], hosts: Set(byString.keys), in: tab, for: context, recordRefusals: false)
        let allowed = Set(granted.hosts.compactMap { byString[$0] })
        if allowed.isEmpty, !ask.isEmpty {
            deniedThisSession[ext.name, default: []].formUnion(ask.map(ExtensionAccessPolicy.denialKey))
        }
        return allowed
    }

    /// Grants the sites picked in the Extensions menu's Review… through WebKit; the permission observer persists
    /// them like any other grant.
    func allowAutoDeniedSites(_ sites: Set<String>, for ext: LoadedExtension) {
        for site in sites {
            for pattern in ExtensionAccessPolicy.grantPatterns(forKey: site) {
                guard let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) else {
                    log.error("\(ext.name, privacy: .public): no match pattern for a reviewed site")
                    continue
                }
                ext.context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }
            autoDenied[ext.name]?.sites[site] = nil
            deniedThisSession[ext.name]?.remove(site)
        }
        log.info("\(ext.name, privacy: .public): allowed \(sites.count, privacy: .public) reviewed site(s)")
    }

    /// The user acted on this extension in the last `ExtensionAccessPolicy.gestureWindow`, or its popup is open.
    private func userActedRecently(on context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        if popupContextID == id, popups.shownPopover?.isShown == true { return true }
        guard let last = lastUserAction[id] else { return false }
        return Date().timeIntervalSince(last) < ExtensionAccessPolicy.gestureWindow
    }

    /// Paddle's toolbar button, menu item or key command for `context` ran, or its popup was shown.
    func noteUserAction(on context: WKWebExtensionContext, showingPopup: Bool = false) {
        lastUserAction[context.uniqueIdentifier] = Date()
        if showingPopup { popupContextID = context.uniqueIdentifier }
    }

    /// A running extension asking for more. Items refused earlier this session are refused again without asking.
    /// Returns what the user allowed; the caller hands those back to WebKit, which records them, and the
    /// observer below persists the result.
    /// `allSites`: asked-for patterns WebKit says match every host.
    /// `recordRefusals` false: the caller remembers a refusal its own way (URLs by site).
    func promptAtRuntime(
        permissions: Set<String>, hosts: Set<String>, allSites: Set<String> = [], in tab: ExtensionTab?,
        for context: WKWebExtensionContext, recordRefusals: Bool = true
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
            defer {
                if let behavior, popover?.isShown == true {
                    popover?.behavior = behavior
                    // The alert had the keyboard; give it back to the popup that asked.
                    self.popups.refocusShownPopup()
                }
            }
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
        if recordRefusals { deniedThisSession[ext.name, default: []].formUnion(askPermissions.union(askHosts)) }
        log.info("\(ext.name, privacy: .public): runtime request refused: \(askPermissions.union(askHosts).sorted().joined(separator: ", "), privacy: .public)")
        return ([], [])
    }

    /// Runs `body` after every alert queued before it, from this profile or another (`ExtensionShared.serialized`).
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        await shared.serialized(body)
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
        for tab in window.model.extensionTabs { controller.didOpenTab(tab.extensionTab) }
        if let selected = window.model.selectedTab { controller.didActivateTab(selected.extensionTab) }
        if window.window?.isKeyWindow == true { reportFocus(window) }
    }

    func windowClosing(_ window: BrowserWindowController) {
        guard isRegistered(window) else { return }
        if let controller {
            for tab in window.model.extensionTabs { controller.didCloseTab(tab.extensionTab, windowIsClosing: true) }
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

    /// Whether the extension `context` may see `window`: the window carries the controller, and a private window
    /// also needs the extension allowed in private windows. A nil context (no extension asking) sees any it carries.
    func isVisible(_ window: BrowserWindowController, to context: WKWebExtensionContext?) -> Bool {
        isRegistered(window) && (!window.model.isPrivate || (context?.hasAccessToPrivateData ?? true))
    }

    /// Whether a private window may show `url`: false only for an extension's page whose extension isn't allowed in
    /// private windows. Pages no extension owns are allowed.
    func allowsPrivatePage(_ url: URL) -> Bool {
        loaded.first { $0.owns(url) }?.context.hasAccessToPrivateData ?? true
    }

    /// A tab of a registered window; the link preview counts too (`BrowserModel.extensionTabs`).
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

    /// `oldWindow`: the window the tab left, when it changed windows.
    func tabMoved(_ tab: Tab, from index: Int, in oldWindow: BrowserWindowController? = nil) {
        guard let controller, isRegistered(tab) else { return }
        controller.didMoveTab(tab.extensionTab, from: index, in: (oldWindow ?? tab.browser?.controller)?.extensionWindow)
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
        noteUserAction(on: ext.context)
        ext.context.performAction(for: tab?.extensionTab)
    }

    /// An extension command chosen from the Extensions menu.
    func performCommand(_ command: WKWebExtension.Command, of ext: LoadedExtension) {
        popups.noteUserAction(for: ext.context)
        noteUserAction(on: ext.context)
        ext.context.performCommand(command)
    }

    /// Extension commands run before the page and the window see the key, as in Chrome, so a page that handles
    /// the same key (Google Docs and ⌘⇧L) can't swallow them. A key one of Paddle's menu items uses is left to
    /// the menu. Only in browser windows of this profile, and not while a sheet is up. An extension's command doesn't
    /// run in a private window it isn't allowed in. Called by `ExtensionShared`'s key monitor for the key window's host.
    func performCommandBeforeDispatch(_ event: NSEvent) -> Bool {
        guard controller != nil, !loaded.isEmpty, let window = event.window as? BrowserWindow,
              window.isKeyWindow, window.attachedSheet == nil,
              let browser = window.windowController as? BrowserWindowController, isRegistered(browser) else { return false }
        for ext in loaded where isVisible(browser, to: ext.context) {
            guard let command = ext.context.command(for: event) else { continue }
            if MainMenu.usesKeyEquivalent(command.activationKey, modifiers: command.modifierFlags) {
                log.debug("command \(command.id, privacy: .public) of \(ext.name, privacy: .public): key taken by Paddle's menu")
                return false
            }
            popups.noteUserAction(for: ext.context)
            noteUserAction(on: ext.context)
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
    /// window the extension may see, selecting an existing one.
    func openOptionsPage(for context: WKWebExtensionContext) throws {
        guard let url = context.optionsPageURL else { throw PaddleExtensionError.noOptions }
        let app = AppModel.shared
        for window in app.windows where isVisible(window, to: context) {
            if let tab = window.model.allTabs.first(where: { $0.url == url }) {
                window.model.select(tab)
                window.window?.makeKeyAndOrderFront(nil)
                return
            }
        }
        guard let front = app.frontExtensionWindow(for: context) else {
            app.openWindow(url: url, profile: profileID)
            return
        }
        front.model.newTab(url: url, select: true)
        front.window?.makeKeyAndOrderFront(nil)
    }

    /// The background page's web view, through WebKit's private `_backgroundWebView` (personal build; nil when the
    /// API is gone or the background isn't running).
    /// The persona user agent goes on it here, the first time Paddle sees it (its first requests may still carry
    /// WebKit's own).
    func backgroundWebView(of ext: LoadedExtension) -> WKWebView? {
        let key = "_backgroundWebView"
        guard ext.context.responds(to: NSSelectorFromString(key)), let view = ext.context.value(forKey: key) as? WKWebView else { return nil }
        if let agent = ext.userAgent, view.customUserAgent != agent {
            view.customUserAgent = agent
            log.info("\(ext.name, privacy: .public): background page user agent set (\(ext.persona.rawValue, privacy: .public))")
        }
        return view
    }

    /// The profile is being deleted (its windows are closed): every extension unloads and the controller is let go,
    /// so nothing of the profile's extensions keeps running or holds its data store. Nothing loads again.
    func shutDown() {
        isShutDown = true
        for ext in loaded { unload(ext, closingTabs: false) }
        deferredTabs = []
        registeredWindows = []
        controller?.delegate = nil
        controller = nil
        web.setExtensionController(nil, for: profileID)
        log.info("extension host of a deleted profile shut down")
    }

    /// The window banner's close button. The lines stay in the Extensions menu.
    func dismissBanner() {
        bannerText = nil
        bannerFailures = [:]
    }

    // MARK: - Settings

    /// Every folder in `extensions/` as Settings > Extensions shows it, running or not, sorted by folder name. Built
    /// from the host's state each time it is read (answers can change while an extension runs); the folder list and
    /// status change with each load, reconcile or reload, which also changes `statusLines`.
    var folderSummaries: [ExtensionFolderSummary] {
        Set(entries.map(\.name)).union(scanProblems.keys).sorted().map { name in
            let ext = loaded.first { $0.name == name }
            let record = decisionsError == nil ? decisions.byFolder[name] : nil
            var notes: [String] = []
            if let overlay = overlays[name] { notes.append(overlay.statusText) }
            if let ext { notes += ext.problems.map { ExtensionPermissionText.sanitize($0, max: 240) } }
            let access: ExtensionFolderSummary.Access =
                if decisionsError != nil { .unreadable } else if let record { record.isFullyDeclined ? .declined : .allowed(Self.accessLines(record)) } else { .notAsked }
            return ExtensionFolderSummary(
                folder: name,
                displayName: ext?.displayName ?? record.map { ExtensionPermissionText.sanitize($0.name) } ?? ExtensionPermissionText.sanitize(name),
                version: ext?.version ?? record.map { ExtensionPermissionText.sanitize($0.version, max: 24) } ?? "",
                root: entries.first { $0.name == name }?.root,
                isLoaded: ext != nil,
                status: ext != nil ? "Running" : ExtensionPermissionText.sanitize(status[name] ?? "Not loaded", max: 240),
                access: access,
                compatNotes: notes,
                hasOptionsPage: ext?.context.optionsPageURL != nil
            )
        }
    }

    /// What an allowed extension's record lets it reach, in the install prompt's words.
    private static func accessLines(_ record: ExtensionSnapshot) -> [String] {
        let permissions = Set(record.permissions.filter { $0.value == .allow }.keys)
        let hosts = Set(record.hosts.filter { $0.value == .allow }.keys)
        let onClick = record.hosts.contains { $0.value == .click }
        var lines = onClick && permissions.isEmpty && hosts.isEmpty ? [] : ExtensionPermissionText.lines(permissions: permissions, hosts: hosts)
        if onClick { lines.insert("Sites only when you click its button", at: 0) }
        return lines
    }
}

/// One folder of `extensions/` for Settings: who it is, whether it runs, and what it was allowed.
struct ExtensionFolderSummary: Identifiable, Equatable {
    enum Access: Equatable {
        /// No answer recorded yet (never prompted, or Ask Again pending).
        case notAsked
        /// The permissions file can't be read, so no folder's answers are known.
        case unreadable
        /// Don't Allow: it doesn't load.
        case declined
        /// The allowed items, one line each.
        case allowed([String])
    }

    /// Folder name: the key in config.json's `extensions` and in the permissions file.
    let folder: String
    let displayName: String
    let version: String
    /// The folder holding `manifest.json`; nil when the scan found no loadable extension there.
    let root: URL?
    let isLoaded: Bool
    /// "Running", or why it isn't ("off in config.json", "permissions declined", a load failure).
    let status: String
    let access: Access
    /// The compat overlay's status and the running extension's problems (permissions WebKit drops included).
    let compatNotes: [String]
    let hasOptionsPage: Bool

    var id: String { folder }
}
