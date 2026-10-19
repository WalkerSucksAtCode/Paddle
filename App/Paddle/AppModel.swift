import AppKit
import Foundation
import os
import PaddleCore
import WebKit

/// App-wide state: config, shared WebKit environment, windows, session saving,
/// tab sleeping and memory sampling.
@Observable
final class AppModel {
    static let shared = AppModel()

    private let log = Logger(subsystem: "com.walker.Paddle", category: "app")

    private(set) var config = PaddleConfig()
    /// config.json's bytes as last read or written: what each profile's settings are laid over.
    @ObservationIgnored private var configBytes = Data()
    /// Each profile's config: config.json with the profile's profiles.json `settings` over it (`ProfileOverrides`).
    /// Only profiles that set something are here; the others run on `config`.
    private(set) var profileConfigs: [ProfileID: PaddleConfig] = [:]
    /// What didn't apply from each profile's settings: keys a profile can't set, and values of the wrong type.
    private(set) var profileConfigProblems: [ProfileID: [String]] = [:]
    /// Set when config.json doesn't parse at all (invalid JSON, or a top level that isn't an object); Paddle keeps
    /// running on the previous config.
    private(set) var configError: String?
    /// Values in config.json of the wrong type, and entries or list items Paddle skips: each uses its default (or is
    /// left out) and the rest of the file applies. Listed in Settings > Advanced > Problems. Set on every read and
    /// write of config.json; empty while `configError` is set.
    private(set) var configWarnings: [ConfigIssue] = []
    let web = WebEnvironment()
    let downloads = DownloadStore()
    let bookmarks = BookmarkStore()
    /// The New Tab page's pinned sites (newtab.json).
    let newTab = NewTabStore()
    /// The built-in themes and the files in themes/.
    let themes = ThemeStore()
    let favicons = FaviconStore()
    /// The default profile's extension host (private windows use it too). Other profiles' hosts are made on first
    /// use (`extensions(for:)`).
    let extensions = ExtensionHost()
    /// The other profiles' extension hosts by profile id (`extensions(for:)`).
    @ObservationIgnored var profileExtensionHosts: [ProfileID: ExtensionHost] = [:]
    /// Bookmarks > Show/Hide Bookmarks Bar. Window state, so it lives in user defaults rather than config.json.
    var showBookmarksBar = UserDefaults.standard.object(forKey: "showBookmarksBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBookmarksBar, forKey: "showBookmarksBar") }
    }
    /// The profiles (profiles.json).
    let profiles = ProfileStore()
    /// Browsing history, one database per profile, opened on first use (`history(for:)`).
    @ObservationIgnored private var histories: [ProfileID: HistoryStore] = [:]
    /// Bumped whenever any profile's history changes, so an open History window refreshes.
    private(set) var historyGeneration = 0
    /// Footprint of everything Paddle runs: tab, extension and worker WebContent processes, GPU and Networking,
    /// and the app itself (`memoryBreakdown.total`).
    private(set) var totalWebMemory: UInt64 = 0
    /// The same memory split into the Activity popover's rows.
    private(set) var memoryBreakdown = ProcessBreakdown()

    /// Answers to permission prompts (camera, microphone, location, notifications, downloads) for this run only, by
    /// profile, then site and kind, so an answer given in one profile never carries to another. Settings lists a
    /// profile's under "This session" (`forgetSessionAnswers`).
    var sessionPermissions: [ProfileID: SessionPermissions] = [:]
    /// The same for private windows, kept apart so an answer given in one kind of window doesn't carry to the
    /// other. Not listed in Settings, and dropped when the last private window closes.
    @ObservationIgnored var privatePermissions = SessionPermissions()

    /// `profile`'s `sessionPermissions`, or `privatePermissions` for a private window's tab.
    subscript(permissionsFor isPrivate: Bool, profile profile: ProfileID) -> SessionPermissions {
        get { isPrivate ? privatePermissions : sessionPermissions[profile] ?? SessionPermissions() }
        set { if isPrivate { privatePermissions = newValue } else { sessionPermissions[profile] = newValue } }
    }
    /// Hosts (normalized, without `www.`) the user let load over http:// from the HTTPS-only notice, until Paddle
    /// quits. Never written to disk; private windows share it.
    @ObservationIgnored var httpExceptions: Set<String> = []
    /// Zoom set in private windows, by `sites` key, for this run only: private windows write nothing to config.json.
    @ObservationIgnored var privateZooms: [String: Double] = [:]
    /// Zoom changes waiting to be written to config.json, by `sites` key (`rememberZoom`).
    @ObservationIgnored private var pendingZoomWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var windows: [BrowserWindowController] = []
    @ObservationIgnored private var sampleTimer: Timer?
    @ObservationIgnored private var sweepTimer: Timer?
    /// Each awake tab's CPU use between sweeps, for the CPU-based sleep (`cpuSleepPercent`).
    @ObservationIgnored private var cpuUsage = CPUUsageTracker()
    /// The last "kept running" line the sweep logged, so it logs only when that changes.
    @ObservationIgnored private var lastKeptRunning = ""
    /// When the sweep first saw a WebContent process running service workers with no page in it (`stopOrphanServiceWorkers`).
    @ObservationIgnored private var orphanWorkersSince: Date?
    /// Open readouts that want the 5 s sampler even with `showTabMemory` off (Activity, Settings' memory pane).
    @ObservationIgnored private var memoryReaders = 0
    /// Activation and window-occlusion observers that start and stop the sampler.
    @ObservationIgnored private var samplerObservers: [any NSObjectProtocol] = []
    /// Low Power Mode and the thermal state, kept current by `updatePower`. While they constrain power, the sleep
    /// sweep uses a stricter policy than the configured one (`TabSleepPolicy.adjusted(for:)`).
    private(set) var power = PowerConditions.normal
    @ObservationIgnored private var powerObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var isRestoring = false
    /// False until session.json has been read, so quitting during startup can't overwrite it with no windows.
    @ObservationIgnored private var didRestore = false
    /// session.json and the per-tab state files in sessions/.
    @ObservationIgnored private var sessionStore = SessionStore(file: Paths.session, stateDirectory: Paths.sessions)
    /// When the oldest change not yet saved happened, for the save's maximum delay (`SessionSaveTiming`).
    @ObservationIgnored private var unsavedSince: Date?
    /// Set once the final save has run at quit, so windows closing during teardown can't save a smaller session.
    @ObservationIgnored private var isTerminating = false

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        accessibilityObserver = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.readSystemAccessibility() }
        }
    }

    // MARK: - Appearance and accessibility

    /// macOS's Reduce motion / Reduce transparency settings, kept current by the display-options notification.
    private(set) var systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored private var accessibilityObserver: (any NSObjectProtocol)?

    /// Factor for the chrome's text and spacing (`interfaceTextSize`).
    var chromeScale: Double { config.interfaceTextSize.scale }
    /// Animations in the chrome are off: `reduceMotion` is `always`, or macOS asks for it.
    var reducesMotion: Bool { config.reduceMotion == .always || systemReducesMotion }
    /// Translucent backgrounds in the chrome are opaque: `reduceTransparency` is `always`, or macOS asks for it.
    var reducesTransparency: Bool { config.reduceTransparency == .always || systemReducesTransparency }

    // MARK: - Themes

    /// The theme `theme` names, or nil for Default (and for an id that isn't there).
    var activeTheme: ChromeTheme? { activeTheme(in: config) }
    /// The accent override (`accentColor`); automatic follows the theme, then the system.
    var accentChoice: ColorChoice { accentChoice(in: config) }
    /// The tint over the strip and toolbar (`chromeTint`).
    var tintChoice: ColorChoice { tintChoice(in: config) }
    /// `chromeTintStrength` as 0...1, before any cap.
    var tintStrength: Double { config.chromeTintStrength / 100 }

    /// The same for a window's profile, which may set its own theme, accent and tint.
    func activeTheme(in config: PaddleConfig) -> ChromeTheme? {
        config.theme == "default" ? nil : themes.theme(id: config.theme)
    }
    func accentChoice(in config: PaddleConfig) -> ColorChoice { ColorChoice(configValue: config.accentColor, automaticValue: "system") ?? .automatic }
    func tintChoice(in config: PaddleConfig) -> ColorChoice { ColorChoice(configValue: config.chromeTint, automaticValue: "none") ?? .automatic }

    /// The tint strength actually used in light or dark: `tintStrength`, lowered until the text of the theme (or the
    /// default look) stays readable on both the tab strip and the toolbar. 0 when there is no tint. A theme that sets a
    /// background but not a text color is capped with the default look's text, an approximation of what is drawn.
    func effectiveTintStrength(dark: Bool, in config: PaddleConfig? = nil) -> Double {
        let config = config ?? self.config
        guard let tint = tintChoice(in: config).color else { return 0 }
        return effectiveTintStrength(dark: dark, tint: tint, in: config)
    }

    /// The same cap for a given tint color, such as a space's.
    func effectiveTintStrength(dark: Bool, tint: PaddleCore.RGBColor, in config: PaddleConfig? = nil) -> Double {
        let config = config ?? self.config
        let tintStrength = config.chromeTintStrength / 100
        let palette = activeTheme(in: config)?.palette(dark: dark)
        let text = palette?.text ?? DefaultChromeColors.text(dark: dark)
        let secondary = palette?.secondaryText ?? DefaultChromeColors.secondary(dark: dark)
        let bases = [palette?.tabStrip, palette?.toolbar].map { $0 ?? DefaultChromeColors.base(dark: dark) }
        return bases.map {
            ThemeContrast.maxTintStrength(base: $0, tint: tint, text: text, secondaryText: secondary, requested: tintStrength)
        }.min() ?? tintStrength
    }

    /// Problems with themes, for the config notice: unreadable or misnamed files, bad colors, contrast rules the
    /// active user theme breaks, and a `theme` that names nothing.
    var themeWarnings: [String] {
        var found = themes.warnings
        let id = config.theme
        if id != "default" {
            if let theme = themes.theme(id: id) {
                if !theme.isBuiltIn {
                    for (mode, palette) in [("light", theme.light), ("dark", theme.dark)] {
                        guard let palette else { continue }
                        for issue in ThemeContrast.issues(palette, highContrast: theme.isHighContrast) {
                            found.append("themes/\(id).json: \(mode) \(issue)")
                        }
                    }
                }
            } else if !themes.unreadableIDs.contains(id) {
                found.append("theme \"\(id)\" not found; using Default")
            }
        }
        return found
    }

    private func readSystemAccessibility() {
        systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// `NSApp.appearance` for the `appearance` key: nil follows macOS. Pages follow through their web view's effective appearance.
    var effectiveAppearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for tab in allTabs { tab.refreshPageBackdrop() }
        applySiteDarkMode()
    }

    // MARK: - Lifecycle

    func start(openingURLs urls: [URL]) async {
        let launched = ContinuousClock.now
        Paths.ensure()
        if let loaded = readConfig() { config = loaded }
        profiles.load()
        rebuildProfileConfigs()
        openHistory()
        bookmarks.load()
        newTab.load()
        themes.load()
        web.apply(config)
        applyAppearance(config.appearance)
        MainMenu.applyShortcuts(config.shortcuts)
        MainMenu.setDevelopMenu(visible: config.developerTools)
        extensions.prepare(config: config)

        // Windows open before the block lists are in: tabs make their web views now, and their first page loads
        // wait on `web.blockersReady` (every list installed, or 3 s). Starts once `start` first suspends.
        Task {
            await web.loadContentBlockers()
            reloadUnblockedTabs()
            // After the startup compile and the first windows, so a download never holds up a page.
            await updateFilterListsIfDue()
        }

        restoreSession()
        if windows.isEmpty { openWindow() }
        open(urls)
        let elapsed = (ContinuousClock.now - launched).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        log.info("startup: \(self.windows.count, privacy: .public) windows open \(elapsed, privacy: .public) after start")

        startMonitoring()
        ControlBridge.shared.update(enabled: config.controlBridge)

        // Windows are on screen; extensions find them through the registered windows. Session-restored extension
        // pages wait for this (deferred wake).
        await extensions.loadAll(config: config)
        // Store extensions are checked for updates shortly after launch, then hourly (`ExtensionUpdater.checkIfDue`).
        Task {
            try? await Task.sleep(for: .seconds(30))
            await ExtensionUpdater.shared.checkIfDue(config: AppModel.shared.config)
        }
    }

    /// Pages that loaded while startup block lists were still compiling (after the gate's timeout) reload once,
    /// now that every list is installed. Nothing to do when the gate opened on time.
    private func reloadUnblockedTabs() {
        for tab in allTabs where tab.loadedUnblocked {
            Task { await tab.reloadIfLoadedUnblocked() }
        }
    }

    func willTerminate() {
        ControlBridge.shared.stop()
        downloads.discardRunning()
        bookmarks.saveNow()
        newTab.saveNow()
        saveSessionNow()
        isTerminating = true
    }

    // MARK: - Config

    /// What `writeConfig` did. Success only when the bytes are on disk and Paddle runs with them.
    enum ConfigWriteResult {
        /// `issues` are the values of the written file that fell back or were skipped (see `configWarnings`).
        case written(PaddleConfig, issues: [ConfigIssue], data: Data, stamp: ConfigStamp?)
        /// These paths changed on disk since the edit's base was read; nothing was written.
        case conflict([[String]])
        case failed(String)
    }

    /// The bytes and stamp of Paddle's last config.json write, so Settings can tell its own writes from hand edits.
    @ObservationIgnored private(set) var lastConfigWrite: (stamp: ConfigStamp, data: Data)?
    /// The write before this one, so writes run one at a time in order.
    @ObservationIgnored private var configWriteTail: Task<Void, Never>?

    /// config.json decoded, or nil (and `configError` set) when it doesn't parse. Values of the wrong type don't stop
    /// the read: they use their defaults and are kept in `configWarnings`.
    private func readConfig() -> PaddleConfig? {
        do {
            let data = try Self.readConfigFile(Paths.config)
            let decoded = try Self.decodeConfigFile(data)
            configBytes = data
            configError = nil
            setConfigWarnings(decoded.issues)
            return decoded.config
        } catch {
            configError = "config.json: \(PaddleConfig.describe(error))"
            configWarnings = []
            log.error("\(self.configError ?? "", privacy: .public)")
            return nil
        }
    }

    /// Keeps `issues` as the config warnings and logs each one, once per read or write of config.json.
    private func setConfigWarnings(_ issues: [ConfigIssue]) {
        configWarnings = issues
        for issue in issues {
            log.error("config.json: \(issue.path.joined(separator: "."), privacy: .public) : \(issue.message, privacy: .public)")
        }
    }

    /// "1 value has the wrong type and uses its default", or the plural: the config warnings counted in words.
    var configWarningPhrase: String {
        configWarnings.count == 1
            ? "1 value has the wrong type and uses its default"
            : "\(configWarnings.count) values have the wrong type and use their defaults"
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
    /// Also returns the values that fell back or were skipped (`PaddleConfig.decodeReportingIssues`). Throws only
    /// when the file isn't JSON or its top level isn't an object.
    static func decodeConfigFile(_ data: Data) throws -> (config: PaddleConfig, issues: [ConfigIssue]) {
        let blank = data.drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }.isEmpty
        return try PaddleConfig.decodeReportingIssues(blank ? Data("{}".utf8) : data)
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
        var disk: Data
        do {
            disk = try Self.readConfigFile(url)
        } catch {
            return .failed(error.localizedDescription)
        }
        var data: Data
        var recomputed = false
        while true {
            switch ConfigFile.apply(changes: changes, base: base, disk: disk) {
            case .success(let edited):
                data = edited
            case .failure(.conflict(let paths)):
                return .conflict(paths)
            case .failure(let error):
                return .failed(Self.describe(error))
            }
            // A hand edit that landed since the read above: apply the change again on top of it (once) rather than
            // overwrite it. This narrows the window to the atomic write itself; it doesn't close it.
            let current: Data
            do {
                current = try Self.readConfigFile(url)
            } catch {
                return .failed(error.localizedDescription)
            }
            if current == disk { break }
            if recomputed { return .failed("config.json changed while saving; try again") }
            recomputed = true
            disk = current
        }
        let new: (config: PaddleConfig, issues: [ConfigIssue])
        do {
            new = try Self.decodeConfigFile(data)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("config.json write failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        let stamp = ConfigStamp(url)
        if let stamp { lastConfigWrite = (stamp, data) }
        configBytes = data
        log.info("config.json written: \(changes.map { $0.path.joined(separator: ".") }.joined(separator: ", "), privacy: .public)")
        configError = nil
        setConfigWarnings(new.issues)
        await apply(new.config)
        return .written(new.config, issues: new.issues, data: data, stamp: stamp)
    }

    private static func describe(_ error: ConfigWriteError) -> String {
        switch error {
        case .invalidFile(let text): "it can't be edited (\(text))"
        case .badPath(let path): "Paddle can't make an edit at \(path.joined(separator: "."))"
        case .conflict(let paths): "changed on disk at \(paths.map { $0.joined(separator: ".") }.joined(separator: ", "))"
        case .invalidResult(let text): "the edit would leave it invalid (\(text))"
        }
    }

    /// The config windows of `profile` run with: its own settings over config.json, or `config` when it sets none.
    func config(for profile: ProfileID) -> PaddleConfig { profileConfigs[profile] ?? config }

    /// Recomputes `profileConfigs` from config.json's bytes and profiles.json; returns the profiles whose config
    /// changed. A config.json that can't be read keeps the profiles' previous configs.
    @discardableResult
    func rebuildProfileConfigs() -> Set<ProfileID> {
        // `configBytes` is the last config.json that read, so a broken file still lets profile edits apply.
        var configs: [ProfileID: PaddleConfig] = [:]
        var problems: [ProfileID: [String]] = [:]
        for profile in profiles.all where !profile.settings.isEmpty {
            let dropped = ProfileOverrides.sanitized(profile.settings).dropped
            var notes = dropped.map { "\($0) can't be set per profile; config.json's value applies" }
            if let effective = try? ProfileOverrides.effectiveConfig(globalData: configBytes, overrides: profile.settings) {
                if effective.config != config { configs[profile.id] = effective.config }
                notes += effective.issues.map { "\($0.path.joined(separator: ".")): \($0.message)" }
            }
            if !notes.isEmpty {
                problems[profile.id] = notes
                for note in notes { log.error("profiles.json \(profile.id, privacy: .public): \(note, privacy: .public)") }
            }
        }
        let ids = Set(configs.keys).union(profileConfigs.keys)
        let changed = Set(ids.filter { configs[$0] != profileConfigs[$0] })
        profileConfigs = configs
        if profileConfigProblems != problems { profileConfigProblems = problems }
        return changed
    }

    /// A profile's settings changed in profiles.json (Settings > Profiles, or Reload Config): what config.json's
    /// `apply` does for the keys a profile can set. The chrome (theme, tint) follows by observation.
    func profileConfigsChanged(_ changed: Set<ProfileID>, from old: [ProfileID: PaddleConfig] = [:], reloading: Bool = false) async {
        guard !changed.isEmpty || reloading else { return }
        // Only the work a changed key needs (a run of zoom steps or an edit shouldn't rebuild scripts each time).
        func differs<V: Equatable>(_ value: (PaddleConfig) -> V) -> Bool {
            reloading || changed.contains { value(old[$0] ?? config) != value(config(for: $0)) }
        }
        if differs(\.keepPageWorkRunning) { web.reloadUserScripts() }
        if differs(\.historyDays) { openHistory() }
        if differs(\.sites) { applySiteZoom() }
        if differs({ TabSleepPolicy(config: $0) }) || differs(\.keepPageWorkRunning) || differs(\.keepNotifyingSitesLive) || differs(\.sites) {
            sweepSleepingTabs()
        }
    }

    /// Settings > Profiles changed an override (or a profile was deleted): rebuild, then apply what changed.
    func profileSettingsEdited() {
        let old = profileConfigs
        let changed = rebuildProfileConfigs()
        Task { await profileConfigsChanged(changed, from: old) }
    }

    /// Some profile keeps uploads and unsaved changes running, so pages need the page-work script (it is shared).
    var anyProfileKeepsPageWork: Bool { config.keepPageWorkRunning || profileConfigs.values.contains(where: \.keepPageWorkRunning) }

    /// Runs Paddle with `new`, doing for each key that changed what that key needs. `reloading` (Reload Config)
    /// treats every key as changed, so user scripts, block lists, extension folders and history retention are all
    /// re-read even when config.json itself didn't change.
    func apply(_ new: PaddleConfig, reloading: Bool = false) async {
        let changed = Self.changedKeys(config, new)
        let keys = reloading ? Set(PaddleConfig.CodingKeys.allCases) : changed
        let old = config
        config = new
        let oldProfiles = profileConfigs
        let profilesChanged = rebuildProfileConfigs()
        if !profilesChanged.isEmpty, keys.isEmpty { await profileConfigsChanged(profilesChanged, from: oldProfiles) }
        guard !keys.isEmpty else { return }

        // Every key: the web environment keeps its own copy (user agents, inspector, block lists). This also
        // re-reads user.css and userscripts/.
        web.apply(new)
        if keys.contains(.historyDays) { openHistory() }
        if keys.contains(.shortcuts) { MainMenu.applyShortcuts(new.shortcuts) }
        if keys.contains(.controlBridge) { ControlBridge.shared.update(enabled: new.controlBridge) }
        if keys.contains(.developerTools) {
            // Remote inspection follows at once; the context-menu item needs a new page (its configuration).
            for tab in allTabs { tab.webView?.isInspectable = new.developerTools }
            for ext in extensionHosts.flatMap(\.loaded) { ext.context.isInspectable = new.developerTools }
            MainMenu.setDevelopMenu(visible: new.developerTools)
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
        if keys.contains(.appearance) { applyAppearance(new.appearance) }
        if keys.contains(.minimumFontSize) {
            // A tab's configuration copy shares the WKPreferences object, so this reaches pages already open.
            for tab in allTabs { tab.webView?.configuration.preferences.minimumFontSize = CGFloat(new.minimumFontSize) }
        }
        if !keys.isDisjoint(with: [.fraudWarnings, .tabKeyHighlightsLinks]) {
            // Shared WKPreferences, as minimumFontSize: pages already open follow.
            for tab in allTabs {
                tab.webView?.configuration.preferences.isFraudulentWebsiteWarningEnabled = new.fraudWarnings
                tab.webView?.configuration.preferences.tabFocusesLinks = new.tabKeyHighlightsLinks
            }
        }
        if !keys.isDisjoint(with: [.swipeNavigation, .pinchZoom]) {
            for tab in allTabs { tab.applyGestures() }
        }
        if keys.contains(.sites) || keys.contains(.defaultZoom) { applySiteZoom() }
        if keys.contains(.sites) || keys.contains(.darkMode) { applySiteDarkMode() }
        if keys.contains(.invertTextImages) { for tab in allTabs { tab.applyInvertTextImages() } }
        // Scriptlets come from the same list files, so they are rebuilt with the block lists.
        if !keys.isDisjoint(with: [.contentBlocking, .filterLists, .scriptlets, .trustedLists])
            || (keys.contains(.sites) && old.blockingOffHosts != new.blockingOffHosts) {
            await web.loadContentBlockers()
        }
        // A newly listed (or re-enabled) list has no file yet, so it is due now rather than at the hourly check.
        if !changed.isDisjoint(with: [.contentBlocking, .filterLists, .filterUpdateDays]) {
            Task { await updateFilterListsIfDue() }
        }
        // A changed `extensionCompat` entry reloads that extension (`reconcile` compares each one's reload key).
        if !keys.isDisjoint(with: [.extensions, .extensionsInPrivate, .extensionCompat]) { await extensions.reconcile(config: new) }
        // Other profiles take `extensions` from profiles.json, but `extensionCompat` applies to them too.
        if keys.contains(.extensionCompat) {
            for host in profileExtensionHosts.values { await host.reconcile(config: new) }
        }
        if !keys.isDisjoint(with: [.extensionsInPrivate, .extensionCompat]) {
            extensions.applyPrivateAccess(config: new)
            // No extension may run in private windows any more, so private windows already open drop extensions. An
            // extension newly allowed joins private windows that already carry extensions at once; others only when
            // opened afterwards.
            if !new.anyExtensionInPrivate {
                for controller in windows where controller.model.isPrivate && controller.model.extensionsAllowed {
                    extensions.windowClosing(controller)
                    controller.model.withdrawExtensions()
                }
            }
        }
        if !keys.isDisjoint(with: [.tabFreezeAfterMinutes, .tabSleepAfterMinutes, .maxAwakeTabs, .sleepPinnedTabs, .cpuSleepPercent, .keepPageWorkRunning, .keepNotifyingSitesLive]) {
            sweepSleepingTabs()
        }
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
            case .tabFreezeAfterMinutes: old.tabFreezeAfterMinutes != new.tabFreezeAfterMinutes
            case .tabSleepAfterMinutes: old.tabSleepAfterMinutes != new.tabSleepAfterMinutes
            case .maxAwakeTabs: old.maxAwakeTabs != new.maxAwakeTabs
            case .sleepPinnedTabs: old.sleepPinnedTabs != new.sleepPinnedTabs
            case .cpuSleepPercent: old.cpuSleepPercent != new.cpuSleepPercent
            case .keepPageWorkRunning: old.keepPageWorkRunning != new.keepPageWorkRunning
            case .keepNotifyingSitesLive: old.keepNotifyingSitesLive != new.keepNotifyingSitesLive
            case .sessionHistoryTabs: old.sessionHistoryTabs != new.sessionHistoryTabs
            case .linkPreview: old.linkPreview != new.linkPreview
            case .resumeMediaOnSelect: old.resumeMediaOnSelect != new.resumeMediaOnSelect
            case .speculativeLoading: old.speculativeLoading != new.speculativeLoading
            case .contentBlocking: old.contentBlocking != new.contentBlocking
            case .filterLists: old.filterLists != new.filterLists
            case .filterUpdateDays: old.filterUpdateDays != new.filterUpdateDays
            case .scriptlets: old.scriptlets != new.scriptlets
            case .trustedLists: old.trustedLists != new.trustedLists
            case .userAgentSuffix: old.userAgentSuffix != new.userAgentSuffix
            case .siteUserAgents: old.siteUserAgents != new.siteUserAgents
            case .sites: old.sites != new.sites
            case .showTabMemory: old.showTabMemory != new.showTabMemory
            case .showFullAddress: old.showFullAddress != new.showFullAddress
            case .tabLayout: old.tabLayout != new.tabLayout
            case .developerTools: old.developerTools != new.developerTools
            case .httpsOnly: old.httpsOnly != new.httpsOnly
            case .newTabFrequentSites: old.newTabFrequentSites != new.newTabFrequentSites
            case .askWhereToDownload: old.askWhereToDownload != new.askWhereToDownload
            case .downloadFolder: old.downloadFolder != new.downloadFolder
            case .underlineLinks: old.underlineLinks != new.underlineLinks
            case .alwaysShowTabCloseButtons: old.alwaysShowTabCloseButtons != new.alwaysShowTabCloseButtons
            case .showHomeButton: old.showHomeButton != new.showHomeButton
            case .alwaysShowDownloadsButton: old.alwaysShowDownloadsButton != new.alwaysShowDownloadsButton
            case .onLaunch: old.onLaunch != new.onLaunch
            case .newTabPosition: old.newTabPosition != new.newTabPosition
            case .openLinksInBackground: old.openLinksInBackground != new.openLinksInBackground
            case .afterClosingTab: old.afterClosingTab != new.afterClosingTab
            case .askBeforeQuitting: old.askBeforeQuitting != new.askBeforeQuitting
            case .askBeforeClosingWindow: old.askBeforeClosingWindow != new.askBeforeClosingWindow
            case .externalLinks: old.externalLinks != new.externalLinks
            case .fraudWarnings: old.fraudWarnings != new.fraudWarnings
            case .swipeNavigation: old.swipeNavigation != new.swipeNavigation
            case .pinchZoom: old.pinchZoom != new.pinchZoom
            case .tabKeyHighlightsLinks: old.tabKeyHighlightsLinks != new.tabKeyHighlightsLinks
            case .soundEffects: old.soundEffects != new.soundEffects
            case .contactAutofill: old.contactAutofill != new.contactAutofill
            case .newTabExtension: old.newTabExtension != new.newTabExtension
            case .newTabFeeds: old.newTabFeeds != new.newTabFeeds
            case .newTabNotifications: old.newTabNotifications != new.newTabNotifications
            case .newTabHiddenNotifications: old.newTabHiddenNotifications != new.newTabHiddenNotifications
            case .newTabSections: old.newTabSections != new.newTabSections
            case .mosaicMaxPanes: old.mosaicMaxPanes != new.mosaicMaxPanes
            case .mosaicPaneBars: old.mosaicPaneBars != new.mosaicPaneBars
            case .mosaicGap: old.mosaicGap != new.mosaicGap
            case .mosaicMinimumPaneWidth: old.mosaicMinimumPaneWidth != new.mosaicMinimumPaneWidth
            case .mosaicMinimumPaneHeight: old.mosaicMinimumPaneHeight != new.mosaicMinimumPaneHeight
            case .mosaicStaysReady: old.mosaicStaysReady != new.mosaicStaysReady
            case .mosaicFreezeAfterMinutes: old.mosaicFreezeAfterMinutes != new.mosaicFreezeAfterMinutes
            case .mosaicSleepAfterMinutes: old.mosaicSleepAfterMinutes != new.mosaicSleepAfterMinutes
            case .mosaicAnimation: old.mosaicAnimation != new.mosaicAnimation
            case .mosaicAnimationSpeed: old.mosaicAnimationSpeed != new.mosaicAnimationSpeed
            case .mosaicLiveDragPreview: old.mosaicLiveDragPreview != new.mosaicLiveDragPreview
            case .mosaicDividerGrips: old.mosaicDividerGrips != new.mosaicDividerGrips
            case .mosaicDividerSnapping: old.mosaicDividerSnapping != new.mosaicDividerSnapping
            case .mosaicDividerDoubleClick: old.mosaicDividerDoubleClick != new.mosaicDividerDoubleClick
            case .mosaicPaneCorners: old.mosaicPaneCorners != new.mosaicPaneCorners
            case .mosaicFocusMarker: old.mosaicFocusMarker != new.mosaicFocusMarker
            case .mosaicDimAmount: old.mosaicDimAmount != new.mosaicDimAmount
            case .mosaicToolbarSize: old.mosaicToolbarSize != new.mosaicToolbarSize
            case .mosaicToolbarButtons: old.mosaicToolbarButtons != new.mosaicToolbarButtons
            case .mosaicPaneGrab: old.mosaicPaneGrab != new.mosaicPaneGrab
            case .mosaicModifierDrag: old.mosaicModifierDrag != new.mosaicModifierDrag
            case .mosaicWindowDrag: old.mosaicWindowDrag != new.mosaicWindowDrag
            case .mosaicNewTab: old.mosaicNewTab != new.mosaicNewTab
            case .mosaicLinks: old.mosaicLinks != new.mosaicLinks
            case .mosaicNewPanePlacement: old.mosaicNewPanePlacement != new.mosaicNewPanePlacement
            case .mosaicDefaultLayout: old.mosaicDefaultLayout != new.mosaicDefaultLayout
            case .mosaicAutoArrange: old.mosaicAutoArrange != new.mosaicAutoArrange
            case .mosaicDarkMode: old.mosaicDarkMode != new.mosaicDarkMode
            case .mosaicZoom: old.mosaicZoom != new.mosaicZoom
            case .mosaicFocusFollowsPointer: old.mosaicFocusFollowsPointer != new.mosaicFocusFollowsPointer
            case .mosaicSound: old.mosaicSound != new.mosaicSound
            case .mosaicCloseKey: old.mosaicCloseKey != new.mosaicCloseKey
            case .mosaicStripIcon: old.mosaicStripIcon != new.mosaicStripIcon
            case .mosaicStripName: old.mosaicStripName != new.mosaicStripName
            case .mosaicStripShading: old.mosaicStripShading != new.mosaicStripShading
            case .mosaicStripColor: old.mosaicStripColor != new.mosaicStripColor
            case .mosaicStripStrength: old.mosaicStripStrength != new.mosaicStripStrength
            case .mosaicStripStyle: old.mosaicStripStyle != new.mosaicStripStyle
            case .appearance: old.appearance != new.appearance
            case .darkMode: old.darkMode != new.darkMode
            case .invertTextImages: old.invertTextImages != new.invertTextImages
            case .highContrastTabs: old.highContrastTabs != new.highContrastTabs
            case .theme: old.theme != new.theme
            case .accentColor: old.accentColor != new.accentColor
            case .chromeTint: old.chromeTint != new.chromeTint
            case .chromeTintStrength: old.chromeTintStrength != new.chromeTintStrength
            case .interfaceTextSize: old.interfaceTextSize != new.interfaceTextSize
            case .defaultZoom: old.defaultZoom != new.defaultZoom
            case .minimumFontSize: old.minimumFontSize != new.minimumFontSize
            case .reduceMotion: old.reduceMotion != new.reduceMotion
            case .reduceTransparency: old.reduceTransparency != new.reduceTransparency
            case .controlBridge: old.controlBridge != new.controlBridge
            case .controlBridgeScripts: old.controlBridgeScripts != new.controlBridgeScripts
            case .shortcuts: old.shortcuts != new.shortcuts
            case .extensions: old.extensions != new.extensions
            case .extensionToolbar: old.extensionToolbar != new.extensionToolbar
            case .extensionsInPrivate: old.extensionsInPrivate != new.extensionsInPrivate
            case .extensionCompat: old.extensionCompat != new.extensionCompat
            case .extensionUpdates: old.extensionUpdates != new.extensionUpdates
            case .sitePersonas: old.sitePersonas != new.sitePersonas
            }
        })
    }

    // MARK: - Sites

    /// Whether `profile`'s own settings set `field` for the `sites` key `key`.
    func profileSetsSiteField(_ field: SiteSettings.Field, forKey key: String, profile: ProfileID) -> Bool {
        guard case .object(let sites)? = profiles.profile(id: profile).settings[ProfileOverrides.sitesKey] else { return false }
        return sites[key]?.objectValue?[field.rawValue] != nil
    }

    /// A site setting changed from a window of `profile` (the site popover, Allow Pop-ups): into the profile's own
    /// settings when it already sets that field for the site, else into config.json as `writeSiteSetting`.
    @discardableResult
    func writeSiteSetting(_ field: SiteSettings.Field, _ value: JSONValue?, forKey key: String, profile: ProfileID) async -> Bool {
        if profileSetsSiteField(field, forKey: key, profile: profile) {
            return profiles.setOverride([ProfileOverrides.sitesKey, key, field.rawValue], to: value, for: profile)
        }
        if case .written = await writeSiteSetting(field, value, forKey: key) { return true }
        return false
    }

    /// Sets one field of `sites.<key>` in config.json through `writeConfig`, starting from the entry as it is on
    /// disk now (other members, unknown ones included, stay). A value equal to Paddle's default removes the field,
    /// and an entry left empty is removed. `key` is a `sites` key as written in the file, or a new host.
    @discardableResult
    func writeSiteSetting(_ field: SiteSettings.Field, _ value: JSONValue?, forKey key: String) async -> ConfigWriteResult {
        let disk: Data
        let existing: JSONValue?
        do {
            disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
            let blank = disk.drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }.isEmpty
            existing = blank ? nil : try JSONSpans.scan(disk).object["sites"]?.objectValue?[key]
        } catch {
            return .failed(error.localizedDescription)
        }
        let result = await writeConfig([ConfigChange("sites", key, SiteSettings.entry(existing, setting: field, to: value))], base: disk)
        switch result {
        case .written: break
        case .conflict(let paths):
            log.error("sites.\(key, privacy: .private).\(field.rawValue, privacy: .public) not written: changed on disk (\(paths.count) paths)")
        case .failed(let reason):
            log.error("sites.\(key, privacy: .private).\(field.rawValue, privacy: .public) not written: \(reason, privacy: .public)")
        }
        return result
    }

    /// Sets where one extension's toolbar button goes (`extensionToolbar.<folder>`), starting from the file as it is on
    /// disk now. `pinned` is the default, so it removes the entry.
    func setToolbarPlacement(_ placement: ExtensionToolbarPlacement, folder: String) async {
        await setToolbarPlacement(placement, folders: [folder])
    }

    /// Several extensions' `extensionToolbar` placement in one write (the toolbar's Hide All Pinned / Pin All).
    func setToolbarPlacement(_ placement: ExtensionToolbarPlacement, folders: [String]) async {
        guard !folders.isEmpty else { return }
        let folder = folders.joined(separator: ",")
        let disk: Data
        do {
            disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
        } catch {
            log.error("extensionToolbar.\(folder, privacy: .private) not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        let changes = folders.map { ConfigChange("extensionToolbar", $0, placement == .pinned ? nil : .string(placement.rawValue)) }
        let result = await writeConfig(changes, base: disk)
        switch result {
        case .written: break
        case .conflict(let paths):
            log.error("extensionToolbar.\(folder, privacy: .private) not written: changed on disk (\(paths.count) paths)")
        case .failed(let reason):
            log.error("extensionToolbar.\(folder, privacy: .private) not written: \(reason, privacy: .public)")
        }
    }

    /// Sets `tabLayout` through `writeConfig`, the way Settings does (a value equal to the default removes the key).
    func setTabLayout(_ layout: TabLayout) async {
        let disk: Data
        do {
            disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
        } catch {
            log.error("tabLayout not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch await writeConfig([ConfigChange("tabLayout", .string(layout.rawValue))], base: disk) {
        case .written: break
        case .conflict(let paths): log.error("tabLayout not written: changed on disk (\(paths.count) paths)")
        case .failed(let reason): log.error("tabLayout not written: \(reason, privacy: .public)")
        }
    }

    /// Writes Mosaic settings through `writeConfig` (the Mosaic bar's menu), the way Settings does.
    func setMosaicConfig(_ changes: [ConfigChange]) async {
        let disk: Data
        do {
            disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
        } catch {
            log.error("Mosaic settings not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch await writeConfig(changes, base: disk) {
        case .written: break
        case .conflict(let paths): log.error("Mosaic settings not written: changed on disk (\(paths.count) paths)")
        case .failed(let reason): log.error("Mosaic settings not written: \(reason, privacy: .public)")
        }
    }

    /// `mosaicMaxPanes`, dropping the old `multiViewMaxPanes`.
    func setMosaicMaxPanes(_ count: Int) async {
        await setMosaicConfig([ConfigChange("mosaicMaxPanes", .number(Double(count))), ConfigChange("multiViewMaxPanes", nil)])
    }

    /// The zoom a page on `host` opens at: `sites` in ordinary windows; in private ones what was set there this
    /// run, falling back to `sites`.
    func siteZoom(forHost host: String, isPrivate: Bool, profile: ProfileID = ProfileStore.defaultID) -> Double {
        if isPrivate, let zoom = privateZooms[config.zoomKey(forHost: host)] { return zoom }
        let config = config(for: profile)
        return pendingZooms[config.zoomKey(forHost: host)] ?? config.sitePolicy(forHost: host).zoom
    }

    /// Zoom values not yet in config.json, so a page committing meanwhile opens at the new zoom.
    @ObservationIgnored private var pendingZooms: [String: Double] = [:]

    /// Remembers a zoom set with Zoom In / Zoom Out / Actual Size on `host`: in a private window for this run only,
    /// else in `sites.<key>.zoom` (`PaddleConfig.zoomKey`), written once the keys stop for a second so a run of
    /// steps is one write. Other tabs on the site follow when config.json is applied.
    func rememberZoom(_ zoom: Double, forHost host: String, isPrivate: Bool, profile: ProfileID = ProfileStore.defaultID) {
        let key = config.zoomKey(forHost: host)
        let zoom = SitePolicy.normalizedZoom(zoom)
        if isPrivate {
            privateZooms[key] = zoom
            return
        }
        // A profile that sets its own zoom for the site keeps it in its settings, not in config.json; same one-second
        // wait, so a run of steps is one profiles.json write.
        let profileKey = config(for: profile).zoomKey(forHost: host)
        let ownedByProfile = profileSetsSiteField(.zoom, forKey: profileKey, profile: profile)
        pendingZooms[key] = zoom
        pendingZoomWrites[key]?.cancel()
        pendingZoomWrites[key] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            pendingZoomWrites[key] = nil
            if ownedByProfile {
                if !profiles.setOverride([ProfileOverrides.sitesKey, profileKey, "zoom"], to: .number(zoom), for: profile) {
                    log.error("zoom not remembered: profiles.json can't be written")
                }
                if pendingZoomWrites[key] == nil { pendingZooms[key] = nil }
                return
            }
            // The default zoom needs no entry: remove the site's own, if any. Another zoom is written unless already there.
            if zoom == config.defaultZoom {
                if config.sites[key]?.zoom != nil { await writeSiteSetting(.zoom, nil, forKey: key) }
            } else if config.sites[key]?.zoom != zoom {
                await writeSiteSetting(.zoom, .number(zoom), forKey: key)
            }
            if pendingZoomWrites[key] == nil { pendingZooms[key] = nil }
        }
    }

    /// `sites` changed: awake ordinary tabs take their site's zoom now (other per-site settings apply at the next
    /// page load). Tabs whose site has a zoom write still pending keep theirs.
    private func applySiteZoom() {
        for tab in allTabs {
            if let host = tab.webView?.url?.host(), pendingZoomWrites[config.zoomKey(forHost: host)] != nil { continue }
            tab.applySiteZoom()
        }
    }

    /// Awake tabs update their dark mode state when global or per-site dark mode changes.
    func applySiteDarkMode() {
        let isDark = effectiveAppearanceIsDark
        for tab in allTabs {
            tab.applySiteDarkMode(systemIsDark: isDark)
        }
    }

    /// Writes `invertTextImages` in config.json.
    func toggleInvertTextImages() async {
        let disk: Data
        do {
            disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
        } catch {
            return
        }
        let next = !config.invertTextImages
        _ = await writeConfig([ConfigChange("invertTextImages", .bool(next))], base: disk)
    }

    /// Settings' "This session: Forget": the next camera, microphone, location or download request from `host`
    /// asks again.
    func forgetSessionAnswers(forHost host: String, profile: ProfileID) {
        sessionPermissions[profile]?.forget(host: host)
    }

    /// Paddle > Reload Config: re-reads config.json, user.css, userscripts/, block lists, extension folders and
    /// bookmarks. A config.json that doesn't parse keeps the previous settings; everything else is still re-read.
    /// Only that error stops you with an alert. A reload that worked is announced and logged, and a file with values
    /// of the wrong type says how many (`configWarnings`) in the announcement rather than alerting. Its status stays
    /// in the Activity popover and the Extensions menu, so it never waits for a click. Settings' Apply Now runs the
    /// same path without the announcement.
    func reloadConfig(showAlert: Bool = true) async {
        // Themes first: applying every key can take seconds (block lists), and meanwhile the notice would call a
        // newly added theme file missing.
        themes.load()
        await apply(readConfig() ?? config, reloading: true)
        bookmarks.load()
        newTab.load()
        profiles.load()
        profilesReloaded()
        await profileConfigsChanged(rebuildProfileConfigs(), reloading: true)
        // A hand edit of a profile's `extensions` in profiles.json.
        for host in profileExtensionHosts.values { await host.reconcile(config: config) }
        guard showAlert else { return }

        guard let configError else {
            if configWarnings.isEmpty {
                log.info("config reloaded")
                AccessibilityNotification.Announcement("Config reloaded").post()
            } else {
                log.info("config reloaded with \(self.configWarnings.count) wrong-typed values")
                AccessibilityNotification.Announcement(
                    "Config reloaded. \(configWarningPhrase) (Settings > Advanced > Problems)."
                ).post()
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "config.json has an error"
        alert.informativeText = "\(configError)\n\nPaddle kept the previous settings. User CSS, scripts and filters were reloaded."
        alert.runModal()
    }

    /// Extensions > Reload Extensions: unloads every extension and loads the folder again, edited files included.
    /// No alert: an extension that fails shows in the window's banner and the Extensions menu's status lines.
    func reloadExtensions() async {
        for host in extensionHosts { await host.reloadAll(config: config) }
        log.info("extensions reloaded: \(self.extensions.statusLines.joined(separator: " | "), privacy: .public)")
        AccessibilityNotification.Announcement("Extensions reloaded").post()
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

    /// History is being recorded in some profile: historyDays (config.json's, or a profile's own) is above 0.
    var historyEnabled: Bool { historyEnabled(for: ProfileStore.defaultID) || profileConfigs.values.contains { $0.historyDays > 0 } }

    /// `profile` records history: its historyDays is above 0.
    func historyEnabled(for profile: ProfileID) -> Bool { config(for: profile).historyDays > 0 }

    /// Where a profile's history database is.
    func historyPath(for profile: ProfileID) -> URL {
        profile == ProfileStore.defaultID ? Paths.history : Paths.profileHistory(profile)
    }

    /// A profile's history, opened on first use and pruned to `historyDays` as it opens. Nil when historyDays is 0
    /// or the database can't be opened.
    func history(for profile: ProfileID) -> HistoryStore? {
        // A stale id (a profile removed from profiles.json) never creates profiles/<id>/history.sqlite again.
        guard historyEnabled(for: profile), profile == ProfileStore.defaultID || profiles.contains(profile) else { return nil }
        if let store = histories[profile] { return store }
        do {
            let url = historyPath(for: profile)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = try HistoryStore(path: url.path)
            histories[profile] = store
            prune(store, profile: profile)
            return store
        } catch {
            log.error("history unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drops a profile's open history database (the profile was deleted, or its file is about to be).
    func forgetHistoryStore(profile: ProfileID) {
        histories[profile] = nil
        newTab.forgetFrequentSites(profile: profile)
    }

    /// At launch and when historyDays changes: with historyDays 0 nothing is recorded (the files are left as they
    /// are; Clear History still empties them); else the default profile's history opens and every open one is pruned.
    private func openHistory() {
        defer { historyGeneration += 1 }
        for profile in histories.keys where !historyEnabled(for: profile) {
            histories[profile] = nil
            newTab.forgetFrequentSites(profile: profile)
        }
        if !historyEnabled { newTab.forgetFrequentSites() }
        _ = history(for: ProfileStore.defaultID)
        pruneHistory()
    }

    @ObservationIgnored private var lastHistoryPrune = Date.distantPast

    /// Retention: drops visits older than `historyDays` from every open history. Runs at launch, on Reload Config
    /// and daily from the sweep timer.
    private func pruneHistory() {
        lastHistoryPrune = Date()
        for (profile, store) in histories { prune(store, profile: profile) }
    }

    private func prune(_ history: HistoryStore, profile: ProfileID) {
        do {
            try history.prune(olderThan: Date().addingTimeInterval(-Double(config(for: profile).historyDays) * 86_400))
        } catch {
            log.error("history prune failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordVisit(_ url: URL, title: String, typed: Bool, profile: ProfileID) {
        guard HistoryStore.isRecordable(url), let history = history(for: profile) else { return }
        do {
            try history.recordVisit(url: url, title: title, typed: typed, at: Date())
            historyGeneration += 1
        } catch {
            log.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// File > Import from Browser…: adds another browser's visits with their original dates, skipping those already
    /// here and those older than `historyDays`. Nil when history is off. Runs in batches with a yield between, so
    /// a large history doesn't freeze the windows; the first batch that fails stops it (the earlier ones stay, and a
    /// second import skips them).
    func importHistory(_ visits: [ImportedVisit], profile: ProfileID) async throws -> HistoryImportSummary? {
        guard let history = history(for: profile) else { return nil }
        defer { historyGeneration += 1 }
        let cutoff = Date().addingTimeInterval(-Double(config(for: profile).historyDays) * 86_400)
        var total = HistoryImportSummary()
        for start in stride(from: 0, to: visits.count, by: 20_000) {
            total.add(try history.importVisits(Array(visits[start..<min(start + 20_000, visits.count)]), notBefore: cutoff))
            await Task.yield()
        }
        return total
    }

    func updateHistoryTitle(_ url: URL, _ title: String, profile: ProfileID) {
        guard !title.isEmpty, HistoryStore.isRecordable(url), let history = history(for: profile) else { return }
        try? history.updateTitle(url: url, title: title)
        historyGeneration += 1
    }

    func removeFromHistory(_ url: String, profile: ProfileID) {
        guard let history = history(for: profile) else { return }
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
    /// Only `profile`'s history and recently closed tabs; other profiles keep theirs.
    func clearHistory(since date: Date?, profile: ProfileID) {
        defer { historyGeneration += 1 }
        // The New Tab page's Frequently visited row must not show what was just cleared, even for a moment.
        newTab.forgetFrequentSites(profile: profile)
        windows.filter { $0.model.profileID == profile }.forEach { $0.model.forgetClosedTabs() }
        saveSessionNow()
        favicons.forget(since: date, keeping: bookmarks.siteKeys)
        do {
            let path = historyPath(for: profile).path
            if let history = history(for: profile) {
                if let date { try history.removeVisits(since: date) } else { try history.removeAll() }
            } else if FileManager.default.fileExists(atPath: path) {
                if let date {
                    try HistoryStore(path: path).removeVisits(since: date)
                } else {
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(atPath: path + suffix)
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

    /// Moves `tab` to `index` in `target` (`tabs.move`, `windows.create` with tab ids), keeping its web view and
    /// history. Within one window it is `place`. Extensions see it detach and attach; the window it left closes
    /// once empty, as in Chrome.
    func move(_ tab: Tab, to target: BrowserWindowController, at index: Int, select: Bool = false) {
        guard let source = tab.browser else { return }
        if source === target.model {
            source.place(tab, at: index)
            if select { source.select(tab) }
            return
        }
        guard target.model.canAccept(tab) else {
            log.info("tab move refused: different profile or privacy")
            return
        }
        guard let from = source.detach(tab) else { return }
        target.model.adopt(tab, at: index)
        target.model.extensionHost?.tabMoved(tab, from: from, in: source.controller)
        if select || target.model.selectedID == nil { target.model.select(tab) }
        if source.allTabs.isEmpty { source.controller?.close() }
        sessionChanged()
    }

    /// `isPrivate`: File > New Private Window. Private windows are never restored, so they never have a `record`.
    /// Extensions are told about a window only when they may see it: a private window carries them when any extension
    /// may run in private windows (`anyExtensionInPrivate`), decided here, when it opens.
    /// `moving`: tabs taken from other windows to fill it (`windows.create` with tab ids), instead of a new tab.
    @discardableResult
    func openWindow(
        record: WindowRecord? = nil, url: URL? = nil, isPrivate: Bool = false, profile: ProfileID = ProfileStore.defaultID,
        moving: [Tab] = []
    ) -> BrowserWindowController {
        // Tabs being moved keep their window's profile; an unknown profile is the default one. Private windows ignore it.
        let wanted = moving.first.map { $0.profileID } ?? profile
        let controller = BrowserWindowController(
            record: isPrivate ? nil : record, isPrivate: isPrivate, extensionsAllowed: !isPrivate || config.anyExtensionInPrivate,
            profile: profiles.contains(wanted) ? wanted : ProfileStore.defaultID
        )
        windows.append(controller)
        if controller.model.extensionsAllowed { extensions(for: controller.model.profileID)?.windowOpened(controller) }
        if record == nil {
            let movable = moving.filter { controller.model.canAccept($0) }
            if !movable.isEmpty {
                for (index, tab) in movable.enumerated() { move(tab, to: controller, at: index) }
            } else if let url {
                controller.model.newTab(url: url)
            } else {
                let home = URL(string: controller.model.config.homepage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
                controller.model.newTab(url: home)
                if home == nil { controller.model.focusAddress() }
            }
        }
        controller.showWindow(nil)
        return controller
    }

    /// Closes every window of a profile (it is being deleted); their tabs go to sleep, which drops the web views.
    func closeWindows(inProfile profile: ProfileID) {
        for controller in windows where controller.model.profileID == profile && !controller.model.isPrivate {
            controller.close()
        }
    }

    func windowClosed(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        updateSampler()
        if controller.model.isPrivate, !windows.contains(where: { $0.model.isPrivate }) {
            // The private session ends: a new private window starts with an empty data store.
            web.endPrivateSession()
            downloads.forgetPrivate()
            privateZooms.removeAll()
            privatePermissions = SessionPermissions()
            log.info("last private window closed: private data store released")
        }
        // At once rather than debounced: a closed window is a change worth having on disk right away.
        saveSessionNow()
    }

    /// The browser window the user was last in, even when another kind of window (History) is in front.
    var frontWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
            ?? windows.last
    }

    /// The front window the extension `context` may see and open things in: the front browser window when the
    /// extension host shows it to `context`, else the frontmost one it does. Private windows `context` isn't allowed
    /// in are skipped (`ExtensionHost.isVisible`); a nil context sees every window the host carries.
    /// The extension's own profile decides: another profile's windows are never visible to it.
    func frontExtensionWindow(for context: WKWebExtensionContext?) -> BrowserWindowController? {
        guard let host = context.map(extensionHost(owning:)) ?? frontExtensions else { return nil }
        if let front = frontWindow, host.isVisible(front, to: context) { return front }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first { host.isVisible($0, to: context) }
            ?? windows.last { host.isVisible($0, to: context) }
    }

    /// The browser window the user is in is one the extension `context` can't see: a private window it isn't allowed
    /// in. Its actions and commands started from the menu then do nothing rather than act on a window behind it.
    func frontWindowIsHidden(from context: WKWebExtensionContext?) -> Bool {
        guard let front = frontWindow else { return false }
        guard let host = context.map(extensionHost(owning:)) ?? frontExtensions else { return true }
        return !host.isVisible(front, to: context)
    }

    /// Opens Settings as a tab (Paddle > Settings…, ⌘,, typed settings addresses). Reuses a Settings tab
    /// in a window of the front window's profile (normal first, front preferred); else the front window
    /// opens one after its selected tab. Same profile only: Extensions, Sites and session answers are
    /// per-profile. `pane` nil opens the last pane.
    func showSettings(pane: SettingsPane? = nil) {
        let chosen = pane ?? SettingsPane.remembered
        SettingsPane.remembered = chosen
        let profile = frontWindow?.model.profileID ?? ProfileStore.defaultID
        let candidates = ([frontWindow].compactMap { $0 } + windows).filter { $0.model.profileID == profile }
        let withSettings = candidates.filter { $0.model.allTabs.contains { $0.settingsPane != nil } }
        guard let window = withSettings.first(where: { !$0.model.isPrivate }) ?? withSettings.first ?? frontWindow else {
            openWindow(url: chosen.url)
            return
        }
        window.model.showSettings(pane: chosen)
        window.window?.makeKeyAndOrderFront(nil)
    }

    /// The front normal (non-private) window, for links from other apps.
    var frontNormalWindow: BrowserWindowController? {
        if let front = frontWindow, !front.model.isPrivate { return front }
        return NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first { !$0.model.isPrivate }
            ?? windows.last { !$0.model.isPrivate }
    }

    /// Links from other apps open in a normal window, never a private one, as in Safari and Chrome.
    /// `externalLinks` picks a new tab of the front window, a new window (the other links of the same batch become
    /// its tabs) or the front window's selected tab (the first link; the rest become tabs).
    func open(_ urls: [URL]) {
        var target = config.externalLinks == .newWindow ? nil : frontNormalWindow
        var replaceSelected = config.externalLinks == .currentTab
        for url in urls {
            guard let front = target else {
                target = openWindow(url: url)
                replaceSelected = false
                continue
            }
            if replaceSelected, let tab = front.model.selectedTab {
                tab.load(url)
            } else {
                front.model.newTab(url: url)
            }
            replaceSelected = false
            front.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Every tab of every window, hidden spaces included.
    var allTabs: [Tab] { windows.flatMap { $0.model.allTabs } }

    /// `newTabPage` from config.json; nil for about:blank (an empty tab).
    var newTabPageURL: URL? { newTabPageURL(for: ProfileStore.defaultID) }

    /// `profile`'s `newTabPage`; nil for about:blank.
    func newTabPageURL(for profile: ProfileID) -> URL? {
        URL(string: config(for: profile).newTabPage).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
    }

    // MARK: - Session

    /// Saved windows whose profile restoreSession couldn't check because profiles.json was unreadable. Written back
    /// by every save, and opened once Reload Config reads the file (`profilesReloaded`).
    @ObservationIgnored private var heldWindowRecords: [WindowRecord] = []

    /// After Reload Config re-reads profiles.json: windows held at launch open if their profile is listed (and are
    /// dropped if it isn't), and windows of a profile no longer listed close, with its extension host and history
    /// database, so nothing keeps using its data under another profile's name. Its files stay on disk.
    private func profilesReloaded() {
        guard profiles.loadError == nil else { return }
        let held = heldWindowRecords
        heldWindowRecords = []
        for record in held {
            let profile = record.profile ?? ProfileStore.defaultID
            if profiles.contains(profile) {
                openWindow(record: record, profile: profile)
            } else {
                log.error("session window dropped: its profile no longer exists")
            }
        }
        let removed = Set(windows.filter { !$0.model.isPrivate && !profiles.contains($0.model.profileID) }.map(\.model.profileID))
            .union(profileExtensionHosts.keys.filter { !profiles.contains($0) })
        for profile in removed {
            log.notice("a profile was removed from profiles.json: its windows close")
            closeWindows(inProfile: profile)
            dropExtensions(profile: profile)
            forgetHistoryStore(profile: profile)
            sessionPermissions[profile] = nil
        }
        if !held.isEmpty { sessionChanged() }
    }

    private func restoreSession() {
        defer { didRestore = true }
        // `onLaunch` newWindow: the saved session is replaced by this launch's windows at the first save.
        guard config.onLaunch == .restore else {
            log.info("startup: onLaunch is newWindow, the saved session is not restored")
            return
        }
        guard let session = sessionStore.load() else {
            if FileManager.default.fileExists(atPath: sessionStore.badFile.path) {
                log.error("session.json.bad is there: a saved session that didn't decode, kept with its tab histories")
            }
            return
        }
        do {
            isRestoring = true
            defer { isRestoring = false }
            for record in session.windows where !record.allTabRecords.isEmpty {
                let profile = record.profile ?? ProfileStore.defaultID
                guard profiles.contains(profile) else {
                    if profiles.loadError != nil {
                        // profiles.json can't be read, so the profile may well exist: keep the window as it was
                        // saved, unopened (never in another profile's data store), until the file is fixed.
                        log.error("session window kept unopened: profiles.json can't be read")
                        heldWindowRecords.append(record)
                    } else {
                        log.error("session window dropped: its profile no longer exists")
                    }
                    continue
                }
                openWindow(record: record, profile: profile)
            }
        }
        // A session.json from before sessions/ existed is rewritten in the new form by the next save.
        sessionChanged()
    }

    /// Debounced save; called on every tab change. Runs `SessionSaveTiming.debounce` after the latest change, and
    /// no later than `maxLatency` after the first unsaved one, so steady tab switching can't put it off.
    func sessionChanged() {
        guard !isRestoring else { return }
        let now = Date()
        let first = unsavedSince ?? now
        unsavedSince = first
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSessionNow() }
        }
        saveWork = work
        let delay = SessionSaveTiming.deadline(lastChange: now, firstUnsaved: first).timeIntervalSince(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: work)
    }

    /// Writes only what changed (`SessionStore.save`): back/forward states whose bytes changed, and session.json
    /// unless its bytes are the same. History is kept for the `sessionHistoryTabs` most recent tabs plus pinned ones.
    func saveSessionNow() {
        saveWork?.cancel()
        saveWork = nil
        unsavedSince = nil
        guard didRestore, !isTerminating else { return }
        var session = SessionRecord.saving(windows, isPrivate: \.model.isPrivate, record: \.model.record)
            .cappingStates(to: config.sessionHistoryTabs)
        // Windows of profiles Paddle couldn't read at launch are written back unchanged.
        session.windows += heldWindowRecords
        do {
            let result = try sessionStore.save(session)
            if result.wroteSession || !result.statesWritten.isEmpty || !result.statesDeleted.isEmpty {
                log.debug("session saved: json \(result.wroteSession), \(result.statesWritten.count) states written, \(result.statesDeleted.count) deleted")
            }
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
        // Low Power Mode and thermal changes: the sleep policy tightens at once rather than at the next sweep.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.updatePower() }
            })
        }
        updatePower()
        // Nothing here opts out of App Nap, so macOS naps Paddle (and this timer) while its windows are hidden.
        let sweep = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let app = AppModel.shared
                app.sweepSleepingTabs()
                if Date().timeIntervalSince(app.lastHistoryPrune) > 86_400 { app.pruneHistory() }
                if Date().timeIntervalSince(app.lastFilterCheck) > 3_600 { Task { await app.updateFilterListsIfDue() } }
                Task { await ExtensionUpdater.shared.checkIfDue(config: app.config) }
            }
        }
        // Nothing in the sweep needs to-the-second timing; tolerance lets macOS batch its wakeup with others.
        sweep.tolerance = 10
        sweepTimer = sweep

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppModel.shared.log.info("memory pressure: sleeping background tabs and trimming WebKit memory")
                AppModel.shared.lastMemoryPressure = Date()
                AppModel.shared.sweepSleepingTabs(memoryPressure: true)
                AppModel.shared.trimWebKitMemory()
                // Hands free malloc pages back to the system (vmmap, 2026-10-16: the default zone held ~24 MB unused).
                malloc_zone_pressure_relief(nil, 0)
            }
        }
        source.resume()
        memoryPressureSource = source
        sampleMemory()
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
        for host in extensionHosts {
            for ext in host.loaded {
                if let background = host.backgroundWebView(of: ext) { owners[ObjectIdentifier(background)] = .extensionView }
            }
        }

        // Helpers outside WebKit's list (AutoFill, audio): a fresh process scan whenever a readout is open.
        let helpers = ProcessMemory.responsibleFootprints(rescan: memoryReaders > 0)
        let breakdown: ProcessBreakdown
        if let snapshot = ProcessMemory.snapshot() {
            // Popups (and anything else the host didn't hand us) are extension views by their URL scheme.
            for (id, view) in snapshot.webViews where owners[id] == nil && ExtensionIdentity.schemes.contains(view.url?.scheme?.lowercased() ?? "") {
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

    /// Configured tab sleep policy, tightened while Low Power Mode or heat constrains power (`TabSleepPolicy.adjusted(for:)`).
    var effectiveSleepPolicy: TabSleepPolicy { TabSleepPolicy(config: config).adjusted(for: power) }

    /// The sleep policy for a profile's tabs: its own timers (`profileConfigs`), tightened the same way.
    func sleepPolicy(for profile: ProfileID) -> TabSleepPolicy { TabSleepPolicy(config: config(for: profile)).adjusted(for: power) }

    /// Re-reads Low Power Mode and the thermal state; when power becomes constrained, sweeps at once.
    func updatePower() {
        let now = Self.readPowerConditions()
        guard now != power else { return }
        let wasConstrained = power.isConstrained
        power = now
        if let reason = now.reason {
            let policy = effectiveSleepPolicy
            log.info("power constrained by \(reason, privacy: .public): tabs sleep after \(Int(policy.sleepAfter / 60), privacy: .public) min idle, at most \(policy.maxAwakeTabs, privacy: .public) awake (0 = off)")
            sweepSleepingTabs()
            trimWebKitMemory()
        } else if wasConstrained {
            log.info("power back to normal: the configured sleep settings apply")
        }
    }

    private static func readPowerConditions() -> PowerConditions {
        #if DEBUG
        // Debug builds only: `-PaddleSimulatePower lowPower|serious|critical` on the command line exercises this path
        // without changing the Mac's settings.
        switch UserDefaults.standard.string(forKey: "PaddleSimulatePower") {
        case "lowPower": return PowerConditions(lowPowerMode: true)
        case "serious": return PowerConditions(thermal: .serious)
        case "critical": return PowerConditions(thermal: .critical)
        default: break
        }
        #endif
        let info = ProcessInfo.processInfo
        let thermal: PowerConditions.Thermal = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        return PowerConditions(lowPowerMode: info.isLowPowerModeEnabled, thermal: thermal)
    }

    /// Whether `tab`'s site should keep running in the background: its `sites` entry says `freeze: never`, or it is
    /// `auto` and the site may show notifications while `keepNotifyingSitesLive` is on. Private windows never show
    /// notifications, so there only `never` counts.
    func staysLive(_ tab: Tab) -> Bool {
        guard let url = tab.url, let host = url.host(), url.scheme == "https" || url.scheme == "http" else { return false }
        let config = config(for: tab.profileID)
        switch config.sitePolicy(forHost: host).freeze {
        case .never: return true
        case .always: return false
        case .auto: return config.keepNotifyingSitesLive && !tab.isPrivate && WebsiteNotifications.shared.isAllowed(url)
        }
    }

    /// Applies the sleep policy across all windows. Visible tabs, pinned tabs (by default),
    /// and tabs playing media or using the camera/mic stay awake.
    func sweepSleepingTabs(memoryPressure: Bool = false) {
        stopOrphanServiceWorkers(now: Date())
        let policy = effectiveSleepPolicy
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
            // Both sides of a split view are on screen, so both count as selected.
            let selected = Set(windows.flatMap { $0.model.visibleTabs.map(\.id) })
            let tabs = allTabs
            // A tab is sampled only when it could be judged: not selected, not playing, and not sharing its process with
            // another tab, whose CPU time would be counted twice. Any sweep that doesn't sample drops every clock, so the
            // next sample doesn't average over a gap and start one too early.
            // Each profile's tabs follow its own timers and CPU limit; the awake-tab cap spans every window.
            let policies = Dictionary(Set(tabs.map(\.profileID)).map { ($0, sleepPolicy(for: $0)) }, uniquingKeysWith: { a, _ in a })
            let limits = policies.mapValues { $0.cpuPercent / 100 }
            let limit = policy.cpuPercent / 100
            let sampling = limits.values.contains { $0 > 0 } && !memoryPressure
            var shares: [UUID: Double] = [:]
            if sampling {
                let awake = tabs.filter(\.isAwake)
                var pids: [UUID: pid_t] = [:]
                for tab in awake {
                    if let view = tab.webView, let pid = ProcessMemory.pid(of: view) { pids[tab.id] = pid }
                }
                var tabsPerProcess: [pid_t: Int] = [:]
                for pid in pids.values { tabsPerProcess[pid, default: 0] += 1 }
                for tab in awake {
                    guard let pid = pids[tab.id] else { continue }
                    if selected.contains(tab.id) || busy.contains(tab.id) || tabsPerProcess[pid, default: 0] > 1 {
                        cpuUsage.reset(tab.id)
                    } else if let share = cpuUsage.record(
                        tab.id, pid: pid, cpuSeconds: ProcessMemory.cpuSeconds(of: pid), at: now, limit: limits[tab.profileID] ?? limit
                    ) {
                        shares[tab.id] = share
                    }
                }
            }
            cpuUsage.retain(sampling ? Set(tabs.filter(\.isAwake).map(\.id)) : [])
            let snapshots = tabs.map { tab in
                let pageWork = config(for: tab.profileID).keepPageWorkRunning
                let uploading = pageWork && tab.isUploading
                // The idle clock starts when playback, capture, an upload or the popup ends, not when the tab was last viewed.
                if busy.contains(tab.id) || uploading { tab.lastActive = now }
                return TabSnapshot(
                    id: tab.id, lastActive: tab.lastActive, isAwake: tab.isAwake,
                    isSelected: selected.contains(tab.id), isPinned: tab.isPinned, isBusy: busy.contains(tab.id),
                    // Not before the tab was last shown: viewing it between two sweeps restarts its clock too.
                    cpuBusySince: sampling ? cpuUsage.busySince(tab.id).map { max($0, tab.lastActive) } : nil,
                    isFrozen: tab.isFrozen,
                    // A shared process stays up after this tab sleeps, so it doesn't count as memory this sleep frees.
                    footprint: tab.sharesProcess ? 0 : (tab.memoryBytes ?? 0),
                    isUploading: uploading, guardsUnload: pageWork && tab.guardsUnload, staysLive: staysLive(tab),
                    mosaic: tab.browser?.mosaicID(of: tab)
                )
            }
            let kept = [
                (snapshots.filter(\.isUploading).count, "uploading"), (snapshots.filter(\.guardsUnload).count, "unsaved changes"),
                (snapshots.filter { $0.isAwake && $0.staysLive }.count, "live site"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            if kept != lastKeptRunning {
                lastKeptRunning = kept
                log.info("kept running: \(kept.isEmpty ? "none" : kept, privacy: .public)")
            }
            // Freezing is the first stage: an idle tab keeps its page, stopped, before any sleep. Freezing is skipped
            // under memory pressure, where the sweep discards. It runs even when nothing sleeps this time.
            let profileOf = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.profileID) })
            let groups = Dictionary(grouping: snapshots) { profileOf[$0.id] ?? ProfileStore.defaultID }
                .map { (policy: policies[$0.key] ?? policy, tabs: $0.value) }
            let decided = policy.decide(groups, now: now, memoryPressure: memoryPressure)
            let ids = Set(decided.sleep)
            let freezeIDs = decided.freeze
            if !freezeIDs.isEmpty {
                let freezing = Set(freezeIDs)
                var froze = 0
                for tab in tabs where freezing.contains(tab.id) {
                    if tab.freeze() { froze += 1 }
                    // A frozen page uses no CPU, so its busy clock must not straddle the freeze.
                    cpuUsage.reset(tab.id)
                }
                if froze > 0 { log.info("froze \(froze) tab(s)") }
            }
            guard !ids.isEmpty else { return }
            // Tabs the CPU rule chose, worked out before any of them sleeps: they had been busy for the sustain period.
            let cpuSlept = Set(snapshots.filter { snapshot in
                guard ids.contains(snapshot.id), let since = snapshot.cpuBusySince else { return false }
                return now.timeIntervalSince(since) >= TabSleepPolicy.cpuSustain
            }.map(\.id))
            for tab in tabs where ids.contains(tab.id) {
                if cpuSlept.contains(tab.id) {
                    let percent = Int(((shares[tab.id] ?? limit) * 100).rounded())
                    log.info("slept \(tab.title) for CPU: \(percent, privacy: .public)% of a core for 3+ min")
                }
                tab.sleep()
                cpuUsage.reset(tab.id)
            }
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
        trimWebKitMemory()
    }

    /// How long a WebContent process may run service workers with no page in it before they are stopped.
    static let orphanWorkerGrace: TimeInterval = 3 * 60

    /// Stops service workers once a process has run them with no page in it for `orphanWorkerGrace`: a site's
    /// worker outlives its last tab in that tab's whole process (measured: 218 MB still up 3.5 min after closing
    /// Reddit). WebKit can only stop every worker in a pool (private `-[WKProcessPool _terminateServiceWorkers]`),
    /// so open sites' workers stop too; each starts again on its site's next request, as workers are meant to.
    /// Without the process list or the selector nothing happens.
    private func stopOrphanServiceWorkers(now: Date) {
        guard let snapshot = ProcessMemory.snapshot() else { return }
        let orphans = snapshot.webContent.filter { $0.runsServiceWorkers && $0.views.isEmpty }
        guard !orphans.isEmpty else {
            orphanWorkersSince = nil
            return
        }
        let since = orphanWorkersSince ?? now
        orphanWorkersSince = since
        guard now.timeIntervalSince(since) >= Self.orphanWorkerGrace else { return }
        orphanWorkersSince = nil
        let pools = [WebEnvironment.processPool, WebEnvironment.privateProcessPool].compactMap { $0 }
        let stopped = pools.filter { PrivateAPI.callVoid("_terminateServiceWorkers", on: $0) }.count
        let megabytes = orphans.reduce(0) { $0 + $1.footprint } / 1_048_576
        log.info("stopped service workers in \(stopped) pool(s): \(orphans.count) process(es) with no page, \(megabytes) MB")
    }

    /// Trims WebKit memory: purges in-memory caches across website data stores, and asks
    /// WebKit to run JavaScript garbage collection and clear process caches.
    func trimWebKitMemory() {
        web.emptyMemoryCaches()
        // The trim acts on a web view's process pool (a forced collection in every one of its processes), so once per
        // pool: tabs share `WebEnvironment.processPool`, and once per tab repeated the same work for each.
        var trimmed = Set<ObjectIdentifier>()
        for tab in allTabs {
            guard let webView = tab.webView else { continue }
            let pool = webView.configuration.value(forKey: "processPool") as AnyObject?
            guard trimmed.insert(ObjectIdentifier(pool ?? webView)).inserted else { continue }
            PrivateAPI.trimWebKitMemory(on: webView)
        }
    }

    /// When the system last reported memory pressure; `WebEnvironment` doesn't launch a spare process soon after.
    @ObservationIgnored var lastMemoryPressure: Date?
}
