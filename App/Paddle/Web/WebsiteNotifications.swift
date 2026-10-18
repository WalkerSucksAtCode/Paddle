import AppKit
import Foundation
import os
import PaddleCore
import UserNotifications
import WebKit

/// Website `Notification` API via macOS Notification Center. Private SPI: every call checks
/// `responds(to:)` and degrades to nothing.
///
/// Two WebKit paths, both end in `post`. Persistent (service worker): the default store's
/// `_WKWebsiteDataStoreDelegate` (`showNotification:`). Page (non-persistent): the process pool's
/// notification provider — WebKit sends it nowhere else, and the default does nothing.
/// `providePageNotifications(on:isPrivate:)` installs that provider (`PageNotificationProvider` C API).
/// Starting permission is `notificationPermissions` on both paths; the prompt is `TabWebDelegate`.
/// This object is also the `UNUserNotificationCenter` delegate, so a click brings the site's tab forward.
@MainActor
final class WebsiteNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebsiteNotifications()
    nonisolated private static let log = Logger(subsystem: "com.walker.Paddle", category: "notifications")

    private static let setDelegateSelector = NSSelectorFromString("set_delegate:")
    private static let persistentClickSelector = NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")

    /// Whether the macOS authorization request has been made in this run. It is asked once.
    private var askedSystem = false

    /// The process pools that carry the page provider, by the slot number WebKit hands back as `clientInfo`.
    private var pagePools: [Int: PagePool] = [:]
    private var nextPagePoolSlot = 1
    /// The page notifications WebKit has not destroyed yet, by WebKit's notification ID.
    private var pageRequests: [UInt64: PageRequest] = [:]
    private var loggedMissingPageAPI = false

    /// Called once at launch, before any window: Notification Center's delegate (a click can launch the app, so it is
    /// set before launch completes), then WebKit's delegate on the default data store. Private stores get neither.
    func install(on store: WKWebsiteDataStore) {
        UNUserNotificationCenter.current().delegate = self
        if store.responds(to: Self.setDelegateSelector) {
            _ = store.perform(Self.setDelegateSelector, with: self)
        } else {
            Self.log.notice("website notifications are off: this WebKit has no WKWebsiteDataStore._delegate")
        }
        #if DEBUG
        Self.verifySelectors()
        #endif
    }

    /// The first yes in a run asks macOS once whether Paddle may post notifications. macOS shows its own prompt, which
    /// Paddle never answers. When macOS refuses (now or earlier), the site's answer still stands, but macOS drops every
    /// notification, so that is logged once.
    func requestSystemAuthorization() {
        guard !askedSystem else { return }
        askedSystem = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.log.error("macOS notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Self.log.notice("macOS does not let Paddle post notifications; allow them in System Settings > Notifications")
            }
        }
    }

    // MARK: - WebKit: page notifications (the process pool's notification provider)

    /// Installs the page provider on a process pool that one of Paddle's configurations uses. WebEnvironment calls this as
    /// it makes each configuration, before the web view loads. A fresh `WKWebViewConfiguration` gets its own pool, and each
    /// pool has its own WebKit notification manager (measured: two fresh configurations give two different managers), so
    /// every pool needs the provider. A private window's pool gets it too, answering no permission and showing nothing.
    func providePageNotifications(on pool: AnyObject?, isPrivate: Bool) {
        guard let pool else { return }
        guard let api = PageNotificationAPI.functions else {
            if !loggedMissingPageAPI {
                loggedMissingPageAPI = true
                Self.log.notice("page notifications are off: this WebKit lacks \(PageNotificationAPI.missing.joined(separator: ", "), privacy: .public)")
            }
            return
        }
        pagePools = pagePools.filter { $0.value.pool != nil }
        // A page notification whose pool is gone can't be answered; WebKit may never say it is destroyed.
        pageRequests = pageRequests.filter { pagePools[$0.value.slot] != nil }
        guard !pagePools.values.contains(where: { $0.pool === pool }) else { return }
        guard MemoryLayout<PageNotificationProvider>.size == 72,
              MemoryLayout<PageNotificationProvider>.offset(of: \.clientInfo) == 8,
              MemoryLayout<PageNotificationProvider>.offset(of: \.show) == 16
        else {
            Self.log.fault("page notifications are off: PageNotificationProvider does not match WKNotificationProviderV0")
            return
        }
        guard let manager = api.contextManager(Unmanaged.passUnretained(pool).toOpaque()) else {
            Self.log.notice("a pool got no page notification provider: WebKit returned no notification manager")
            return
        }
        let slot = nextPagePoolSlot
        nextPagePoolSlot += 1
        let provider = UnsafeMutablePointer<PageNotificationProvider>.allocate(capacity: 1)
        provider.initialize(to: PageNotificationProvider.make(slot: slot))
        // Registered before WebKit is told about the provider, since WebKit may call back during `setProvider`.
        pagePools[slot] = PagePool(pool: pool, isPrivate: isPrivate, manager: manager, provider: provider)
        api.setProvider(manager, UnsafeRawPointer(provider))
        Self.log.info("page notification provider installed on \(self.pagePools.count) pool(s)")
    }

    /// The permission answers a pool's page provider gives: none for a private window, the same answers as the data store otherwise.
    fileprivate func pagePermissions(slot: Int) -> [String: Bool] {
        guard let pool = pagePools[slot], !pool.isPrivate else { return [:] }
        return permissionAnswers()
    }

    /// A page notification WebKit showed. Shown only from a live, non-private pool, and only while the site is allowed.
    fileprivate func showPage(_ notice: PageNotice) {
        guard let pool = pagePools[notice.slot], pool.pool != nil else {
            Self.log.notice("dropped a page notification: its window is gone")
            return
        }
        guard !pool.isPrivate else {
            Self.log.notice("dropped a page notification from a private window")
            return
        }
        guard let url = URL(string: notice.origin), let origin = Self.origin(of: url), let host = Self.host(of: url) else {
            Self.log.notice("dropped a page notification with no usable origin")
            return
        }
        guard isAllowed(url) else {
            Self.log.notice("dropped a notification from \(host, privacy: .public): notifications are not allowed for it")
            return
        }
        let id = notice.id
        let userInfo: [AnyHashable: Any] = [
            "origin": origin,
            "uuid": UUID().uuidString,
            "persistent": false,
            "pageNotificationID": NSNumber(value: id),
        ]
        let identifier = post(title: notice.title, body: notice.body, tag: notice.tag, origin: origin, userInfo: userInfo) {
            WebsiteNotifications.shared.pageDidShow(id)
        }
        pageRequests[id] = PageRequest(identifier: identifier, slot: notice.slot)
    }

    /// The manager of a page notification's pool, while that pool is alive. Once the pool is gone WebKit's manager may be
    /// too, so no reply goes to it.
    private func liveManager(forPage id: UInt64) -> UnsafeMutableRawPointer? {
        guard let request = pageRequests[id], let pool = pagePools[request.slot], pool.pool != nil else { return nil }
        return pool.manager
    }

    /// macOS accepted the request: WebKit fires the page's `onshow`.
    private func pageDidShow(_ id: UInt64) {
        guard let manager = liveManager(forPage: id) else { return }
        PageNotificationAPI.functions?.didShow(manager, id)
    }

    /// A click on a page notification: WebKit fires the page's `onclick`. The tab is brought forward in `handleClick`.
    private func pageClicked(_ id: UInt64) {
        guard let manager = liveManager(forPage: id) else { return }
        PageNotificationAPI.functions?.didClick(manager, id)
    }

    /// The page called `close()`: take its notification out of Notification Center.
    fileprivate func cancelPage(_ id: UInt64) {
        guard let request = pageRequests[id] else { return }
        removeNotifications(withIdentifiers: [request.identifier])
    }

    /// WebKit cleared these notifications: take them out of Notification Center and forget them.
    fileprivate func clearPages(_ ids: [UInt64]) {
        for id in ids {
            guard let request = pageRequests.removeValue(forKey: id) else { continue }
            removeNotifications(withIdentifiers: [request.identifier])
        }
    }

    /// WebKit destroyed a page notification: nothing to answer any more.
    fileprivate func forgetPage(_ id: UInt64) {
        pageRequests[id] = nil
    }

    /// WebKit gave a pool its notification manager (`clientInfo` names the pool).
    fileprivate func attachManager(_ manager: Int, slot: Int) {
        pagePools[slot]?.manager = UnsafeMutableRawPointer(bitPattern: manager)
    }

    /// WebKit removed a manager: no reply goes to it from now on.
    fileprivate func detachManager(_ manager: Int) {
        for pool in pagePools.values where Int(bitPattern: pool.manager) == manager {
            pool.manager = nil
        }
    }

    private func removeNotifications(withIdentifiers identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - WebKit: permissions and notifications (_WKWebsiteDataStoreDelegate)

    /// Read by WebKit for the origins of the default store, so `Notification.permission` reads "granted" or "denied"
    /// on load: this run's answers, then each `sites` entry's allow or deny (the config wins). Origins are `scheme://host`.
    @objc(notificationPermissionsForWebsiteDataStore:)
    func notificationPermissions(for dataStore: WKWebsiteDataStore) -> [String: NSNumber] {
        guard dataStore === AppModel.shared.web.dataStore else { return [:] }
        return permissionAnswers().mapValues { NSNumber(value: $0) }
    }

    /// The origin → allowed answers, from this run's answers and the `sites` entries (the config wins).
    private func permissionAnswers() -> [String: Bool] {
        let app = AppModel.shared
        var answers: [String: Bool] = [:]
        for answer in app[permissionsFor: false, profile: ProfileStore.defaultID].all where answer.kind == .notifications {
            guard let url = URL(string: answer.site), let origin = Self.origin(of: url) else { continue }
            answers[origin] = answer.allowed
        }
        for (origin, allowed) in app.config.notificationPermissions {
            answers[origin] = allowed
        }
        return answers
    }

    /// A notification a page showed (`_WKNotificationData`, read through KVC). Shown only while the site is allowed:
    /// its `sites` setting is allow, or it is `ask` and this run's answer was yes. Otherwise dropped and logged.
    @objc(websiteDataStore:showNotification:)
    func websiteDataStore(_ dataStore: WKWebsiteDataStore, showNotification notification: NSObject) {
        guard dataStore === AppModel.shared.web.dataStore else { return }
        let originString = PrivateAPI.value(of: notification, forKey: "origin") as? String
        guard
            let url = (PrivateAPI.value(of: notification, forKey: "securityOrigin") as? URL)
                ?? originString.flatMap(URL.init(string:)),
            let origin = Self.origin(of: url),
            let host = Self.host(of: url)
        else {
            Self.log.notice("dropped a notification with no usable origin")
            return
        }
        guard isAllowed(url) else {
            Self.log.notice("dropped a notification from \(host, privacy: .public): notifications are not allowed for it")
            return
        }

        let title = PrivateAPI.value(of: notification, forKey: "title") as? String ?? ""
        let body = PrivateAPI.value(of: notification, forKey: "body") as? String ?? ""
        let tag = PrivateAPI.value(of: notification, forKey: "tag") as? String ?? ""
        let uuid = (PrivateAPI.value(of: notification, forKey: "uuid") as? NSUUID)?.uuidString ?? UUID().uuidString
        // A service-worker notification has a registration URL; Web Push ones are not supported, only these.
        let persistent = (PrivateAPI.value(of: notification, forKey: "serviceWorkerRegistrationURL") as? URL) != nil

        var userInfo: [AnyHashable: Any] = ["origin": origin, "uuid": uuid, "persistent": persistent]
        if let dict = PrivateAPI.call("dictionaryRepresentation", on: notification) as? NSDictionary,
           PropertyListSerialization.propertyList(dict, isValidFor: .binary) {
            userInfo["dict"] = dict
        }
        post(title: title, body: body, tag: tag, origin: origin, userInfo: userInfo)
    }

    // MARK: - Shared by both WebKit paths

    /// Whether the site at `url` may show notifications now: its `sites` setting is allow, or it is `ask` and this run's
    /// answer was yes.
    func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = Self.host(of: url) else { return false }
        let app = AppModel.shared
        switch app.config.sitePolicy(forHost: host).notifications {
        case .allow: return true
        case .deny: return false
        case .ask:
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return app[permissionsFor: false, profile: ProfileStore.defaultID].answer(site: "\(scheme)://\(host):\(port)", kind: .notifications) == true
        }
    }

    /// Posts one notification through Notification Center. A tag replaces the same site's earlier notification with that
    /// tag, as in the Notification API; the origin is part of the identifier so two sites that pick the same tag don't
    /// replace each other. `onAdded` runs on the main actor once macOS has accepted the request. Returns the identifier.
    @discardableResult
    private func post(
        title: String,
        body: String,
        tag: String,
        origin: String,
        userInfo: [AnyHashable: Any],
        onAdded: (@MainActor @Sendable () -> Void)? = nil
    ) -> String {
        let host = Self.host(ofUserInfo: userInfo)
        let uuid = userInfo["uuid"] as? String ?? UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = host
        content.threadIdentifier = host
        content.userInfo = userInfo
        let identifier = tag.isEmpty ? uuid : "\(origin)#\(tag)"
        NotificationInbox.shared.record(origin: origin, host: host, title: title, body: body)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("could not post a notification: \(error.localizedDescription, privacy: .public)")
            } else if let onAdded {
                Task { @MainActor in onAdded() }
            }
        }
        return identifier
    }

    // MARK: - Notification Center (UNUserNotificationCenterDelegate)

    /// A banner shows even while Paddle is in front, except when the key window already shows the notifying site.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let host = Self.host(ofUserInfo: notification.request.content.userInfo)
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            handler(WebsiteNotifications.shared.isOnScreen(host: host) ? [] : [.banner, .list, .sound])
        }
    }

    /// A click brings the most recently active normal tab on the site forward, or opens the site in a new tab.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let userInfo = response.notification.request.content.userInfo
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            WebsiteNotifications.shared.handleClick(userInfo: userInfo)
            handler()
        }
    }

    /// The host a notification's `origin` names, for the presentation decision (empty when there is none).
    private nonisolated static func host(ofUserInfo userInfo: [AnyHashable: Any]) -> String {
        guard let origin = userInfo["origin"] as? String, let url = URL(string: origin) else { return "" }
        return host(of: url) ?? ""
    }

    private func isOnScreen(host: String) -> Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow?.windowController as? BrowserWindowController,
              let shown = window.model.selectedTab?.url else { return false }
        return !host.isEmpty && Self.host(of: shown) == host
    }

    /// New Tab's Notifications section: what a click on the notification does.
    func showSite(origin: String) { handleClick(userInfo: ["origin": origin]) }

    private func handleClick(userInfo: [AnyHashable: Any]) {
        let app = AppModel.shared
        if let origin = userInfo["origin"] as? String, let url = URL(string: origin), let host = Self.host(of: url) {
            let matches = app.windows.flatMap { window in
                window.model.allTabs
                    .filter { !$0.isPrivate && $0.url.flatMap(Self.host(of:)) == host }
                    .map { (window: window, tab: $0) }
            }
            // The page that posted it still has its web view; another tab of the site may be asleep and would come
            // back as a fresh load. So a live tab first, then the most recently used.
            let live = matches.filter { $0.tab.webView != nil }
            if let match = (live.isEmpty ? matches : live).max(by: { $0.tab.lastActive < $1.tab.lastActive }) {
                match.window.model.select(match.tab)
                if match.window.window?.isMiniaturized == true { match.window.window?.deminiaturize(nil) }
                match.window.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else {
                app.open([url])
                NSApp.activate()
            }
        }
        if let id = (userInfo["pageNotificationID"] as? NSNumber)?.uint64Value {
            pageClicked(id)
        }
        if userInfo["persistent"] as? Bool == true, let dict = userInfo["dict"] as? NSDictionary {
            processPersistentClick(dict)
        }
    }

    /// A service-worker notification's click goes to the page's own `notificationclick` handler, through WebKit, on
    /// the default data store. Guarded: a WebKit without the selector just gets no page-side click.
    private func processPersistentClick(_ dict: NSDictionary) {
        let store = AppModel.shared.web.dataStore
        guard store.responds(to: Self.persistentClickSelector) else {
            Self.log.notice("persistent notification click not delivered: WebKit lacks _processPersistentNotificationClick:")
            return
        }
        typealias Process = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
        let process = unsafeBitCast(store.method(for: Self.persistentClickSelector), to: Process.self)
        process(store, Self.persistentClickSelector, dict) { handled in
            if !handled { Self.log.notice("the page did not handle a notification click") }
        }
    }

    // MARK: - Origins

    /// `https://example.com`, or `https://example.com:8443` for a port that isn't the scheme's default: how WebKit names an
    /// origin. Nil for a URL without a scheme or host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = host(of: url) else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// The host as `sites` keys match it (`PaddleConfig.normalizedHost`), or nil without one.
    private nonisolated static func host(of url: URL) -> String? {
        guard let host = url.host(), !host.isEmpty else { return nil }
        return PaddleConfig.normalizedHost(host)
    }

    #if DEBUG
    /// Every private selector this object and `TabWebDelegate` answer to, checked where WebKit sends them, and every WebKit
    /// C symbol the page provider calls. The Notification Center methods are protocol requirements, so the compiler checks those.
    static func verifySelectors() {
        let delegateSelector = NSSelectorFromString("_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:")
        let checks: [(String, Bool)] = [
            ("TabWebDelegate \(delegateSelector)", TabWebDelegate.instancesRespond(to: delegateSelector)),
            ("notificationPermissionsForWebsiteDataStore:", instancesRespond(to: NSSelectorFromString("notificationPermissionsForWebsiteDataStore:"))),
            ("websiteDataStore:showNotification:", instancesRespond(to: NSSelectorFromString("websiteDataStore:showNotification:"))),
        ] + PageNotificationAPI.names.map { name -> (String, Bool) in
            ("WebKit C API \(name)", PageNotificationAPI.symbol(name) != nil)
        }
        let missing = checks.filter { !$0.1 }.map(\.0)
        if missing.isEmpty {
            log.info("notification selector check passed: \(checks.count) selectors and symbols")
        } else {
            log.fault("notification selector check FAILED: \(missing.joined(separator: ", "), privacy: .public)")
            assertionFailure("notification selector check failed: \(missing)")
        }
    }
    #endif
}

// MARK: - Page notification provider (WebKit's C API)

/// A page notification WebKit showed, copied out of WebKit's objects inside the callback. WebKit owns those objects until
/// it destroys the notification, so nothing reads them after the callback returns.
nonisolated struct PageNotice: Sendable {
    let id: UInt64
    let slot: Int
    let title: String
    let body: String
    let tag: String
    let origin: String
}

/// What a page notification's reply needs: the request identifier it was posted under, and the pool it came from.
private struct PageRequest {
    let identifier: String
    let slot: Int
}

/// One process pool that carries the page provider. `pool` is weak: the pool lives as long as the web views made on it,
/// and WebKit's manager lives with the pool, so once the pool is gone no reply goes to a freed manager.
@MainActor
private final class PagePool {
    weak var pool: AnyObject?
    let isPrivate: Bool
    /// WebKit's notification manager for the pool, nil once WebKit removes it.
    var manager: UnsafeMutableRawPointer?
    /// The provider WebKit reads. Allocated once and never freed: WebKit keeps the pointer for as long as the pool lives.
    let provider: UnsafeMutablePointer<PageNotificationProvider>

    init(pool: AnyObject, isPrivate: Bool, manager: UnsafeMutableRawPointer, provider: UnsafeMutablePointer<PageNotificationProvider>) {
        self.pool = pool
        self.isPrivate = isPrivate
        self.manager = manager
        self.provider = provider
    }
}

typealias CRef = UnsafeMutableRawPointer
typealias CRefToRef = @convention(c) (CRef?) -> CRef?
typealias CRefToVoid = @convention(c) (CRef?) -> Void
typealias CRefToUInt64 = @convention(c) (CRef?) -> UInt64
typealias CRefToBool = @convention(c) (CRef?) -> Bool
typealias CRefAndIDToVoid = @convention(c) (CRef?, UInt64) -> Void
typealias CSetProvider = @convention(c) (CRef?, UnsafeRawPointer?) -> Void
typealias CStringToCF = @convention(c) (UnsafeRawPointer?, CRef?) -> CRef?
typealias CCreateDictionary = @convention(c) () -> CRef?
typealias CSetDictionaryItem = @convention(c) (CRef?, CRef?, CRef?) -> Void
typealias CCreateString = @convention(c) (UnsafePointer<CChar>?) -> CRef?
typealias CCreateBoolean = @convention(c) (Bool) -> CRef?
typealias CArraySize = @convention(c) (CRef?) -> Int
typealias CArrayItem = @convention(c) (CRef?, Int) -> CRef?

/// The provider's callbacks, as C function pointers (`@convention(c)`, so none of them captures anything).
typealias CShowCallback = @convention(c) (CRef?, CRef?, UnsafeRawPointer?) -> Void
typealias CRefCallback = @convention(c) (CRef?, UnsafeRawPointer?) -> Void
typealias CPermissionsCallback = @convention(c) (UnsafeRawPointer?) -> CRef?

/// `WKNotificationProviderV0` from WebKit's WKNotificationManager.h: the `base` (version, clientInfo), then seven callbacks.
/// Swift lays stored properties out in declaration order with C alignment, so these offsets match the C struct: version 0,
/// clientInfo 8, show 16, then 8 bytes each, 72 bytes in all. `providePageNotifications` checks them before installing.
nonisolated struct PageNotificationProvider {
    var version: Int32
    var clientInfo: UnsafeRawPointer?
    var show: CShowCallback?
    var cancel: CRefCallback?
    var didDestroyNotification: CRefCallback?
    var addNotificationManager: CRefCallback?
    var removeNotificationManager: CRefCallback?
    var notificationPermissions: CPermissionsCallback?
    var clearNotifications: CRefCallback?

    /// The provider for one pool. `slot` comes back to every callback as `clientInfo`.
    nonisolated static func make(slot: Int) -> PageNotificationProvider {
        PageNotificationProvider(
            version: 0,
            clientInfo: UnsafeRawPointer(bitPattern: slot),
            show: { _, notification, info in PageNotificationCallbacks.show(notification, slot: Int(bitPattern: info)) },
            cancel: { notification, _ in PageNotificationCallbacks.cancel(notification) },
            didDestroyNotification: { notification, _ in PageNotificationCallbacks.didDestroy(notification) },
            addNotificationManager: { manager, info in PageNotificationCallbacks.addManager(manager, slot: Int(bitPattern: info)) },
            removeNotificationManager: { manager, _ in PageNotificationCallbacks.removeManager(manager) },
            notificationPermissions: { info in PageNotificationCallbacks.permissions(slot: Int(bitPattern: info)) },
            clearNotifications: { array, _ in PageNotificationCallbacks.clear(array) }
        )
    }
}

/// The WebKit C functions the page provider calls, each resolved with dlsym. Nil from `init?` when WebKit lacks one.
nonisolated struct PageNotificationFunctions: Sendable {
    let contextManager: CRefToRef          // WKContextGetNotificationManager(WKContextRef): the pool object itself
    let setProvider: CSetProvider          // WKNotificationManagerSetProvider
    let copyTitle: CRefToRef               // WKNotificationCopyTitle: a new string
    let copyBody: CRefToRef                // WKNotificationCopyBody: a new string
    let copyTag: CRefToRef                 // WKNotificationCopyTag: a new string
    let securityOrigin: CRefToRef          // WKNotificationGetSecurityOrigin: borrowed
    let notificationID: CRefToUInt64       // WKNotificationGetID
    let isPersistent: CRefToBool           // WKNotificationGetIsPersistent
    let copyOriginString: CRefToRef        // WKSecurityOriginCopyToString: a new string
    let copyCFString: CStringToCF          // WKStringCopyCFString: a new CFString
    let release: CRefToVoid                // WKRelease
    let didShow: CRefAndIDToVoid           // WKNotificationManagerProviderDidShowNotification
    let didClick: CRefAndIDToVoid          // WKNotificationManagerProviderDidClickNotification
    let createDictionary: CCreateDictionary // WKMutableDictionaryCreate: a new dictionary
    let setDictionaryItem: CSetDictionaryItem // WKDictionarySetItem: the dictionary retains the item
    let createString: CCreateString        // WKStringCreateWithUTF8CString: a new string
    let createBoolean: CCreateBoolean      // WKBooleanCreate: a new boolean
    let arraySize: CArraySize              // WKArrayGetSize
    let arrayItem: CArrayItem              // WKArrayGetItemAtIndex: borrowed
    let uint64Value: CRefToUInt64          // WKUInt64GetValue: borrowed

    nonisolated init?() {
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            PageNotificationAPI.symbol(name).map { unsafeBitCast($0, to: type) }
        }
        guard
            let contextManager = load("WKContextGetNotificationManager", CRefToRef.self),
            let setProvider = load("WKNotificationManagerSetProvider", CSetProvider.self),
            let copyTitle = load("WKNotificationCopyTitle", CRefToRef.self),
            let copyBody = load("WKNotificationCopyBody", CRefToRef.self),
            let copyTag = load("WKNotificationCopyTag", CRefToRef.self),
            let securityOrigin = load("WKNotificationGetSecurityOrigin", CRefToRef.self),
            let notificationID = load("WKNotificationGetID", CRefToUInt64.self),
            let isPersistent = load("WKNotificationGetIsPersistent", CRefToBool.self),
            let copyOriginString = load("WKSecurityOriginCopyToString", CRefToRef.self),
            let copyCFString = load("WKStringCopyCFString", CStringToCF.self),
            let release = load("WKRelease", CRefToVoid.self),
            let didShow = load("WKNotificationManagerProviderDidShowNotification", CRefAndIDToVoid.self),
            let didClick = load("WKNotificationManagerProviderDidClickNotification", CRefAndIDToVoid.self),
            let createDictionary = load("WKMutableDictionaryCreate", CCreateDictionary.self),
            let setDictionaryItem = load("WKDictionarySetItem", CSetDictionaryItem.self),
            let createString = load("WKStringCreateWithUTF8CString", CCreateString.self),
            let createBoolean = load("WKBooleanCreate", CCreateBoolean.self),
            let arraySize = load("WKArrayGetSize", CArraySize.self),
            let arrayItem = load("WKArrayGetItemAtIndex", CArrayItem.self),
            let uint64Value = load("WKUInt64GetValue", CRefToUInt64.self)
        else { return nil }
        self.contextManager = contextManager
        self.setProvider = setProvider
        self.copyTitle = copyTitle
        self.copyBody = copyBody
        self.copyTag = copyTag
        self.securityOrigin = securityOrigin
        self.notificationID = notificationID
        self.isPersistent = isPersistent
        self.copyOriginString = copyOriginString
        self.copyCFString = copyCFString
        self.release = release
        self.didShow = didShow
        self.didClick = didClick
        self.createDictionary = createDictionary
        self.setDictionaryItem = setDictionaryItem
        self.createString = createString
        self.createBoolean = createBoolean
        self.arraySize = arraySize
        self.arrayItem = arrayItem
        self.uint64Value = uint64Value
    }
}

/// WebKit's page-notification C API, looked up by name. A WebKit without one of these names gets no provider.
nonisolated enum PageNotificationAPI {
    nonisolated static let names = [
        "WKContextGetNotificationManager", "WKNotificationManagerSetProvider",
        "WKNotificationCopyTitle", "WKNotificationCopyBody", "WKNotificationCopyTag",
        "WKNotificationGetSecurityOrigin", "WKNotificationGetID", "WKNotificationGetIsPersistent",
        "WKSecurityOriginCopyToString", "WKStringCopyCFString", "WKRelease",
        "WKNotificationManagerProviderDidShowNotification", "WKNotificationManagerProviderDidClickNotification",
        "WKMutableDictionaryCreate", "WKDictionarySetItem", "WKStringCreateWithUTF8CString", "WKBooleanCreate",
        "WKArrayGetSize", "WKArrayGetItemAtIndex", "WKUInt64GetValue",
    ]

    nonisolated static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW) else { return nil }
        return dlsym(handle, name)
    }

    /// The names this WebKit does not export. Empty on a WebKit with the whole page API.
    nonisolated static let missing: [String] = names.filter { symbol($0) == nil }

    /// Nil when any name is missing: no provider is installed then.
    nonisolated static let functions: PageNotificationFunctions? = PageNotificationFunctions()
}

/// The provider's callbacks. WebKit calls them on the main thread; each copies what it needs out of WebKit's objects, then
/// continues on the main actor in `WebsiteNotifications`.
nonisolated enum PageNotificationCallbacks {
    nonisolated static func show(_ notification: CRef?, slot: Int) {
        guard let api = PageNotificationAPI.functions, let notification else { return }
        // A service-worker notification comes through the data-store delegate instead.
        guard !api.isPersistent(notification) else { return }
        let notice = PageNotice(
            id: api.notificationID(notification),
            slot: slot,
            title: string(api, api.copyTitle(notification)),
            body: string(api, api.copyBody(notification)),
            tag: string(api, api.copyTag(notification)),
            origin: originString(api, api.securityOrigin(notification))
        )
        Task { @MainActor in WebsiteNotifications.shared.showPage(notice) }
    }

    nonisolated static func cancel(_ notification: CRef?) {
        guard let api = PageNotificationAPI.functions, let notification else { return }
        let id = api.notificationID(notification)
        Task { @MainActor in WebsiteNotifications.shared.cancelPage(id) }
    }

    nonisolated static func didDestroy(_ notification: CRef?) {
        guard let api = PageNotificationAPI.functions, let notification else { return }
        let id = api.notificationID(notification)
        Task { @MainActor in WebsiteNotifications.shared.forgetPage(id) }
    }

    nonisolated static func addManager(_ manager: CRef?, slot: Int) {
        guard let manager else { return }
        let bits = Int(bitPattern: manager)
        Task { @MainActor in WebsiteNotifications.shared.attachManager(bits, slot: slot) }
    }

    nonisolated static func removeManager(_ manager: CRef?) {
        guard let manager else { return }
        let bits = Int(bitPattern: manager)
        Task { @MainActor in WebsiteNotifications.shared.detachManager(bits) }
    }

    nonisolated static func clear(_ array: CRef?) {
        guard let api = PageNotificationAPI.functions, let array else { return }
        var ids: [UInt64] = []
        for index in 0..<api.arraySize(array) {
            if let item = api.arrayItem(array, index) { ids.append(api.uint64Value(item)) }
        }
        Task { @MainActor in WebsiteNotifications.shared.clearPages(ids) }
    }

    /// The permission answers for a pool, as a WebKit dictionary (WebKit adopts the +1 it gets back). WebKit asks on the
    /// main thread; if it ever doesn't, the answer is empty and pages read "default".
    nonisolated static func permissions(slot: Int) -> CRef? {
        guard let api = PageNotificationAPI.functions else { return nil }
        let answers: [String: Bool] = Thread.isMainThread
            ? MainActor.assumeIsolated { WebsiteNotifications.shared.pagePermissions(slot: slot) }
            : [:]
        return dictionary(api, answers)
    }

    /// A WebKit string as a Swift string. WebKit's copy functions return a new reference, released here. Empty for nil.
    nonisolated private static func string(_ api: PageNotificationFunctions, _ ref: CRef?) -> String {
        guard let ref else { return "" }
        defer { api.release(ref) }
        guard let cf = api.copyCFString(nil, ref) else { return "" }
        return Unmanaged<CFString>.fromOpaque(cf).takeRetainedValue() as String
    }

    /// The origin of a notification as a string. The origin is borrowed from the notification; empty for nil.
    nonisolated private static func originString(_ api: PageNotificationFunctions, _ origin: CRef?) -> String {
        guard let origin else { return "" }
        return string(api, api.copyOriginString(origin))
    }

    nonisolated private static func dictionary(_ api: PageNotificationFunctions, _ answers: [String: Bool]) -> CRef? {
        guard let dictionary = api.createDictionary() else { return nil }
        for (origin, allowed) in answers {
            guard let key = origin.withCString({ api.createString($0) }) else { continue }
            if let value = api.createBoolean(allowed) {
                api.setDictionaryItem(dictionary, key, value)
                api.release(value)
            }
            api.release(key)
        }
        return dictionary
    }
}
