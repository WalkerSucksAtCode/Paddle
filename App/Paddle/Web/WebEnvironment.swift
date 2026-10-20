import CryptoKit
import Foundation
import os
import PaddleCore
import WebKit

/// Shared WebKit setup for every tab: one content controller (user scripts, user CSS, block lists),
/// the default website data store (cookies and logins persist; private windows get a non-persistent one), and the
/// user agent.
@Observable
final class WebEnvironment {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "web")

    @ObservationIgnored let contentController = WKUserContentController()
    @ObservationIgnored let dataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.default()
        WebEnvironment.configureDataStoreIdentity(store, displayName: "Paddle")
        return store
    }()
    /// The other profiles' persistent stores, made on first use (`dataStore(for:)`).
    @ObservationIgnored private var profileStores: [String: WKWebsiteDataStore] = [:]
    @ObservationIgnored private(set) var config = PaddleConfig()
    @ObservationIgnored private var installedRuleLists: [String: WKContentRuleList] = [:]
    @ObservationIgnored private lazy var ruleStore: WKContentRuleListStore =
        WKContentRuleListStore(url: Paths.compiledRules) ?? .default()
    /// The default profile's extension controller, set by its `ExtensionHost` once at least one extension is allowed
    /// to run; every web view made after that carries it (popups copy the configuration, so they inherit it too). nil
    /// costs nothing: WebKit's extension machinery is never started. Private windows use this one.
    @ObservationIgnored private var extensionController: WKWebExtensionController?
    /// The other profiles' controllers, set the same way by their hosts.
    @ObservationIgnored private var profileExtensionControllers: [String: WKWebExtensionController] = [:]

    /// The controller a normal window of `profile` carries; nil while that profile runs no extension.
    func extensionController(for profile: String) -> WKWebExtensionController? {
        profile == ProfileStore.defaultID ? extensionController : profileExtensionControllers[profile]
    }

    /// Called by a profile's `ExtensionHost` when it makes its controller, and with nil when the profile is deleted.
    func setExtensionController(_ controller: WKWebExtensionController?, for profile: String) {
        if profile == ProfileStore.defaultID {
            extensionController = controller
        } else {
            profileExtensionControllers[profile] = controller
        }
    }

    /// One line per block list for the Content Blocking status item, e.g. "easylist: 61,204 rules", then one for
    /// the lists' scriptlets.
    private(set) var blockerLines: [BlockerLine] = []
    /// `blockerLines` as text (Settings, the Reload Config alert).
    var blockerStatus: [String] { blockerLines.map(\.text) }
    /// The lists' scriptlets as user scripts (`Scriptlets`), rebuilt with the block lists and added after user.css
    /// and userscripts by `reloadUserScripts`.
    @ObservationIgnored private var scriptletScripts: [WKUserScript] = []
    /// `paddlePageScript` is added once. `removeAllUserScripts` does not remove it.
    @ObservationIgnored private var didInstallPageScriptBridge = false
    @ObservationIgnored private var didInstallPageWorkMonitor = false
    @ObservationIgnored private var didInstallContactAutofill = false
    /// Contact autofill's own world: its message handler is reachable only from here, never from the page.
    private static let contactAutofillWorld = WKContentWorld.world(name: ContactAutofillScript.worldName)
    private(set) var isUpdatingFilters = false

    /// `Version/27.0 Safari/605.1.15` from the installed Safari, so sites treat Paddle as Safari.
    static let safariApplicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "27.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    var applicationName: String {
        config.userAgentSuffix.isEmpty ? Self.safariApplicationName : config.userAgentSuffix
    }

    /// One non-persistent data store shared by every private window, made with the first one and dropped when the
    /// last one closes (`endPrivateSession`), so the next private window starts with no cookies or storage.
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    /// The persistent store of a profile: the default profile keeps `dataStore` (so nothing moves on upgrade), every
    /// other one gets its own `WKWebsiteDataStore(forIdentifier:)` named by its id (cookies, logins, storage, cache).
    /// An id that isn't a UUID falls back to the default store only for the default profile's sake; callers pass ids
    /// from `ProfileStore`, which has only UUIDs.
    func dataStore(for profile: String) -> WKWebsiteDataStore {
        guard profile != ProfileStore.defaultID, let uuid = UUID(uuidString: profile) else { return dataStore }
        if let store = profileStores[profile] { return store }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        Self.configureDataStoreIdentity(store, displayName: "Paddle")
        profileStores[profile] = store
        return store
    }

    /// Deletes a deleted profile's data store from disk, after its windows (and so web views) are gone. Retries once
    /// because WebKit refuses while a web view still holds the store. False when it still failed.
    func removeDataStore(for profile: String) async -> Bool {
        guard profile != ProfileStore.defaultID, let uuid = UUID(uuidString: profile) else { return false }
        profileStores[profile] = nil
        for attempt in 0..<3 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: uuid)
                return true
            } catch {
                log.error("data store removal failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return false
    }

    /// Evicts WebKit's in-memory image, decoding, and resource caches across all active data stores.
    /// Disk caches, cookies, and local storage are untouched.
    func emptyMemoryCaches() {
        let stores = [dataStore] + Array(profileStores.values) + (privateDataStore.map { [$0] } ?? [])
        let memoryCacheType = Set([WKWebsiteDataTypeMemoryCache])
        for store in stores {
            store.removeData(ofTypes: memoryCacheType, modifiedSince: .distantPast) { }
        }
        log.info("evicted in-memory WebKit caches across \(stores.count) store(s)")
    }

    /// Web views of private windows get the private store and, unless `extensions` (the window carries extensions,
    /// see `BrowserModel.extensionsAllowed`), no extension controller. Content blockers, user CSS and userscripts are
    /// the same as everywhere.
    /// `profile` picks the persistent store and the extension controller of a normal window; private windows ignore
    /// it and carry the default profile's controller.
    func makeConfiguration(isPrivate: Bool, extensions: Bool, profile: String = ProfileStore.defaultID) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        Self.configureProcessIdentity(c, displayName: "Paddle", isPrivate: isPrivate)
        // This configuration's process pool gets the page notification provider (WebsiteNotifications). KVC, not
        // `processPool`: that property is deprecated.
        WebsiteNotifications.shared.providePageNotifications(on: c.value(forKey: "processPool") as AnyObject?, isPrivate: isPrivate)
        c.userContentController = contentController
        if isPrivate {
            let store = privateDataStore ?? {
                let s = WKWebsiteDataStore.nonPersistent()
                Self.configureDataStoreIdentity(s, displayName: "Paddle Private")
                return s
            }()
            privateDataStore = store
            c.websiteDataStore = store
        } else {
            c.websiteDataStore = dataStore(for: profile)
        }
        c.applicationNameForUserAgent = applicationName
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = config.fraudWarnings
        c.preferences.tabFocusesLinks = config.tabKeyHighlightsLinks
        // Paddle blocks pop-ups itself when it can tell a click from a script (`TabWebDelegate` createWebViewWith,
        // `PopupProbe`), so a window a script opens to download a file still works. Without that private flag WebKit
        // keeps blocking them silently, as before.
        c.preferences.javaScriptCanOpenWindowsAutomatically = Self.allowsScriptWindows
        c.preferences.minimumFontSize = CGFloat(config.minimumFontSize)
        PrivateAPI.setValue(config.developerTools, forKey: "developerExtrasEnabled", on: c.preferences)
        // A background tab is out of the window (`MountedWebPages` keeps only `BrowserModel.mountedWebTabs` in it). WebKit's default for such a view suspends its process; throttling keeps chat, mail and notification
        // pages receiving while it slows their timers and stops their drawing. Idle tabs still freeze and sleep
        // through Paddle's own policy.
        c.preferences.inactiveSchedulingPolicy = .throttle
        c.allowsAirPlayForMediaPlayback = true
        // Safari's default ("Stop media with sound"): pages can autoplay muted video, sound waits for a click or key.
        // WebKit's own macOS default lets pages start sound on their own.
        c.mediaTypesRequiringUserActionForPlayback = .audio
        c.webExtensionController = extensions ? extensionController(for: isPrivate ? ProfileStore.defaultID : profile) : nil
        Self.enableWebFeatures(c.preferences)
        if !isPrivate, config.speculativeLoading { Self.enableDNSPrefetching(c.preferences) }
        if !isPrivate { scheduleProcessWarm(for: c) }
        return c
    }

    private static let warmInitialProcess = NSSelectorFromString("_warmInitialProcess")
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// Keeps one spare WebContent process launched in the shared pool (`processPool`), so a new tab or a woken tab can skip launching
    /// one (a cold wake's process start measured 20-40 ms; the saving itself is not measured). WebKit prewarms by itself only once it has swapped processes on a navigation, and
    /// `prewarmsProcessesAutomatically` lives on the pool configuration, which cannot change for a pool that exists;
    /// `-[WKProcessPool _warmInitialProcess]` is a no-op while a prewarmed process is already waiting, so calling it
    /// after every web view creation refills the spare once the previous one was taken. Delayed and coalesced so the
    /// spare launches after the view that is being made has picked up its own process. Not for private windows; the
    /// spare carries no data store, so it serves any window. Without the selector nothing happens.
    /// Not in Low Power Mode or heat (`AppModel.power`), and not within a minute of memory pressure: a spare is an
    /// idle process (measured: one extra WebContent process of about 7 MB), the opposite of what a pressure trim frees.
    private func scheduleProcessWarm(for c: WKWebViewConfiguration) {
        guard let pool = c.value(forKey: "processPool") as? NSObject, pool.responds(to: Self.warmInitialProcess) else { return }
        warmTask?.cancel()
        warmTask = Task { [weak pool] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let pool else { return }
            let app = AppModel.shared
            guard !app.power.isConstrained, app.lastMemoryPressure.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
            pool.perform(Self.warmInitialProcess)
        }
    }

    private static let setDNSPrefetching = NSSelectorFromString("_setDNSPrefetchingEnabled:")

    /// WebKit's private DNS prefetching (off by default): looks up the hosts of a page's links while it loads, so a
    /// click skips the lookup. `speculativeLoading`, never in private windows. Without the call nothing changes.
    private static func enableDNSPrefetching(_ preferences: WKPreferences) {
        guard preferences.responds(to: setDNSPrefetching),
              let method = class_getInstanceMethod(type(of: preferences), setDNSPrefetching) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, setDNSPrefetching, true)
    }

    /// Settings' "Clear this site's data": removes every kind of website data WebKit keeps for `host` (cookies,
    /// caches, storage, service workers) from the store `isPrivate` picks. WebKit groups data by registrable domain,
    /// so this clears the whole domain (`www.` and other subdomains). Returns how many records it removed; a private
    /// store that no window has made yet has none.
    @discardableResult
    func clearData(forHost host: String, isPrivate: Bool = false, profile: String = ProfileStore.defaultID) async -> Int {
        guard let store = isPrivate ? privateDataStore : dataStore(for: profile) else { return 0 }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { SitePolicy.dataRecord($0.displayName, covers: host) }
        guard !records.isEmpty else { return 0 }
        await store.removeData(ofTypes: types, for: records)
        log.info("cleared website data: \(records.count) records")
        return records.count
    }

    /// The last private window closed: forget the private store. Its web views are gone (closing a window sleeps
    /// every tab), so WebKit discards its cookies, caches and storage with it.
    func endPrivateSession() {
        privateDataStore = nil
    }

    /// WebKit features Paddle turns on that WebKit ships off:
    /// - `requestIdleCallback` — Chrome/Firefox ship it; extensions (Proton Pass form detector) and
    ///   some sites call it with no fallback (the prelude has a stand-in);
    /// - `HiddenPageDOMTimerThrottlingAutoIncreases` — hidden-page timers throttle harder the longer
    ///   they stay hidden (WebKit already throttles; this lets the interval grow);
    /// - `AllowsPictureInPictureMediaPlayback` and `VideoPresentationManagerEnabled` together, or
    ///   `requestPictureInPicture()` fails with NotSupportedError (measured 2026-10).
    /// Private `_setEnabled:forFeature:`, guarded (`WebFeatureToggles`); without it nothing changes.
    private static func enableWebFeatures(_ preferences: WKPreferences) {
        let outcome = WebFeatureToggles.enable(enabledFeatures, in: preferences)
        guard !loggedFeatureOutcome else { return }
        let log = Logger(subsystem: "com.walker.Paddle", category: "web")
        switch outcome {
        case .unavailable(let reason):
            loggedFeatureOutcome = true
            log.notice("web features not enabled: \(reason, privacy: .public)")
        case .applied(let keys):
            let missing = wantedFeatureKeys.filter { !keys.contains($0) }.sorted()
            if !missing.isEmpty {
                loggedFeatureOutcome = true
                log.notice("web features missing from this WebKit: \(missing.joined(separator: ", "), privacy: .public)")
            }
        }
    }

    /// Set once the feature outcome has been logged, so the notice appears once per process.
    private static var loggedFeatureOutcome = false

    private static let wantedFeatureKeys: Set<String> = [
        "RequestIdleCallbackEnabled", "HiddenPageDOMTimerThrottlingAutoIncreases",
        "AllowsPictureInPictureMediaPlayback", "VideoPresentationManagerEnabled",
    ]

    /// The `_WKFeature` objects for `enableWebFeatures`, looked up once: `+_features` builds an object for every
    /// WebKit feature (hundreds), which is wasted work on each new web view.
    private static let enabledFeatures: [NSObject] = WebFeatureToggles.features(
        named: wantedFeatureKeys,
        in: WKPreferences.self as AnyObject
    )

    /// The configuration extension pages (popups, options pages, backgrounds) derive from: the browsing data store,
    /// the user agent and developer extras, and nothing else. No shared content controller, so user.css, userscripts
    /// and block lists never reach extension pages.
    func makeExtensionPageBaseConfiguration(profile: String = ProfileStore.defaultID) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        Self.configureProcessIdentity(c, displayName: "Paddle Extension")
        WebsiteNotifications.shared.providePageNotifications(on: c.value(forKey: "processPool") as AnyObject?, isPrivate: false)
        c.websiteDataStore = dataStore(for: profile)
        c.applicationNameForUserAgent = applicationName
        c.preferences.minimumFontSize = CGFloat(config.minimumFontSize)
        PrivateAPI.setValue(config.developerTools, forKey: "developerExtrasEnabled", on: c.preferences)
        Self.enableWebFeatures(c.preferences)
        return c
    }

    /// Sets process identity on WebKit configurations so child processes (WebContent, Networking, GPU) bear the
    /// Paddle name and bundle identifier in macOS Activity Monitor and system task accounting.
    /// WebKit tells Paddle whether a navigation came from a click (`WKNavigationAction._isUserInitiated`), so Paddle can
    /// let every script window reach `createWebViewWith` and block pages there itself.
    static let allowsScriptWindows = WKNavigationAction.instancesRespond(to: NSSelectorFromString("_isUserInitiated"))

    static func configureProcessIdentity(_ c: WKWebViewConfiguration, displayName: String = "Paddle", isPrivate: Bool = false) {
        if c.responds(to: Selector(("_setProcessDisplayName:"))) {
            c.perform(Selector(("_setProcessDisplayName:")), with: displayName as NSString)
        }
        if c.responds(to: Selector(("_setAttributedBundleIdentifier:"))) {
            c.perform(Selector(("_setAttributedBundleIdentifier:")), with: "com.walker.Paddle" as NSString)
        }
        if let pool = isPrivate ? privateProcessPool : processPool { c.setValue(pool, forKey: "processPool") }
    }

    /// The one process pool every Paddle configuration outside private windows uses (tabs, extension pages, Reader). A fresh
    /// `WKWebViewConfiguration` carries its own new pool (measured on macOS 27: three configurations, three pools), so
    /// without this each wake had a private pool: its prewarmed spare could serve no other tab, and the per-pool work
    /// (memory trim, stuck service workers, page notifications) reached only that tab. Pages still get one WebContent
    /// process each either way (measured); data stores keep processes apart inside a pool. KVC: the property is
    /// deprecated. nil if this WebKit has no `WKProcessPool`, and each configuration keeps its own.
    static let processPool = makeProcessPool(displayName: "Paddle")
    /// Private windows' pool: page notifications are answered per pool (`WebsiteNotifications`), and a private page
    /// must get no permission and show nothing.
    static let privateProcessPool = makeProcessPool(displayName: "Paddle Private")

    private static func makeProcessPool(displayName: String) -> NSObject? {
        guard let type = NSClassFromString("WKProcessPool") as? NSObject.Type else { return nil }
        let pool = type.init()
        configureProcessPoolIdentity(pool, displayName: displayName)
        return pool
    }

    static func configureProcessPoolIdentity(_ pool: NSObject, displayName: String = "Paddle") {
        if let cfg = PrivateAPI.value(of: pool, forKey: "_configuration") as? NSObject {
            if cfg.responds(to: Selector(("setSourceApplicationBundleIdentifier:"))) {
                cfg.perform(Selector(("setSourceApplicationBundleIdentifier:")), with: "com.walker.Paddle" as NSString)
            }
            if cfg.responds(to: Selector(("setSourceApplicationSecondaryIdentifier:"))) {
                cfg.perform(Selector(("setSourceApplicationSecondaryIdentifier:")), with: displayName as NSString)
            }
            if cfg.responds(to: Selector(("setPresentingApplicationPID:"))) {
                cfg.setValue(getpid(), forKey: "presentingApplicationPID")
            }
        }
    }

    static func configureDataStoreIdentity(_ store: WKWebsiteDataStore, displayName: String = "Paddle") {
        if let cfg = PrivateAPI.value(of: store, forKey: "_configuration") as? NSObject {
            if cfg.responds(to: Selector(("setSourceApplicationBundleIdentifier:"))) {
                cfg.perform(Selector(("setSourceApplicationBundleIdentifier:")), with: "com.walker.Paddle" as NSString)
            }
            if cfg.responds(to: Selector(("setSourceApplicationSecondaryIdentifier:"))) {
                cfg.perform(Selector(("setSourceApplicationSecondaryIdentifier:")), with: displayName as NSString)
            }
        }
    }

    /// Applies a (re)loaded config. New tabs pick up user agent changes; scripts and CSS apply on next load.
    func apply(_ config: PaddleConfig) {
        self.config = config
        reloadUserScripts()
    }

    // MARK: - User CSS and scripts

    /// Page-world half of the content prelude's `xray` and `pageScripts` sections. The content-script window and
    /// the page window do not share events, so the prelude writes a hidden element and dispatches on `document`.
    /// Capturing listeners stop the event before a page script sees it. Extension script URLs are posted to
    /// `PageScriptBridge`, which runs the file in this world; a `<script src>` would die on the page's CSP.
    private static let xrayBridgeScript = """
    (function () {
      function runQueued() {
        var html = document.documentElement;
        var raw = html && html.getAttribute('data-paddle-run');
        if (!raw || raw === '[]') return;
        html.removeAttribute('data-paddle-run');
        var batch;
        try { batch = JSON.parse(raw); } catch (e) { return; }
        if (!Array.isArray(batch)) return;
        for (var i = 0; i < batch.length; i++) {
          var item = batch[i];
          if (!item || typeof item.url !== 'string') continue;
          try {
            webkit.messageHandlers.paddlePageScript.postMessage({ url: item.url, dataset: item.dataset || {} });
          } catch (e) {}
        }
      }
      document.addEventListener('__paddle_run_page_script__', function (e) {
        e.stopImmediatePropagation();
        runQueued();
      }, true);
      if (document.documentElement) {
        new MutationObserver(runQueued).observe(document.documentElement, { attributes: true, attributeFilter: ['data-paddle-run'] });
      }
      document.addEventListener('DOMContentLoaded', runQueued);
      runQueued();
      document.addEventListener('__paddle_xray__', function (e) {
        e.stopImmediatePropagation();
        var el = document.getElementById('__paddle_xray__');
        if (!el) return;
        var raw = el.textContent;
        el.textContent = '';
        if (!raw) return;
        var m;
        try { m = JSON.parse(raw); } catch (err) { return; }
        if (!m || typeof m.k !== 'string') return;
        try {
          if (m.op === 'set') {
            window[m.k] = m.v;
          } else if (m.op === 'del') {
            delete window[m.k];
          } else if (m.op === 'get') {
            var has = m.k in window;
            var val = has ? window[m.k] : undefined;
            var reply = { has: has && typeof val !== 'function' };
            if (reply.has) {
              try { JSON.stringify(val); reply.v = val; }
              catch (err) { reply.has = false; }
            }
            el.setAttribute('data-reply', JSON.stringify(reply));
          }
        } catch (err) {}
      }, true);
      runQueued();
    })();
    """

    private func installPageScriptBridge() {
        guard !didInstallPageScriptBridge else { return }
        didInstallPageScriptBridge = true
        contentController.add(PageScriptBridge.shared, contentWorld: .page, name: PageScriptBridge.handlerName)
    }

    func reloadUserScripts() {
        installPageScriptBridge()
        contentController.removeAllUserScripts()

        // Tells the sleep sweep about uploads and unsaved changes (`keepPageWorkRunning`). Pages loaded while it was
        // off report nothing until they load again.
        if AppModel.shared.anyProfileKeepsPageWork {
            if !didInstallPageWorkMonitor {
                didInstallPageWorkMonitor = true
                contentController.add(PageWorkMonitor.shared, contentWorld: .page, name: PageWorkScript.handlerName)
            }
            contentController.addUserScript(WKUserScript(
                source: PageWorkScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
            ))
        }

        contentController.addUserScript(WKUserScript(
            source: Self.xrayBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
        ))
        // Remembers a column's scroll position across Back. See `ScrollRestoreScript`.
        contentController.addUserScript(WKUserScript(
            source: ScrollRestoreScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))

        // `contactAutofill`: the fill chip on name, email, phone and address fields. Pages loaded while it was off get
        // it when they next load.
        if config.contactAutofill {
            if !didInstallContactAutofill {
                didInstallContactAutofill = true
                contentController.addScriptMessageHandler(
                    ContactAutofillHandler.shared, contentWorld: Self.contactAutofillWorld, name: ContactAutofillScript.handlerName
                )
            }
            contentController.addUserScript(WKUserScript(
                source: ContactAutofillScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
                in: Self.contactAutofillWorld
            ))
        }

        // First, so user scripts see the persona too. Private windows share this controller, so they get it as well.
        let persona = SitePersonaScript.source(for: config.sitePersonas)
        if !persona.isEmpty {
            contentController.addUserScript(WKUserScript(
                source: persona, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
            ))
        }

        if let css = try? String(contentsOf: Paths.userCSS, encoding: .utf8), Self.hasRealCSS(css) {
            contentController.addUserScript(WKUserScript(
                source: Self.styleInjection(css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            ))
        }

        if config.underlineLinks {
            let underlineCSS = "a, a:link, a:visited { text-decoration: underline !important; }"
            contentController.addUserScript(WKUserScript(
                source: Self.styleInjection(underlineCSS),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            ))
        }

        let isDark = AppModel.shared.effectiveAppearanceIsDark
        let darkModeScript = DarkModeScript.source(for: config.sites, defaultDarkMode: config.defaultDarkMode(systemIsDark: isDark), invertTextImages: config.invertTextImages)
        contentController.addUserScript(WKUserScript(
            source: darkModeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))

        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.userScripts, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "js" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let script = UserScript(fileName: file.lastPathComponent, source: source)
            contentController.addUserScript(WKUserScript(
                source: script.wrappedSource,
                injectionTime: script.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: script.mainFrameOnly,
                in: script.isolated ? .defaultClient : .page
            ))
            log.info("user script loaded: \(script.name, privacy: .public)")
        }

        for script in scriptletScripts { contentController.addUserScript(script) }
    }

    private static func hasRealCSS(_ css: String) -> Bool {
        let withoutComments = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return !withoutComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func styleInjection(_ css: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [css])) ?? Data("[\"\"]".utf8)
        let literal = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return """
        (function () {
          const add = () => {
            const style = document.createElement("style");
            style.id = "paddle-user-css";
            style.textContent = \(literal);
            (document.head || document.documentElement).appendChild(style);
          };
          if (document.documentElement) add(); else document.addEventListener("DOMContentLoaded", add);
        })();
        """
    }

    // MARK: - Content blocking

    /// Opens when the first block-list load has installed every list (or found blocking off), or 3 s after the
    /// first tab waits on it. A tab's first page load waits on it (`Tab.wake`), so startup has no unblocked gap
    /// unless a list takes longer than that to compile; such pages reload once afterwards (`AppModel.start`).
    @ObservationIgnored let blockersReady = BlockerGate()
    /// The block-list load before this one, so loads run one at a time in order.
    @ObservationIgnored private var blockerLoadTail: Task<Void, Never>?

    /// Installs compiled block lists: each `config.filterLists` file, Paddle's own `paddle-filters.txt` (bundled),
    /// then `user-filters.txt`. Other files
    /// in `filters/` stay on disk unused, so a removed list stops blocking at the next reload. Unchanged
    /// lists load from cache; new or changed ones convert and compile in parallel, each installed as soon
    /// as it compiles, selectors first checked by a `SelectorValidator` that lives only for this call. A
    /// missing file starts from its bundled snapshot (`BundledFilterSnapshots`). Every list gets a status
    /// line, empty and failed included. User `@@` / `#@#` and `contentBlocking: false` hosts are appended
    /// to every list (`SharedExceptions`); WebKit applies exceptions only inside one list, and the cache
    /// key carries their fingerprint. Each list also gets the others' `@@` network exceptions (as uBO
    /// does) and a digest of the others' text in its key, so updating one recompiles the rest. Opens
    /// `blockersReady` when done.
    func loadContentBlockers() async {
        let previous = blockerLoadTail
        let load = Task {
            await previous?.value
            let started = ContinuousClock.now
            await performBlockerLoad()
            let first = !blockersReady.isReady
            let late = blockersReady.markReady()
            let took = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            if first {
                log.info("startup block lists installed in \(took, privacy: .public)\(late ? "; the gate had timed out, so pages that loaded meanwhile reload once" : "", privacy: .public)")
            } else {
                log.info("block lists reloaded in \(took, privacy: .public)")
            }
        }
        blockerLoadTail = load
        await load.value
    }

    /// One list that needs converting and compiling; `index` is its line in the status.
    private struct CompileJob: Sendable {
        let index: Int
        let name: String
        let identifier: String
        let text: String
        let shared: SharedExceptions
        /// The other filter lists' text: their `@@` exceptions join this list's (`SharedExceptions.adding`).
        let otherLists: [String]
    }

    /// One line of the Content blocking status. `summary` is set for an installed block list: its counts feed the
    /// Activity popover's "Not covered" disclosure. Scriptlet, failure and note lines have none.
    struct BlockerLine: Sendable {
        let text: String
        let summary: RuleListSummary?

        init(_ text: String, summary: RuleListSummary? = nil) {
            self.text = text
            self.summary = summary
        }
    }

    /// What compiling one list gave: its status line, and whether it was installed or left only a sidecar.
    private struct CompileOutcome: Sendable {
        let job: CompileJob
        let line: String
        let installed: Bool
        let sidecar: Bool
        var summary: RuleListSummary? = nil
    }

    private func performBlockerLoad() async {
        guard config.contentBlocking else {
            contentController.removeAllContentRuleLists()
            installedRuleLists.removeAll()
            if !scriptletScripts.isEmpty {
                scriptletScripts = []
                reloadUserScripts()
            }
            blockerLines = [BlockerLine("Off (contentBlocking is false in config.json)")]
            return
        }

        var status: [BlockerLine] = []
        var sources: [URL] = []
        renameLegacyFilterFiles()
        seedBundledSnapshots()
        for list in config.filterLists {
            guard let file = FilterUpdatePolicy.fileName(forList: list) else {
                status.append(BlockerLine("\(list): ignored, not an https URL"))
                continue
            }
            let url = Paths.filters.appending(path: file)
            // File names come from the whole URL, so only the same list entered twice shares one.
            guard !sources.contains(url) else {
                status.append(BlockerLine("\(list): ignored, listed twice"))
                continue
            }
            sources.append(url)
        }
        if let builtIn = Bundle.main.url(forResource: "paddle-filters", withExtension: "txt", subdirectory: "PaddleFilters") {
            sources.append(builtIn)
        }
        sources.append(Paths.userFilters)

        // Sites with `contentBlocking: false` join these as site-wide exceptions, so turning one off recompiles every
        // list with it rather than leaving those pages without the content controller.
        let userFiltersText = Self.readUserFilters() ?? ""
        let blockingOff = config.blockingOffHosts
        let shared = await Task.detached(priority: .utility) {
            SharedExceptions(userFilters: userFiltersText, blockingOffHosts: blockingOff)
        }.value

        var scriptletInputs: [(text: String, trusted: Bool)] = []
        var wanted: [String: WKContentRuleList] = [:]
        // Sidecars of lists that are current but not installed (no rules, or WebKit refused them).
        var sidecars: Set<String> = []
        var jobs: [CompileJob] = []
        // Every filter list's text up front: each list carries the others' exceptions, so their text is part of its key.
        let listTexts: [URL: String] = Dictionary(uniqueKeysWithValues: sources.filter { $0 != Paths.userFilters }.compactMap { file in
            (try? String(contentsOf: file, encoding: .utf8)).map { (file, $0) }
        })
        for file in sources {
            let name = file.deletingPathExtension().lastPathComponent
            guard let text = file == Paths.userFilters ? Self.readUserFilters() : try? String(contentsOf: file, encoding: .utf8) else {
                let exists = FileManager.default.fileExists(atPath: file.path)
                status.append(BlockerLine("\(name): \(exists ? "unreadable (not UTF-8 text)" : file == Paths.userFilters ? "no file" : "not downloaded yet")"))
                continue
            }
            // user-filters.txt is the user's own, so it counts as trusted.
            let trusted = file == Paths.userFilters || config.trustedLists.contains { FilterUpdatePolicy.fileName(forList: $0) == file.lastPathComponent }
            scriptletInputs.append((text, trusted))
            let listShared = file == Paths.userFilters ? shared.forUserFilters : shared
            let otherLists = sources.filter { $0 != file }.compactMap { listTexts[$0] }
            let fingerprint = listShared.fingerprint
            var keyText = fingerprint.isEmpty ? text : text + "\n\u{0}shared exceptions\n" + fingerprint
            // Only the other lists' `@@` lines go in the key, not their whole text: an EasyList update rarely changes its
            // exceptions (none changed between two versions a day apart, 2026-10), so EasyPrivacy needn't recompile.
            for other in otherLists {
                let lines = SharedExceptions.exceptionLines(in: other)
                keyText += "\n\u{0}other list " + SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let digest = SHA256.hash(data: Data(keyText.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            // Text, shared exceptions and converter version: a new converter recompiles lists WebKit still has cached
            // from the old one.
            let identifier = "\(name).v\(FilterListConverter.converterVersion).\(digest)"

            var cached = installedRuleLists[identifier]
            if cached == nil { cached = try? await ruleStore.contentRuleList(forIdentifier: identifier) }
            if let cached {
                wanted[identifier] = cached
                install(cached, identifier: identifier)
                let summary = await cachedSummary(identifier: identifier, text: text, shared: listShared, otherLists: otherLists)
                status.append(BlockerLine(summary.statusLine(name: name, cached: true), summary: summary))
                continue
            }
            // A list that gave no rules or failed to compile last time has only a sidecar; same text, same answer.
            if let remembered = savedSummary(identifier: identifier), !remembered.installable {
                sidecars.insert(identifier)
                status.append(BlockerLine(remembered.statusLine(name: name, cached: true)))
                continue
            }
            jobs.append(CompileJob(
                index: status.count, name: name, identifier: identifier, text: text, shared: listShared, otherLists: otherLists
            ))
            status.append(BlockerLine("\(name): compiling"))
        }
        // Scriptlets are in place before the startup gate opens, like the cached lists.
        if let line = await loadScriptlets(scriptletInputs) { status.append(BlockerLine(line)) }
        blockerLines = status

        if !jobs.isEmpty {
            // Shared by the parallel conversions and dropped with this scope, so cached loads start no web view and
            // the throwaway web view and its WebContent process go once every list is done.
            let validator = SelectorValidator()
            await withTaskGroup(of: CompileOutcome.self) { group in
                for job in jobs {
                    group.addTask { await self.compile(job, validator: validator) }
                }
                for await outcome in group {
                    status[outcome.job.index] = BlockerLine(outcome.line, summary: outcome.summary)
                    blockerLines = status
                    if outcome.installed, let list = installedRuleLists[outcome.job.identifier] { wanted[outcome.job.identifier] = list }
                    if outcome.sidecar { sidecars.insert(outcome.job.identifier) }
                }
            }
        }

        for (identifier, list) in installedRuleLists where wanted[identifier] == nil { contentController.remove(list) }
        for (identifier, list) in wanted where installedRuleLists[identifier] == nil { contentController.add(list) }
        installedRuleLists = wanted
        blockerLines = status
        await removeStaleCompiledLists(keeping: Set(wanted.keys), sidecars: sidecars)
    }

    /// Parses every list's scriptlet lines off the main thread, builds their user scripts and installs them (with
    /// user.css and userscripts). Returns the status line, nil when `scriptlets` is off.
    private func loadScriptlets(_ inputs: [(text: String, trusted: Bool)]) async -> String? {
        guard config.scriptlets else {
            if !scriptletScripts.isEmpty {
                scriptletScripts = []
                reloadUserScripts()
            }
            return nil
        }
        let (rules, summaries) = await Task.detached(priority: .userInitiated) { ScriptletSet.rules(from: inputs) }.value
        let built = Scriptlets.build(rules, blockingOffHosts: config.blockingOffHosts)
        scriptletScripts = built.scripts
        reloadUserScripts()
        let total = summaries.reduce(ScriptletSummary(), +)
        log.info("scriptlets: \(rules.count) rules (\(built.matched) by site, \(built.dispatched) in the shared script), \(total.accepted) lines accepted, \(total.refusedUnknown + total.refusedTrusted + total.malformed) skipped")
        return Self.scriptletStatusLine(rules: rules.count, summary: total)
    }

    /// "scriptlets: 23 rules from 23 lines; 6 lines skipped (names Paddle doesn't run: set-cookie, …)".
    static func scriptletStatusLine(rules: Int, summary: ScriptletSummary) -> String {
        var line = "scriptlets: \(rules.formatted()) \(rules == 1 ? "rule" : "rules") from \(summary.accepted.formatted()) \(summary.accepted == 1 ? "line" : "lines")"
        let skipped = summary.refusedUnknown + summary.refusedTrusted + summary.malformed
        if skipped > 0 {
            line += "; \(skipped.formatted()) skipped"
            if !summary.topRefused.isEmpty {
                line += " (names Paddle doesn't run: \(summary.topRefused.prefix(4).joined(separator: ", "))\(summary.topRefused.count > 4 ? ", …" : ""))"
            }
        }
        return line
    }

    /// Adds a list to the content controller now, so later page loads use it before the rest of the load is done.
    /// A previous version of the same list stays until the load ends (`performBlockerLoad` removes it then).
    private func install(_ list: WKContentRuleList, identifier: String) {
        guard installedRuleLists[identifier] == nil else { return }
        contentController.add(list)
        installedRuleLists[identifier] = list
    }

    /// Converts and compiles one list, installing it as soon as WebKit has compiled it.
    private func compile(_ job: CompileJob, validator: SelectorValidator) async -> CompileOutcome {
        let text = job.text, otherLists = job.otherLists
        let shared = await Task.detached(priority: .utility) {
            job.shared.adding(otherLists.map(SharedExceptions.listExceptions(in:)))
        }.value
        let (result, summary) = await Task.detached(priority: .utility) {
            let result = await FilterListConverter.convert(text, shared: shared) { await validator.validate($0) }
            return (result, RuleListSummary(text: text, result: result))
        }.value
        // WebKit refuses a list with no rules ("Empty extension"); there is nothing to install.
        guard summary.ruleCount > 0 else {
            saveSummary(summary, identifier: job.identifier)
            return CompileOutcome(job: job, line: summary.statusLine(name: job.name, cached: false), installed: false, sidecar: true)
        }
        do {
            guard let list = try await ruleStore.compileContentRuleList(forIdentifier: job.identifier, encodedContentRuleList: result.json) else {
                return CompileOutcome(job: job, line: "\(job.name): WebKit returned no rule list", installed: false, sidecar: false)
            }
            install(list, identifier: job.identifier)
            saveSummary(summary, identifier: job.identifier)
            log.info("compiled \(job.identifier, privacy: .public): \(result.ruleCount) rules, \(result.skippedLines) lines skipped, \(result.styleInjection) style rules, \(result.invalidSelectors) invalid selectors, regex \(result.regexTranslated) translated \(result.regexRefused) refused")
            return CompileOutcome(job: job, line: summary.statusLine(name: job.name, cached: false), installed: true, sidecar: false, summary: summary)
        } catch {
            let reason = RuleListSummary.compileFailureReason(
                helpAnchor: (error as NSError).userInfo[NSHelpAnchorErrorKey] as? String,
                fallback: error.localizedDescription
            )
            log.error("compile \(job.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            // Only WebKit refusing the rules is remembered; a disk or cancellation error says nothing about the list,
            // so no sidecar is saved and the next launch tries again.
            let nsError = error as NSError
            guard nsError.domain == WKError.errorDomain, nsError.code == WKError.Code.contentRuleListStoreCompileFailed.rawValue else {
                log.error("compile \(job.identifier, privacy: .public) not remembered as a failure: \(error.localizedDescription, privacy: .public)")
                return CompileOutcome(job: job, line: "\(job.name): compile error, will retry next launch", installed: false, sidecar: false)
            }
            // One rule WebKit refuses fails the whole list, and a translated regex is the likeliest culprit: compile
            // once more without the regex rules rather than leave the list blocking nothing.
            if result.containsRegexRules {
                let (retry, retrySummary) = await Task.detached(priority: .utility) {
                    let retry = await FilterListConverter.convert(text, shared: shared, dropRegex: true) { await validator.validate($0) }
                    return (retry, RuleListSummary(text: text, result: retry))
                }.value
                do {
                    if retry.ruleCount > 0,
                       let list = try await ruleStore.compileContentRuleList(forIdentifier: job.identifier, encodedContentRuleList: retry.json) {
                        install(list, identifier: job.identifier)
                        var dropped = retrySummary
                        dropped.regexDropped = reason
                        saveSummary(dropped, identifier: job.identifier)
                        log.info("compiled \(job.identifier, privacy: .public) without its regex rules: \(retry.ruleCount) rules")
                        return CompileOutcome(job: job, line: dropped.statusLine(name: job.name, cached: false), installed: true, sidecar: false, summary: dropped)
                    }
                    log.error("compile \(job.identifier, privacy: .public) without its regex rules gave no rule list (\(retry.ruleCount) rules)")
                } catch {
                    log.error("compile \(job.identifier, privacy: .public) without its regex rules failed too: \(String(describing: error), privacy: .public)")
                }
            }
            var failed = summary
            failed.compileFailure = reason
            saveSummary(failed, identifier: job.identifier)
            return CompileOutcome(job: job, line: failed.statusLine(name: job.name, cached: false), installed: false, sidecar: true)
        }
    }

    /// `user-filters.txt` decoded by `FilterListText.decode` (UTF-8, UTF-16 with a BOM, else Latin-1); nil when it
    /// can't be read, which includes a missing file.
    private static func readUserFilters() -> String? {
        (try? Data(contentsOf: Paths.userFilters)).map(FilterListText.decode)
    }

    /// Copies the bundled EasyList / EasyPrivacy snapshot into `filters/` for each configured default list whose
    /// file is missing (a first launch), dated by the snapshot's `! Version:` line so the automatic update
    /// downloads a current copy once the snapshot is `filterUpdateDays` old.
    private func seedBundledSnapshots() {
        let fm = FileManager.default
        for list in config.filterLists {
            guard let file = BundledFilterSnapshots.fileName(forList: list) else { continue }
            let destination = Paths.filters.appending(path: file)
            guard !fm.fileExists(atPath: destination.path),
                  let snapshot = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: "txt", subdirectory: "FilterSnapshots")
            else { continue }
            do {
                try fm.copyItem(at: snapshot, to: destination)
                let head = try? FileHandle(forReadingFrom: snapshot).read(upToCount: 4_096)
                let date = BundledFilterSnapshots.versionDate(String(decoding: head ?? Data(), as: UTF8.self)[...]) ?? .distantPast
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
                log.info("seeded \(file, privacy: .public) from the bundled snapshot")
            } catch {
                log.error("seeding \(file, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Moves `filters/<name>.txt` files from before file names carried the URL hash to the name their list uses
    /// now, so the list keeps blocking instead of reading "not downloaded yet" until the next download.
    private func renameLegacyFilterFiles() {
        let fm = FileManager.default
        let renames = FilterUpdatePolicy.legacyRenames(config.filterLists) { fm.fileExists(atPath: Paths.filters.appending(path: $0).path) }
        for (from, to) in renames {
            do {
                try fm.moveItem(at: Paths.filters.appending(path: from), to: Paths.filters.appending(path: to))
                log.info("renamed filter list \(from, privacy: .public) to \(to, privacy: .public)")
            } catch {
                log.error("rename \(from, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The sidecar `compiled-rules/<identifier>.json` written when the list was compiled.
    private static func summaryURL(_ identifier: String) -> URL {
        Paths.compiledRules.appending(path: "\(identifier).json")
    }

    private func saveSummary(_ summary: RuleListSummary, identifier: String) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: Self.summaryURL(identifier), options: .atomic)
    }

    private func savedSummary(identifier: String) -> RuleListSummary? {
        guard let data = try? Data(contentsOf: Self.summaryURL(identifier)) else { return nil }
        return try? JSONDecoder().decode(RuleListSummary.self, from: data)
    }

    /// The saved counts for a cached list. Lists compiled before sidecars existed are converted once more (not
    /// recompiled) to recover them. A sidecar from before the skip breakdown keeps its saved counts and gets the
    /// breakdown re-derived from the list text (a parse, no WebKit compile), then is saved again. Its selector counts
    /// stay as saved: only WebKit's own selector check could recount them.
    private func cachedSummary(identifier: String, text: String, shared: SharedExceptions, otherLists: [String]) async -> RuleListSummary {
        if var summary = savedSummary(identifier: identifier) {
            guard !summary.hasSkipBreakdown else { return summary }
            summary.skips = await Task.detached(priority: .utility) { FilterListConverter.skipBreakdown(text) }.value
            saveSummary(summary, identifier: identifier)
            return summary
        }
        let summary = await Task.detached(priority: .utility) {
            RuleListSummary(text: text, result: FilterListConverter.convert(
                text, shared: shared.adding(otherLists.map(SharedExceptions.listExceptions(in:)))
            ))
        }.value
        saveSummary(summary, identifier: identifier)
        return summary
    }

    /// Drops compiled lists and sidecars that no current list uses. `sidecars` are the identifiers of current
    /// lists that have a sidecar but nothing installed (no rules, or WebKit refused them).
    private func removeStaleCompiledLists(keeping: Set<String>, sidecars: Set<String>) async {
        if let identifiers = await ruleStore.availableIdentifiers() {
            for identifier in identifiers where !keeping.contains(identifier) {
                try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
            }
        }
        let keptSidecars = keeping.union(sidecars)
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.compiledRules, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !keptSidecars.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// What one Update Filter Lists run did: a line per list, and how many lists were written or failed.
    struct FilterUpdateReport {
        var lines: [String] = []
        var written = 0
        var failures = 0
        /// Another update was already running, so this one did nothing.
        var skipped = false
        var text: String { lines.joined(separator: "\n") }
    }

    /// Lists whose last automatic or manual download failed, keyed by file name, e.g.
    /// "easyprivacy: update failed (404), last downloaded 9 days ago". Shown under Content blocking in Activity.
    private(set) var filterUpdateProblems: [String: String] = [:]

    /// Downloads `lists` (default: every list in `config.filterLists`) into `filters/`, then recompiles if any
    /// list was written. Used by Paddle > Update Filter Lists and by the automatic update (`filterUpdateDays`).
    func updateFilterLists(_ lists: [String]? = nil) async -> FilterUpdateReport {
        guard !isUpdatingFilters else { return FilterUpdateReport(lines: ["Already updating."], skipped: true) }
        isUpdatingFilters = true
        defer { isUpdatingFilters = false }

        renameLegacyFilterFiles()
        let configured = Set(config.filterLists.compactMap(FilterUpdatePolicy.fileName(forList:)))
        filterUpdateProblems = filterUpdateProblems.filter { configured.contains($0.key) }

        var report = FilterUpdateReport()
        for string in lists ?? config.filterLists {
            guard let file = FilterUpdatePolicy.fileName(forList: string), let url = URL(string: string) else {
                report.lines.append("Skipped \(string): not an https URL")
                report.failures += 1
                continue
            }
            let name = (file as NSString).deletingPathExtension
            let destination = Paths.filters.appending(path: file)
            func failed(_ reason: String) {
                report.lines.append("\(name): \(reason)")
                report.failures += 1
                filterUpdateProblems[file] = "\(name): update failed (\(reason)), \(Self.downloadedAge(destination))"
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { failed("HTTP \(status)"); continue }
                guard response.expectedContentLength <= Int64(FilterListText.maxBytes), data.count <= FilterListText.maxBytes
                else { failed("larger than 50 MB"); continue }
                guard FilterListText.mayReplaceStoredList(data) else { failed("not a filter list"); continue }
                try data.write(to: destination, options: .atomic)
                report.lines.append("\(name): \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                report.written += 1
                filterUpdateProblems[file] = nil
            } catch {
                failed(error.localizedDescription)
            }
        }
        // Nothing new on disk means the installed rule lists are already current.
        if report.written > 0 { await loadContentBlockers() }
        return report
    }

    /// "last downloaded 3 days ago", or "never downloaded" when the list's file does not exist.
    private static func downloadedAge(_ file: URL) -> String {
        guard let date = modificationDate(file) else { return "never downloaded" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        return days <= 0 ? "last downloaded today" : "last downloaded \(days) day\(days == 1 ? "" : "s") ago"
    }

    private static func modificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The configured lists due for an automatic download: each judged on its own file in `filters/`.
    func filterListsDue(now: Date) -> [String] {
        FilterUpdatePolicy.dueLists(config.filterLists, now: now, days: config.filterUpdateDays) { file in
            Self.modificationDate(Paths.filters.appending(path: file))
        }
    }
}

private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String]? {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0) }
        }
    }
}
