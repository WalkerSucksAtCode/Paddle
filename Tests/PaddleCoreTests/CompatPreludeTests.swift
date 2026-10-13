import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing

/// The v2 prelude run headless in JavaScriptCore against a stand-in for WebKit's extension namespace. Real WebKit
/// behaviour (namespace rebuilding, service workers, popups) is wave 4c-3's live check.
struct CompatPreludeTests {
    static let manifest = #"{"manifest_version":3,"name":"T","version":"1","permissions":["storage","tabs","favicon","notifications"],"optional_permissions":["cookies"],"background":{"service_worker":"sw.js"},"action":{"default_popup":"popup.html"}}"#

    static func plan(_ persona: Persona = .chrome, shims: Bool = true, installReason: String? = nil, manifest: String = manifest) throws -> CompatPlan {
        var plan = try CompatPlan.make(manifestData: Data(manifest.utf8), persona: persona, runtimeID: "abcd", installReason: installReason)
        plan.versions = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0.8078.12", firefoxVersion: "157.0")
        plan.uiLocale = "en_GB"
        plan.platformVersion = "27.0.1"
        plan.shims = shims
        return plan
    }

    /// A stand-in for WebKit's namespace: events whose prototype has add/remove/hasListener, a `lastError` getter
    /// on the runtime's prototype, permissions that reject names WebKit doesn't know (E23), and a scripting API
    /// that records its calls.
    static let environment = """
    globalThis.__timers = [];
    globalThis.setTimeout = (f) => { __timers.push(f); return __timers.length; };
    globalThis.clearTimeout = () => {};
    globalThis.__flush = () => { let n = 0; while (__timers.length && n++ < 100) __timers.shift()(); };
    class Ev { constructor() { this._l = new Set(); } addListener(l) { this._l.add(l); } removeListener(l) { this._l.delete(l); } hasListener(l) { return this._l.has(l); } }
    globalThis.Ev = Ev;
    class Runtime { get lastError() { return globalThis.__nativeLastError; } }
    const runtime = Object.assign(new Runtime(), {id: 'abcd', onMessage: new Ev(), onInstalled: new Ev(),
      getURL: (p) => 'chrome-extension://abcd/' + p, sendMessage: (...a) => Promise.resolve({sent: a})});
    const granted = new Set(['storage', 'tabs', 'nativeMessaging']);
    const known = new Set(['storage', 'tabs', 'nativeMessaging', 'cookies', 'alarms']);
    const permissions = {
      getAll() { return Promise.resolve({permissions: [...granted], origins: ['<all_urls>']}); },
      contains(q) { for (const x of q.permissions || []) if (!known.has(x)) return Promise.reject(new Error('Invalid permission ' + x)); return Promise.resolve((q.permissions || []).every((x) => granted.has(x))); },
      request(q) { globalThis.__requested = q; return Promise.resolve(true); },
      remove(q) { return Promise.resolve(true); },
    };
    const scripting = {calls: [], executeScript(inj) { this.calls.push(inj); return Promise.resolve(inj.files && inj.files[0] === 'paddle-content.js' ? [{result: 'prelude'}] : [{result: 'orig'}]); }};
    const ns = {
      runtime, permissions, scripting,
      tabs: {getCurrent() { return Promise.resolve({id: 7}); }},
      i18n: {getMessage(n) { return n === '@@ui_locale' ? '' : 'msg:' + n; }},
      storage: {local: {}},
      action: {onClicked: new Ev(), enable(t) { globalThis.__enabled = t; }},
      extension: {getViews(o) { return o.type === 'popup' ? (globalThis.__popupViews || []) : []; }},
    };
    globalThis.__ns = ns;
    globalThis.chrome = ns;
    globalThis.browser = ns;
    class Navigator { get userAgent() { return 'Safari'; } get vendor() { return 'Apple Computer, Inc.'; } }
    globalThis.Navigator = Navigator;
    globalThis.navigator = new Navigator();
    """

    static let window = "globalThis.window = globalThis; globalThis.document = {}; globalThis.location = {pathname: '/popup.html'};"

    /// A context with the environment, `before`, then the prelude. Fails the test on any uncaught exception.
    static func run(_ plan: CompatPlan, kind: CompatPlan.Kind = .full, window: Bool = false, before: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        for script in [environment, window ? Self.window : "", before, CompatPrelude.source(for: plan, kind: kind)] {
            context.evaluateScript(script)
            #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        }
        return context
    }

    static func eval(_ context: JSContext, _ js: String) -> String {
        let value = context.evaluateScript("(() => { const v = (\(js)); return v === undefined ? 'undefined' : JSON.stringify(v); })()")
        return context.exception?.toString() ?? value?.toString() ?? "nil"
    }

    /// Settles the promise `js` (microtasks drain between evaluations) and returns its JSON, or `ERR:` + message.
    static func settle(_ context: JSContext, _ js: String) -> String {
        context.evaluateScript("globalThis.__r = 'pending'; Promise.resolve(\(js)).then((v) => { globalThis.__r = v === undefined ? 'undefined' : JSON.stringify(v); }, (e) => { globalThis.__r = 'ERR:' + e.message; });")
        context.evaluateScript("__flush()")
        return context.evaluateScript("globalThis.__r")?.toString() ?? "nil"
    }

    // MARK: - Shape

    @Test(arguments: [Persona.chrome, .firefox])
    func sourcesParseAndEmbedThePlan(persona: Persona) throws {
        let context = try #require(JSContext())
        for kind in [CompatPlan.Kind.full, .content] {
            let source = CompatPrelude.source(for: try Self.plan(persona), kind: kind)
            context.setObject(source, forKeyedSubscript: "src" as NSString)
            #expect(context.evaluateScript("(function () { try { new Function(src); return 'ok'; } catch (e) { return String(e); } })()")?.toString() == "ok")
            #expect(source.contains("\"kind\":\"\(kind.rawValue)\""))
            #expect(!source.contains("__PADDLE_PLAN__"))
        }
    }

    @Test func noneGetsThe4bPreludeAndNativeNothing() throws {
        #expect(CompatPrelude.source(for: try Self.plan(.none), kind: .full) == ExtensionCompat.prelude)
        #expect(CompatPrelude.source(for: try Self.plan(.none), kind: .content) == ExtensionCompat.prelude)
        #expect(CompatPrelude.source(for: try Self.plan(.native), kind: .full).isEmpty)
    }

    @Test func planReadsTheManifest() throws {
        let plan = try Self.plan()
        #expect(plan.requiredPermissions == ["storage", "tabs", "favicon", "notifications"])
        #expect(plan.optionalPermissions == ["cookies"])
        #expect(plan.popupPath == "popup.html")
        #expect(plan.paddleGranted == ["nativeMessaging"])
        let raised = try CompatPlan.make(manifestData: Data(#"{"minimum_chrome_version":"170"}"#.utf8), persona: .chrome, runtimeID: "x")
        #expect(raised.versions.chromeMajor == 170)
        #expect(throws: (any Error).self) { try CompatPlan.make(manifestData: Data("[]".utf8), persona: .chrome, runtimeID: "x") }
    }

    // MARK: - Persona

    @Test func chromePersonaHidesBrowserAndPinsChrome() throws {
        let c = try Self.run(try Self.plan(.chrome), window: true)
        #expect(Self.eval(c, "typeof browser") == #""undefined""#)
        #expect(Self.eval(c, "'browser' in globalThis") == "true", "E11: defined as undefined, not deleted")
        #expect(Self.eval(c, "chrome === __ns") == "true")
        // Writable, so an extension's own `browser = chrome` polyfill works; `chrome` stays pinned.
        #expect(Self.eval(c, "(() => { chrome = 1; browser = chrome; return chrome === __ns && browser === __ns; })()") == "true")
        #expect(Self.eval(c, "navigator.userAgent") == #""Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36""#)
        #expect(Self.eval(c, "navigator.vendor") == #""Google Inc.""#)
        let brands = Persona.chrome.brands(try Self.plan().versions).map { "\($0.brand)/\($0.version)" }
        #expect(Self.eval(c, "navigator.userAgentData.brands.map(b => b.brand + '/' + b.version).join('|')") == "\"\(brands.joined(separator: "|"))\"")
        #expect(Self.eval(c, "JSON.stringify(navigator.userAgentData) === JSON.stringify({brands: navigator.userAgentData.brands, mobile: false, platform: 'macOS'})") == "true")
        #expect(Self.settle(c, "navigator.userAgentData.getHighEntropyValues(['platformVersion', 'uaFullVersion', 'nope']).then(v => [v.platformVersion, v.uaFullVersion, v.platform, 'nope' in v])") == #"["27.0.1","156.0.8078.12","macOS",false]"#)
        #expect(Self.settle(c, "navigator.userAgentData.getHighEntropyValues('x')").hasPrefix("ERR:"))
        #expect(Self.eval(c, "[chrome.app.isInstalled, chrome.app.getDetails(), chrome.app.InstallState.NOT_INSTALLED]") == #"[false,null,"not_installed"]"#)
        #expect(Self.eval(c, "typeof chrome.runtime.getBrowserInfo") == #""undefined""#)
    }

    @Test func firefoxPersonaPinsBothAndAnswersGetBrowserInfo() throws {
        let c = try Self.run(try Self.plan(.firefox), window: true)
        #expect(Self.eval(c, "browser === __ns && chrome === __ns") == "true")
        #expect(Self.eval(c, "(() => { browser = 1; return browser === __ns; })()") == "true")
        #expect(Self.eval(c, "navigator.userAgent") == #""Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) Gecko/20100101 Firefox/157.0""#)
        #expect(Self.eval(c, "[navigator.vendor, navigator.oscpu, navigator.appVersion, 'userAgentData' in navigator]") == #"["","Intel Mac OS X 10.15","5.0 (Macintosh)",false]"#)
        #expect(Self.settle(c, "browser.runtime.getBrowserInfo()") == #"{"name":"Firefox","vendor":"Mozilla","version":"157.0","buildID":"20181001000000"}"#)
        #expect(Self.eval(c, "'app' in chrome") == "false")
        #expect(Self.eval(c, "chrome.runtime.OnInstalledReason.BROWSER_UPDATE") == #""browser_update""#)
    }

    /// In a page's content world both personas keep WebKit's own `browser` and `chrome` (E11: a pin to another value
    /// loses tabs.sendMessage replies), locked so a content script can't swap them out: WebKit delivers
    /// runtime.onMessage through that world's `browser`, and Proton Pass's Proxy swap had cut its autofill off.
    @Test func contentWorldGlobalsAreWebKitsAndCantBeSwapped() throws {
        for persona in [Persona.firefox, .chrome] {
            let context = try Self.run(try Self.plan(persona), kind: .content, window: true)
            context.evaluateScript("globalThis.__b = browser; globalThis.__c = chrome;")
            for name in ["browser", "chrome"] {
                #expect(Self.eval(context, "(() => { const d = Object.getOwnPropertyDescriptor(globalThis, '\(name)'); return [d.configurable, 'get' in d, 'set' in d]; })()") == "[false,true,true]", "\(persona) \(name)")
            }
            // Proton Pass's swap, in strict mode: ignored, no exception, and the objects are still WebKit's.
            #expect(Self.eval(context, "(() => { 'use strict'; globalThis.browser = new Proxy({}, {}); globalThis.chrome = 2; browser = chrome; return [browser === __b, chrome === __c, typeof browser.runtime.id]; })()") == #"[true,true,"string"]"#, "\(persona)")
        }
        let firefox = try Self.run(try Self.plan(.firefox), kind: .content, window: true)
        #expect(Self.eval(firefox, "navigator.userAgent.includes('Firefox/157.0')") == "true", "the rest of the persona still applies")
    }

    @Test func aWebPagesOwnWorldIsLeftAlone() throws {
        let context = try #require(JSContext())
        context.evaluateScript("class Navigator { get userAgent() { return 'Safari'; } }; globalThis.navigator = new Navigator(); globalThis.chrome = {runtime: {}};")
        context.evaluateScript(CompatPrelude.source(for: try Self.plan(.chrome), kind: .content))
        #expect(context.exception == nil)
        #expect(Self.eval(context, "[navigator.userAgent, typeof globalThis[Symbol.for('paddle.compat')], 'browser' in globalThis]") == #"["Safari","undefined",false]"#)
    }

    // MARK: - Held objects, idempotency, isolation

    @Test func holdsEveryObjectItTouches() throws {
        let c = try Self.run(try Self.plan(.chrome), window: true)
        let held = "globalThis[Symbol.for('paddle.compat')].held"
        for object in ["__ns", "__ns.runtime", "__ns.permissions", "__ns.i18n", "__ns.tabs", "__ns.storage", "__ns.action", "__ns.scripting", "Navigator.prototype", "Ev.prototype", "__ns.storage.managed", "navigator.userAgentData"] {
            #expect(Self.eval(c, "\(held).includes(\(object))") == "true", "\(object)")
        }
        #expect(Self.eval(c, "Object.getOwnPropertyDescriptor(globalThis, Symbol.for('paddle.compat')).enumerable") == "false")
        #expect(Self.eval(c, "Object.keys(globalThis).some(k => k.includes('paddle'))") == "false")
        #expect(Self.eval(c, "globalThis[Symbol.for('paddle.compat')].errors") == "[]")
    }

    @Test func contentPreludeIsIdempotent() throws {
        let plan = try Self.plan(.chrome)
        let c = try Self.run(plan, kind: .content)
        let before = Self.eval(c, "globalThis[Symbol.for('paddle.compat')].held.length")
        c.evaluateScript("globalThis.__first = globalThis[Symbol.for('paddle.compat')]")
        c.evaluateScript(CompatPrelude.source(for: plan, kind: .content))
        c.evaluateScript(CompatPrelude.source(for: plan, kind: .full))
        #expect(c.exception == nil)
        #expect(Self.eval(c, "globalThis[Symbol.for('paddle.compat')] === __first") == "true")
        #expect(Self.eval(c, "globalThis[Symbol.for('paddle.compat')].held.length") == before)
        #expect(Self.eval(c, "__first.kind") == #""content""#)
    }

    @Test func oneFailingSectionDoesNotStopTheRest() throws {
        let throwing = "Object.defineProperty(__ns, 'i18n', {get() { throw new Error('boom'); }, configurable: true});"
        let c = try Self.run(try Self.plan(.chrome), before: throwing)
        #expect(Self.eval(c, "globalThis[Symbol.for('paddle.compat')].errors") == #"["i18n: boom"]"#)
        #expect(Self.eval(c, "typeof chrome.storage.managed.get") == #""function""#)
        #expect(Self.eval(c, "chrome.action.getUserSettings !== undefined && chrome.tabs.TAB_ID_NONE === -1") == "true")
        #expect(Self.settle(c, "chrome.permissions.getAll().then(r => r.permissions)") == #"["storage","tabs"]"#)
    }

    // MARK: - Gating

    @Test func shimsOffLeavesOnlyThePersona() throws {
        let c = try Self.run(try Self.plan(.chrome, shims: false), window: true)
        #expect(Self.eval(c, "typeof browser") == #""undefined""#)
        #expect(Self.eval(c, "navigator.vendor") == #""Google Inc.""#)
        #expect(Self.eval(c, "[typeof chrome.runtime.OnInstalledReason, typeof chrome.storage.managed, chrome.permissions.getAll === __ns.permissions.getAll]") == #"["undefined","undefined",true]"#)
    }

    @Test func contentKindIsSlim() throws {
        let c = try Self.run(try Self.plan(.chrome), kind: .content)
        #expect(Self.eval(c, "chrome.runtime.OnInstalledReason.INSTALL") == #""install""#)
        #expect(Self.eval(c, "chrome.runtime.getManifest().name") == #""T""#)
        #expect(Self.eval(c, "chrome.i18n.getMessage('@@ui_locale')") == #""en_GB""#)
        #expect(Self.eval(c, "[typeof chrome.storage.managed, typeof chrome.runtime.onUpdateAvailable, typeof chrome.action.getUserSettings]") == #"["undefined","undefined","undefined"]"#)
        #expect(Self.eval(c, "chrome.scripting.executeScript.toString().includes('this.calls')") == "true", "executeScript untouched")
        #expect(Self.eval(c, "chrome.permissions.getAll.toString().includes('granted')") == "true", "permissions untouched")
    }

    // MARK: - Shims

    @Test func permissionsHidePaddlesGrantAndAnswerUnknownNames() throws {
        let c = try Self.run(try Self.plan(.chrome))
        #expect(Self.settle(c, "chrome.permissions.getAll()") == #"{"permissions":["storage","tabs"],"origins":["<all_urls>"]}"#)
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['storage']})") == "true")
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['nativeMessaging']})") == "false")
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['favicon']})") == "false", "E23: no rejection")
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['storage', 'favicon']})") == "false")
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['cookies']})") == "false")
        #expect(Self.settle(c, "chrome.permissions.request({permissions: ['nativeMessaging']})") == "ERR:Only permissions specified in the manifest may be requested.")
        #expect(Self.settle(c, "chrome.permissions.request({permissions: ['cookies', 'favicon']})") == "false")
        #expect(Self.settle(c, "chrome.permissions.request({permissions: ['cookies']})") == "true")
        #expect(Self.eval(c, "__requested.permissions") == #"["cookies"]"#)
    }

    @Test func declaredOrShimmedNamesShow() throws {
        var plan = try Self.plan(.chrome, manifest: #"{"manifest_version":3,"permissions":["storage","nativeMessaging","notifications"]}"#)
        plan.shimmedPermissions = ["notifications"]
        let c = try Self.run(plan)
        #expect(Self.settle(c, "chrome.permissions.getAll().then(r => r.permissions)") == #"["storage","tabs","nativeMessaging","notifications"]"#)
        #expect(Self.settle(c, "chrome.permissions.contains({permissions: ['notifications', 'nativeMessaging']})") == "true")
    }

    @Test func callbackAndPromiseForms() throws {
        let c = try Self.run(try Self.plan(.chrome))
        #expect(Self.settle(c, "chrome.runtime.requestUpdateCheck()") == #"{"status":"no_update"}"#)
        c.evaluateScript("chrome.runtime.requestUpdateCheck((r) => { globalThis.__cb = [r.status, chrome.runtime.lastError === undefined]; })")
        c.evaluateScript("__flush()")
        #expect(Self.eval(c, "__cb") == #"["no_update",true]"#)
        c.evaluateScript("chrome.permissions.contains({permissions: ['favicon']}, (r) => { globalThis.__cb2 = r; })")
        #expect(Self.eval(c, "__cb2") == "false")

        // A failure: the callback sees lastError, and only while it runs; the promise form rejects.
        #expect(Self.settle(c, "chrome.storage.managed.set({a: 1})") == "ERR:This is a read-only store.")
        c.evaluateScript("globalThis.__nativeLastError = undefined; chrome.storage.managed.set({a: 1}, (r) => { globalThis.__cb3 = [r, chrome.runtime.lastError && chrome.runtime.lastError.message]; })")
        #expect(Self.eval(c, "__cb3") == #"[null,"This is a read-only store."]"#)
        #expect(Self.eval(c, "chrome.runtime.lastError === undefined") == "true")
        c.evaluateScript("globalThis.__nativeLastError = {message: 'native'}")
        #expect(Self.eval(c, "chrome.runtime.lastError.message") == #""native""#, "WebKit's own lastError still shows through")
        #expect(Self.settle(c, "chrome.storage.managed.get(null)") == "{}")
        #expect(Self.settle(c, "chrome.action.getUserSettings()") == #"{"isOnToolbar":true}"#)
    }

    @Test func inertEventsEnumsAndListenerCounts() throws {
        let c = try Self.run(try Self.plan(.chrome))
        #expect(Self.eval(c, "(() => { const f = () => {}; chrome.runtime.onUpdateAvailable.addListener(f); return [chrome.runtime.onUpdateAvailable.hasListener(f), chrome.runtime.onSuspend.hasListeners()]; })()") == "[true,false]")
        #expect(Self.eval(c, "[chrome.runtime.PlatformOs.MAC, chrome.runtime.OnInstalledReason.CHROME_UPDATE, chrome.tabs.TAB_ID_NONE, chrome.tabs.TabStatus.COMPLETE, chrome.scripting.ExecutionWorld.MAIN]") == #"["mac","chrome_update",-1,"complete","MAIN"]"#)
        #expect(Self.eval(c, "typeof chrome.declarativeNetRequest") == #""undefined""#, "no namespace is invented")
        #expect(Self.eval(c, "(() => { const f = () => {}; const e = chrome.runtime.onMessage; const a = e.hasListeners(); e.addListener(f); const b = e.hasListeners(); e.removeListener(f); return [a, b, e.hasListeners(), e.hasListener(f)]; })()") == "[false,true,false,false]")
    }

    @Test func getManifestIsTheOriginalAndFresh() throws {
        let c = try Self.run(try Self.plan(.chrome))
        #expect(Self.eval(c, "chrome.runtime.getManifest().background") == #"{"service_worker":"sw.js"}"#)
        #expect(Self.eval(c, "(() => { const a = chrome.runtime.getManifest(); a.name = 'x'; return chrome.runtime.getManifest().name; })()") == #""T""#)
        #expect(Self.eval(c, "[chrome.i18n.getMessage('@@ui_locale'), chrome.i18n.getMessage('hi')]") == #"["en_GB","msg:hi"]"#)
    }

    @Test func getCurrentIsUndefinedInThePopupOnly() throws {
        let popup = try Self.run(try Self.plan(.chrome), window: true)
        #expect(Self.settle(popup, "chrome.tabs.getCurrent()") == "undefined")
        popup.evaluateScript("chrome.tabs.getCurrent((t) => { globalThis.__t = t === undefined ? 'none' : t; })")
        popup.evaluateScript("__flush()")
        #expect(Self.eval(popup, "__t") == #""none""#)

        let page = try Self.run(try Self.plan(.chrome), window: true, before: "location.pathname = '/options.html';")
        #expect(Self.settle(page, "chrome.tabs.getCurrent()") == #"{"id":7}"#)
        let viaViews = try Self.run(try Self.plan(.chrome), window: true, before: "location.pathname = '/other.html'; globalThis.__popupViews = [globalThis];")
        #expect(Self.settle(viaViews, "chrome.tabs.getCurrent()") == "undefined")
    }

    @Test func executeScriptRunsTheContentPreludeFirstAndKeepsTheResult() throws {
        let c = try Self.run(try Self.plan(.chrome))
        #expect(Self.settle(c, "chrome.scripting.executeScript({target: {tabId: 1}, files: ['inj.js']})") == #"[{"result":"orig"}]"#)
        #expect(Self.eval(c, "__ns.scripting.calls.map(x => x.files.join())") == #"["paddle-content.js","inj.js"]"#)
        c.evaluateScript("__ns.scripting.calls.length = 0")
        #expect(Self.settle(c, "chrome.scripting.executeScript({target: {tabId: 1}, world: 'MAIN', func: () => 1})") == #"[{"result":"orig"}]"#)
        #expect(Self.eval(c, "__ns.scripting.calls.length") == "1")
    }

    @Test func onInstalledIsSynthesisedOnceInTheBackground() throws {
        let worker = "globalThis.ServiceWorkerGlobalScope = class { static [Symbol.hasInstance](x) { return x === globalThis; } };"
        let listener = "globalThis.__got = []; chrome.runtime.onInstalled.addListener((d) => __got.push(d.reason));"
        let c = try Self.run(try Self.plan(.chrome, installReason: "install"), before: worker)
        c.evaluateScript(listener)
        c.evaluateScript("__flush(); __flush();")
        #expect(Self.eval(c, "__got") == #"["install"]"#)
        #expect(Self.eval(c, "__ns.runtime.onInstalled.hasListeners()") == "true")

        let notFirst = try Self.run(try Self.plan(.chrome), before: worker)
        notFirst.evaluateScript(listener + "__flush();")
        #expect(Self.eval(notFirst, "__got") == "[]")
        let notBackground = try Self.run(try Self.plan(.chrome, installReason: "install"), window: true)
        notBackground.evaluateScript(listener + "__flush();")
        #expect(Self.eval(notBackground, "__got") == "[]")
    }

    @Test func manifestV2Aliases() throws {
        let manifest = #"{"manifest_version":2,"name":"T","page_action":{"default_popup":"p.html"},"background":{"scripts":["bg.js"]}}"#
        let c = try Self.run(try Self.plan(.firefox, manifest: manifest), kind: .full)
        #expect(Self.settle(c, "browser.extension.sendRequest('hi')") == #"{"sent":["hi"]}"#)
        #expect(Self.eval(c, "browser.extension.onRequest === browser.runtime.onMessage") == "true")
        #expect(Self.eval(c, "browser.extension.getURL('a.html')") == #""chrome-extension://abcd/a.html""#)
        #expect(Self.eval(c, "(() => { browser.pageAction.show(5); return [__enabled, browser.browserAction === browser.action]; })()") == "[5,true]")
    }
}
