import Foundation

/// Everything the v2 prelude needs to know about one extension. The App builds it at every load (it carries the
/// current versions, locale and first-run state) and `CompatPrelude.source` turns it into `paddle-prelude.js`
/// (`.full`) and `paddle-content.js` (`.content`).
public struct CompatPlan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Background, popup, options, offscreen and extension-page tabs.
        case full
        /// Content scripts: JS only, no bus.
        case content
    }

    public var persona: Persona
    /// `runtime.id` (`ExtensionIdentity.Resolved.runtimeID`).
    public var runtimeID: String
    /// Already raised to the manifest's minimums (`BrowserVersions.raised(for:)`).
    public var versions: BrowserVersions
    /// The original manifest as JSON text: what `runtime.getManifest()` returns (not the overlay's patched one).
    public var manifest: String
    /// Permission names in the manifest's `permissions`.
    public var requiredPermissions: [String]
    /// Permission names in `optional_permissions`.
    public var optionalPermissions: [String]
    /// Names WebKit drops that Paddle provides (wave 5 on). Declared ones count as granted.
    public var shimmedPermissions: [String]
    /// Names Paddle grants on the context for itself (`nativeMessaging`, for the bus): hidden from the extension
    /// unless its manifest declares them.
    public var paddleGranted: [String]
    /// Names WebKit knows; any other name is answered by the prelude, never passed to WebKit (E23).
    public var webKitKnown: [String]
    /// The action popup, relative to the root (`ExtensionCompat.popupPath`).
    public var popupPath: String?
    /// The MV2 background page, relative to the root.
    public var backgroundPage: String?
    /// `ExtensionCompatConfig.shims`: off leaves only the persona.
    public var shims: Bool
    /// `i18n.getMessage("@@ui_locale")`, like `en_US`.
    public var uiLocale: String
    /// `userAgentData` `platformVersion`, like `27.0.1`.
    public var platformVersion: String
    /// Set to `"install"` for the first load of a newly installed extension (WebKit never fires it, E19); the App
    /// must clear it once that load's background has started, or every later load fires it again.
    public var installReason: String?

    public init(
        persona: Persona, runtimeID: String, versions: BrowserVersions = .current, manifest: String = "{}",
        requiredPermissions: [String] = [], optionalPermissions: [String] = [], shimmedPermissions: [String] = [],
        paddleGranted: [String] = ["nativeMessaging"], webKitKnown: [String] = ExtensionCompat.webKitPermissionNames.sorted(),
        popupPath: String? = nil, backgroundPage: String? = nil, shims: Bool = true,
        uiLocale: String = CompatPlan.currentUILocale, platformVersion: String = CompatPlan.currentPlatformVersion,
        installReason: String? = nil
    ) {
        self.persona = persona
        self.runtimeID = runtimeID
        self.versions = versions
        self.manifest = manifest
        self.requiredPermissions = requiredPermissions
        self.optionalPermissions = optionalPermissions
        self.shimmedPermissions = shimmedPermissions
        self.paddleGranted = paddleGranted
        self.webKitKnown = webKitKnown
        self.popupPath = popupPath
        self.backgroundPage = backgroundPage
        self.shims = shims
        self.uiLocale = uiLocale
        self.platformVersion = platformVersion
        self.installReason = installReason
    }

    /// A plan from the extension's original `manifest.json` bytes.
    public static func make(
        manifestData: Data, persona: Persona, runtimeID: String, compat: ExtensionCompatConfig = ExtensionCompatConfig(),
        versions: BrowserVersions = .current, shimmedPermissions: [String] = [], installReason: String? = nil
    ) throws -> CompatPlan {
        guard let root = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw ExtensionCompat.PatchError.notAnObject
        }
        let text = (try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        func names(_ key: String) -> [String] {
            ((root[key] as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { !$0.contains("/") && !$0.contains("*") && !$0.hasPrefix("<") }
        }
        let page = ((root["background"] as? [String: Any])?["page"] as? String).flatMap(ExtensionCompat.containedPath)
        return CompatPlan(
            persona: persona, runtimeID: runtimeID, versions: versions.raised(for: root), manifest: text,
            requiredPermissions: names("permissions"), optionalPermissions: names("optional_permissions"),
            shimmedPermissions: shimmedPermissions, popupPath: ExtensionCompat.popupPath(manifest: root),
            backgroundPage: page, shims: compat.shimsEnabled, installReason: installReason
        )
    }

    /// The UI locale as Chrome's `@@ui_locale` writes it: language, underscore, region.
    public static var currentUILocale: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        guard let region = locale.region?.identifier else { return language }
        return "\(language)_\(region)"
    }

    public static var currentPlatformVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// The v2 compatibility prelude: the persona (globals, `navigator`, persona-only members) and the wave-2 JS
/// stand-ins. Globals: the chrome persona defines `browser` as a non-configurable `undefined` and pins `chrome` in
/// every world (the form E11 verified); the firefox persona pins both in the full kind only and leaves a content
/// world's globals as WebKit made them.
///
/// The wave-2 rows of the plan's §5 each run in their own try/catch, so one failing section can't stop the
/// background (E24).
/// Shipped as Swift text, written into the overlay at every load.
public enum CompatPrelude {
    /// The prelude for `plan`. `none` gets the wave 4b prelude (`ExtensionCompat.prelude`) for either kind;
    /// `native` gets nothing.
    public static func source(for plan: CompatPlan, kind: CompatPlan.Kind) -> String {
        switch plan.persona {
        case .native: return ""
        case .none: return ExtensionCompat.prelude
        case .chrome, .firefox: break
        }
        let header = kind == .full
            ? "// Paddle compat prelude v2 (\(plan.persona.rawValue)); generated at every load, edits are overwritten.\n"
            : "// Paddle content prelude v2 (\(plan.persona.rawValue)); generated at every load, edits are overwritten.\n"
        return header + template.replacingOccurrences(of: "__PADDLE_PLAN__", with: embedded(plan, kind: kind))
    }

    /// The plan as the JSON object literal the template reads as `P`.
    static func embedded(_ plan: CompatPlan, kind: CompatPlan.Kind) -> String {
        struct Embedded: Encodable {
            let kind: String, persona: String, id: String
            let ua: String, vendor: String
            let brands: [Persona.Brand], fullBrands: [Persona.Brand]
            let chromeFull: String, firefox: String, arch: String, platformVersion: String
            let manifest: String
            let required: [String], optional: [String], shimmed: [String], granted: [String], known: [String]
            let popup: String?, backgroundPage: String?
            let shims: Bool, uiLocale: String, installReason: String?, contentFile: String
        }
        #if arch(arm64)
        let arch = "arm"
        #else
        let arch = "x86"
        #endif
        let v = plan.versions
        let value = Embedded(
            kind: kind.rawValue, persona: plan.persona.rawValue, id: plan.runtimeID,
            ua: plan.persona.userAgent(v) ?? "", vendor: plan.persona.vendor ?? "",
            brands: plan.persona.brands(v), fullBrands: plan.persona.brands(v, full: true),
            chromeFull: v.chromeFullVersion, firefox: v.firefoxVersion, arch: arch, platformVersion: plan.platformVersion,
            manifest: plan.manifest,
            required: plan.requiredPermissions, optional: plan.optionalPermissions, shimmed: plan.shimmedPermissions,
            granted: plan.paddleGranted, known: plan.webKitKnown,
            popup: plan.popupPath, backgroundPage: plan.backgroundPage,
            shims: plan.shims, uiLocale: plan.uiLocale, installReason: plan.installReason,
            contentFile: ExtensionCompat.contentFileName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        // U+2028/2029 are legal in JS strings since ES2019, but escaping them costs nothing.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static let template = #"""
    (() => {
      'use strict';
      const P = __PADDLE_PLAN__;
      const G = globalThis;
      const KEY = Symbol.for('paddle.compat');
      if (Object.prototype.hasOwnProperty.call(G, KEY)) return;          // once per world (E10: one run per entry)
      let ns = null;
      try { ns = G.chrome || G.browser; if (!(ns && ns.runtime && ns.runtime.id)) ns = null; } catch (e) { ns = null; }
      if (!ns) return;                                                     // a web page's own world: do nothing
      const state = {version: 2, kind: P.kind, persona: P.persona, held: [], errors: []};
      try { Object.defineProperty(G, KEY, {value: state}); } catch (e) { return; }
      // WebKit rebuilds namespace objects nothing holds, dropping what was added to them: hold every one touched.
      const hold = (o) => { if (o !== null && (typeof o === 'object' || typeof o === 'function') && !state.held.includes(o)) state.held.push(o); return o; };
      const section = (name, fn) => { try { fn(); } catch (e) { state.errors.push(name + ': ' + ((e && e.message) || String(e))); } };
      const put = (obj, name, value) => { Object.defineProperty(obj, name, {value, writable: true, configurable: true, enumerable: true}); return value; };
      const fill = (obj, name, value) => { if (obj && !(name in obj)) put(obj, name, value); };
      const full = P.kind === 'full';
      const isWindow = typeof window !== 'undefined' && typeof document !== 'undefined';
      const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined' && G instanceof ServiceWorkerGlobalScope;
      const manifest = (() => { try { return JSON.parse(P.manifest); } catch (e) { return {}; } })();
      let browserNS; try { browserNS = G.browser; } catch (e) {}
      hold(ns); hold(browserNS);
      const spaces = P.persona === 'firefox' ? [...new Set([browserNS, ns].filter(Boolean))] : [ns];
      for (const n of spaces) { try { hold(n.runtime); } catch (e) {} }

      // runtime.lastError for the callback form of Paddle's own functions.
      const pending = [];
      const lastErrorFor = new WeakSet();
      const installLastError = (rt) => {
        if (!rt || lastErrorFor.has(rt)) return;
        let owner = rt, desc;
        while (owner && !(desc = Object.getOwnPropertyDescriptor(owner, 'lastError'))) owner = Object.getPrototypeOf(owner);
        if (owner === rt && desc && !(desc.configurable && desc.get)) return;
        const nativeGet = desc ? (desc.get ? () => desc.get.call(rt) : () => desc.value) : () => undefined;
        Object.defineProperty(rt, 'lastError', {configurable: true, enumerable: true, get() { return pending.length ? pending[pending.length - 1] : nativeGet(); }});
        lastErrorFor.add(rt);
      };
      const withLastError = (e, fn) => { pending.push({message: (e && e.message) || String(e)}); try { fn(); } finally { pending.pop(); } };
      // A function in both forms: a trailing callback gets the result (or lastError), otherwise a promise.
      const callbackForm = (impl) => function (...args) {
        const cb = args.length && typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const p = new Promise((resolve) => resolve(impl.apply(this, args)));
        if (!cb) return p;
        p.then((v) => { cb(v); }, (e) => { withLastError(e, () => cb()); });
      };
      const later = (fn) => { if (typeof setTimeout === 'function') setTimeout(fn, 0); else Promise.resolve().then(fn); };
      const makeEvent = () => {
        const listeners = new Set();
        const event = hold({
          addListener(l) { if (typeof l === 'function') listeners.add(l); },
          removeListener(l) { listeners.delete(l); },
          hasListener(l) { return listeners.has(l); },
          hasListeners() { return listeners.size > 0; },
        });
        return event;
      };

      // MARK: persona
      // Content worlds keep WebKit's own `browser` and `chrome` for both personas: a pin to another value there (a
      // writable undefined `browser` beside a pinned `chrome`) loses tabs.sendMessage replies (E11 and its re-run).
      // They are locked to WebKit's own objects, though: WebKit delivers runtime.onMessage to a content world through
      // that world's `browser` global, so a content script that swaps it out (Proton Pass replaces both with a
      // Proxy that answers nothing, to keep pages away from the API) stops receiving tabs.sendMessage at all, and its
      // autofill click fills nothing (seen live, 2026-10-13). The setter ignores the write, so the swap and a
      // `browser = chrome` polyfill both find `browser` unchanged and working.
      section('content.globals', () => {
        if (full || !isWindow) return;
        for (const k of ['browser', 'chrome']) {
          let v; try { v = G[k]; } catch (e) {}
          if (!v) continue;
          try { Object.defineProperty(G, k, {get: () => v, set: () => {}, enumerable: true, configurable: false}); }
          catch (e) { state.errors.push('content.' + k + ': ' + e.message); }
        }
      });
      section('persona.globals', () => {
        if (!full) return;
        if (P.persona === 'chrome') {
          const c = ns;
          // Extension pages and the background: `browser` is an own, non-configurable, undefined property (not
          // deleted, which E11 showed comes back), writable so an extension's own `browser = chrome` polyfill works.
          // WebKit leaves it undefined in a worker (E11 re-run: still undefined after 4 s).
          try { Object.defineProperty(G, 'browser', {value: undefined, writable: true, enumerable: false, configurable: false}); }
          catch (e) { state.errors.push('persona.browser: ' + e.message); }
          Object.defineProperty(G, 'chrome', {get: () => c, set: () => {}, enumerable: true, configurable: false});
        } else {
          let c; try { c = G.chrome; } catch (e) {}
          const b = browserNS || ns;
          c = c || b;
          for (const [k, v] of [['browser', b], ['chrome', c]]) {
            try { Object.defineProperty(G, k, {get: () => v, set: () => {}, enumerable: true, configurable: false}); }
            catch (e) { state.errors.push('persona.' + k + ': ' + e.message); }
          }
        }
      });
      section('persona.navigator', () => {
        const nav = G.navigator;
        if (!nav) return;
        const proto = Object.getPrototypeOf(nav);                          // Navigator or WorkerNavigator
        if (!proto || proto === Object.prototype) return;
        hold(proto);
        const value = (name, v) => Object.defineProperty(proto, name, {get: () => v, configurable: true, enumerable: true});
        value('userAgent', P.ua);
        value('vendor', P.vendor);
        if (P.persona === 'chrome') {
          value('appVersion', P.ua.replace(/^Mozilla\//, ''));
          const copy = (list) => Object.freeze(list.map((b) => Object.freeze({brand: b.brand, version: b.version})));
          const brands = copy(P.brands), fullVersionList = copy(P.fullBrands);
          const low = () => ({brands, mobile: false, platform: 'macOS'});
          const high = {architecture: P.arch, bitness: '64', fullVersionList, model: '', platformVersion: P.platformVersion,
                        uaFullVersion: P.chromeFull, wow64: false, formFactors: ['Desktop']};
          const data = hold({
            brands, mobile: false, platform: 'macOS',
            getHighEntropyValues(hints) {
              if (!Array.isArray(hints)) return Promise.reject(new TypeError("Failed to execute 'getHighEntropyValues' on 'NavigatorUAData': The provided value cannot be converted to a sequence."));
              const out = low();
              for (const h of hints) if (Object.prototype.hasOwnProperty.call(high, h)) out[h] = high[h];
              return Promise.resolve(out);
            },
            toJSON() { return low(); },
          });
          value('userAgentData', data);
        } else {
          value('appVersion', '5.0 (Macintosh)');
          value('oscpu', 'Intel Mac OS X 10.15');
          value('buildID', '20181001000000');
          value('productSub', '20100101');
        }
      });
      section('persona.members', () => {
        if (P.persona === 'chrome') {
          if (isWindow) fill(ns, 'app', hold({
            isInstalled: false,
            getDetails() { return null; },
            getIsInstalled() { return false; },
            installState(cb) { if (typeof cb === 'function') later(() => cb('not_installed')); },
            runningState() { return 'cannot_run'; },
            InstallState: {DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed'},
            RunningState: {CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running'},
          }));
        } else if (full) {
          for (const n of spaces) fill(n.runtime, 'getBrowserInfo', callbackForm(() => ({name: 'Firefox', vendor: 'Mozilla', version: P.firefox, buildID: '20181001000000'})));
        }
      });
      // WebKit ships requestIdleCallback switched off; Proton Pass's form detector needs it (wave 4b).
      section('requestIdleCallback', () => {
        if (!isWindow || typeof G.requestIdleCallback === 'function') return;
        G.requestIdleCallback = (cb) => setTimeout(() => { const s = performance.now(); cb({didTimeout: false, timeRemaining: () => Math.max(0, 50 - (performance.now() - s))}); }, 1);
        G.cancelIdleCallback = (id) => clearTimeout(id);
      });

      if (!P.shims) return;

      // MARK: shims (wave 2: JS only)
      section('lastError', () => { if (full) for (const n of spaces) installLastError(n.runtime); });

      section('event.hasListeners', () => {
        const sample = ns.runtime.onMessage;
        if (!sample || typeof sample.hasListeners === 'function') return;
        const proto = Object.getPrototypeOf(sample);
        if (!proto || proto === Object.prototype || typeof proto.addListener !== 'function') return;
        hold(proto);
        const seen = new WeakMap();
        const of = (ev) => { let s = seen.get(ev); if (!s) seen.set(ev, s = new Set()); return s; };
        const add = proto.addListener, remove = proto.removeListener;
        put(proto, 'addListener', function addListener(l, ...rest) { const r = add.call(this, l, ...rest); if (typeof l === 'function') of(this).add(l); return r; });
        if (typeof remove === 'function') put(proto, 'removeListener', function removeListener(l, ...rest) { const r = remove.call(this, l, ...rest); of(this).delete(l); return r; });
        put(proto, 'hasListeners', function hasListeners() { return of(this).size > 0; });
      });

      section('runtime.events', () => {
        if (!full) return;
        for (const n of spaces) {
          const rt = n.runtime;
          for (const name of ['onUpdateAvailable', 'onSuspend', 'onSuspendCanceled', 'onRestartRequired', 'onConnectExternal', 'onMessageExternal']) {
            if (!rt[name]) put(rt, name, makeEvent());
          }
          fill(rt, 'restart', callbackForm(() => undefined));
          fill(rt, 'restartAfterDelay', callbackForm(() => undefined));
          fill(rt, 'requestUpdateCheck', callbackForm(() => ({status: 'no_update'})));
        }
      });

      const CONTEXT_TYPE = {ALL: 'all', PAGE: 'page', FRAME: 'frame', SELECTION: 'selection', LINK: 'link', EDITABLE: 'editable', IMAGE: 'image', VIDEO: 'video', AUDIO: 'audio', LAUNCHER: 'launcher', BROWSER_ACTION: 'browser_action', PAGE_ACTION: 'page_action', ACTION: 'action'};
      const MENUS = {ACTION_MENU_TOP_LEVEL_LIMIT: 6, ContextType: CONTEXT_TYPE, ItemType: {NORMAL: 'normal', CHECKBOX: 'checkbox', RADIO: 'radio', SEPARATOR: 'separator'}};
      const WINDOW_TYPE = {NORMAL: 'normal', POPUP: 'popup', PANEL: 'panel', APP: 'app', DEVTOOLS: 'devtools'};
      const ENUMS = {
        runtime: {
          OnInstalledReason: P.persona === 'firefox'
            ? {INSTALL: 'install', UPDATE: 'update', BROWSER_UPDATE: 'browser_update', SHARED_MODULE_UPDATE: 'shared_module_update'}
            : {INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update'},
          OnRestartRequiredReason: {APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic'},
          PlatformArch: {ARM: 'arm', ARM64: 'arm64', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64', RISCV64: 'riscv64'},
          PlatformNaclArch: {ARM: 'arm', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64'},
          PlatformOs: {MAC: 'mac', WIN: 'win', ANDROID: 'android', CROS: 'cros', LINUX: 'linux', OPENBSD: 'openbsd', FUCHSIA: 'fuchsia'},
          RequestUpdateCheckStatus: {THROTTLED: 'throttled', NO_UPDATE: 'no_update', UPDATE_AVAILABLE: 'update_available'},
          ContextType: {TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS'},
        },
        tabs: {
          TAB_ID_NONE: -1, TAB_INDEX_NONE: -1, MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2,
          TabStatus: {UNLOADED: 'unloaded', LOADING: 'loading', COMPLETE: 'complete'},
          MutedInfoReason: {USER: 'user', CAPTURE: 'capture', EXTENSION: 'extension'},
          WindowType: WINDOW_TYPE,
          ZoomSettingsMode: {AUTOMATIC: 'automatic', MANUAL: 'manual', DISABLED: 'disabled'},
          ZoomSettingsScope: {PER_ORIGIN: 'per-origin', PER_TAB: 'per-tab'},
        },
        windows: {
          WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2, WindowType: WINDOW_TYPE,
          WindowState: {NORMAL: 'normal', MINIMIZED: 'minimized', MAXIMIZED: 'maximized', FULLSCREEN: 'fullscreen', LOCKED_FULLSCREEN: 'locked-fullscreen'},
          CreateType: {NORMAL: 'normal', POPUP: 'popup', PANEL: 'panel'},
        },
        scripting: {ExecutionWorld: {ISOLATED: 'ISOLATED', MAIN: 'MAIN'}, StyleOrigin: {AUTHOR: 'AUTHOR', USER: 'USER'}},
        declarativeNetRequest: {
          DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session', GUARANTEED_MINIMUM_STATIC_RULES: 30000,
          MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_SESSION_RULES: 5000,
          MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_STATIC_RULESETS: 100,
          MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50, MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
          RuleActionType: {BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests'},
          ResourceType: {MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other'},
          DomainType: {FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty'},
          HeaderOperation: {APPEND: 'append', SET: 'set', REMOVE: 'remove'},
          RequestMethod: {CONNECT: 'connect', DELETE: 'delete', GET: 'get', HEAD: 'head', OPTIONS: 'options', PATCH: 'patch', POST: 'post', PUT: 'put', OTHER: 'other'},
          UnsupportedRegexReason: {SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded'},
        },
        contextMenus: MENUS,
        menus: MENUS,
        extension: {ViewType: {TAB: 'tab', POPUP: 'popup'}},
        webNavigation: {
          TransitionType: {LINK: 'link', TYPED: 'typed', AUTO_BOOKMARK: 'auto_bookmark', AUTO_SUBFRAME: 'auto_subframe', MANUAL_SUBFRAME: 'manual_subframe', GENERATED: 'generated', START_PAGE: 'start_page', FORM_SUBMIT: 'form_submit', RELOAD: 'reload', KEYWORD: 'keyword', KEYWORD_GENERATED: 'keyword_generated'},
          TransitionQualifier: {CLIENT_REDIRECT: 'client_redirect', SERVER_REDIRECT: 'server_redirect', FORWARD_BACK: 'forward_back', FROM_ADDRESS_BAR: 'from_address_bar'},
        },
        cookies: {SameSiteStatus: {NO_RESTRICTION: 'no_restriction', LAX: 'lax', STRICT: 'strict', UNSPECIFIED: 'unspecified'}},
        storage: {AccessLevel: {TRUSTED_CONTEXTS: 'TRUSTED_CONTEXTS', TRUSTED_AND_UNTRUSTED_CONTEXTS: 'TRUSTED_AND_UNTRUSTED_CONTEXTS'}},
      };
      for (const [space, members] of Object.entries(ENUMS)) {
        section('enums.' + space, () => {
          for (const n of spaces) {
            const target = n[space];
            if (!target) continue;
            hold(target);
            for (const [name, value] of Object.entries(members)) fill(target, name, value);
          }
        });
      }

      section('getManifest', () => {
        for (const n of spaces) put(n.runtime, 'getManifest', function getManifest() { return JSON.parse(P.manifest); });
      });

      section('i18n', () => {
        for (const n of spaces) {
          const i18n = n.i18n;
          if (!i18n || typeof i18n.getMessage !== 'function') continue;
          hold(i18n);
          const original = i18n.getMessage;
          put(i18n, 'getMessage', function getMessage(name, ...rest) {
            if (name === '@@ui_locale') {
              let v;
              try { v = original.call(i18n, name, ...rest); } catch (e) {}
              return v || P.uiLocale;
            }
            return original.call(i18n, name, ...rest);
          });
        }
      });

      section('extension', () => {
        if (manifest.manifest_version !== 2) return;
        for (const n of spaces) {
          const rt = n.runtime;
          const ext = hold(n.extension || put(n, 'extension', {}));
          fill(ext, 'sendRequest', (...a) => rt.sendMessage(...a));
          fill(ext, 'onRequest', rt.onMessage);
          fill(ext, 'onRequestExternal', rt.onMessageExternal || makeEvent());
          fill(ext, 'getURL', (path) => rt.getURL(path));
          fill(ext, 'inIncognitoContext', false);
        }
      });

      if (!full) return;

      section('permissions', () => {
        const required = new Set(P.required), declared = new Set(P.required.concat(P.optional));
        const shimmed = new Set(P.shimmed), known = new Set(P.known);
        const hidden = new Set(P.granted.filter((x) => !declared.has(x)));
        // Each requested name: 'hide' (Paddle's own grant), 'shim' (Paddle answers yes), 'no', or 'webkit'.
        const judge = (x) => hidden.has(x) ? 'hide' : known.has(x) ? 'webkit' : (shimmed.has(x) && required.has(x)) ? 'shim' : 'no';
        const split = (q) => {
          q = q || {};
          const names = Array.isArray(q.permissions) ? q.permissions : [];
          const verdicts = names.map(judge);
          const rest = names.filter((x, i) => verdicts[i] === 'webkit');
          const origins = Array.isArray(q.origins) ? q.origins : [];
          return {verdicts, origins, query: Object.assign({}, q, {permissions: rest}), empty: !rest.length && !origins.length};
        };
        for (const n of spaces) {
          const perms = n.permissions;
          if (!perms) continue;
          hold(perms);
          const getAll = perms.getAll, contains = perms.contains, request = perms.request, remove = perms.remove;
          if (typeof getAll === 'function') put(perms, 'getAll', callbackForm(async () => {
            const r = (await getAll.call(perms)) || {};
            const names = (r.permissions || []).filter((x) => !hidden.has(x));
            for (const x of P.shimmed) if (required.has(x) && !names.includes(x)) names.push(x);
            return Object.assign({}, r, {permissions: names, origins: r.origins || []});
          }));
          if (typeof contains === 'function') put(perms, 'contains', callbackForm((q) => {
            const s = split(q);
            if (s.verdicts.some((v) => v === 'hide' || v === 'no')) return false;
            if (s.empty) return true;
            return Promise.resolve(contains.call(perms, s.query)).then((v) => !!v);
          }));
          // No await before WebKit's request: it must run inside the user gesture.
          if (typeof request === 'function') put(perms, 'request', callbackForm((q) => {
            const s = split(q);
            if (s.verdicts.includes('hide')) throw new Error('Only permissions specified in the manifest may be requested.');
            if (s.verdicts.includes('no')) return false;
            if (s.empty) return true;
            return Promise.resolve(request.call(perms, s.query)).then((v) => !!v);
          }));
          if (typeof remove === 'function') put(perms, 'remove', callbackForm((q) => {
            const s = split(q);
            if (s.empty) return false;
            return Promise.resolve(remove.call(perms, s.query)).then((v) => !!v);
          }));
        }
      });

      section('action', () => {
        for (const n of spaces) {
          for (const action of [...new Set([n.action, n.browserAction].filter(Boolean))]) {
            hold(action);
            fill(action, 'getUserSettings', callbackForm(() => ({isOnToolbar: true})));
            if (!('setBadgeTextColor' in action)) {
              const colors = new Map();                                    // stored only: WebKit draws its own badge
              const key = (d) => (d && d.tabId != null ? d.tabId : -1);
              put(action, 'setBadgeTextColor', callbackForm((d) => { colors.set(key(d), d && d.color); }));
              put(action, 'getBadgeTextColor', callbackForm((d) => colors.get(key(d)) ?? colors.get(-1) ?? [255, 255, 255, 255]));
            }
          }
          const action = n.action;
          if (action && manifest.page_action && !n.pageAction) {
            const call = (name) => (...a) => action[name](...a);
            put(n, 'pageAction', hold({
              show: call('enable'), hide: call('disable'), isShown: call('isEnabled'),
              setTitle: call('setTitle'), getTitle: call('getTitle'), setIcon: call('setIcon'),
              setPopup: call('setPopup'), getPopup: call('getPopup'), openPopup: call('openPopup'),
              onClicked: action.onClicked,
            }));
          }
          if (action && manifest.manifest_version === 2 && !n.browserAction) put(n, 'browserAction', action);
        }
      });

      const isPopup = () => {
        try {
          const ext = ns.extension;
          if (ext && typeof ext.getViews === 'function') {
            const popups = ext.getViews({type: 'popup'});
            if (Array.isArray(popups) && popups.includes(G)) return true;
            const tabs = ext.getViews({type: 'tab'});
            if (Array.isArray(tabs) && tabs.includes(G)) return false;
          }
        } catch (e) {}
        if (!P.popup || !isWindow) return false;
        let path = '';
        try { path = decodeURIComponent(location.pathname).replace(/^\/+/, ''); } catch (e) {}
        return path === P.popup;
      };
      section('tabs.getCurrent', () => {
        if (!isWindow) return;
        for (const n of spaces) {
          const tabs = n.tabs;
          if (!tabs || typeof tabs.getCurrent !== 'function') continue;
          hold(tabs);
          const original = tabs.getCurrent;
          put(tabs, 'getCurrent', function getCurrent(...args) {
            if (!isPopup()) return original.apply(tabs, args);
            const cb = args.length && typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
            if (cb) { later(() => cb(undefined)); return; }
            return Promise.resolve(undefined);
          });
        }
      });

      section('storage.managed', () => {
        for (const n of spaces) {
          const storage = n.storage;
          if (!storage || storage.managed) continue;
          hold(storage);
          const readOnly = () => { throw new Error('This is a read-only store.'); };
          put(storage, 'managed', hold({
            get: callbackForm(() => ({})), getBytesInUse: callbackForm(() => 0), getKeys: callbackForm(() => []),
            set: callbackForm(readOnly), remove: callbackForm(readOnly), clear: callbackForm(readOnly),
            setAccessLevel: callbackForm(readOnly), onChanged: makeEvent(),
          }));
        }
      });

      // E10: the content prelude first, as its own call, so the original call's result array is unchanged.
      section('executeScript', () => {
        for (const n of spaces) {
          const scripting = n.scripting;
          if (scripting && typeof scripting.executeScript === 'function') {
            hold(scripting);
            const original = scripting.executeScript;
            put(scripting, 'executeScript', callbackForm(async (injection) => {
              if (injection && injection.target && String(injection.world || 'ISOLATED').toUpperCase() !== 'MAIN') {
                const first = {target: injection.target, files: [P.contentFile]};
                if (injection.injectImmediately !== undefined) first.injectImmediately = injection.injectImmediately;
                try { await original.call(scripting, first); } catch (e) {}
              }
              return original.call(scripting, injection);
            }));
          }
          const tabs = n.tabs;
          if (manifest.manifest_version === 2 && tabs && typeof tabs.executeScript === 'function') {
            hold(tabs);
            const original = tabs.executeScript;
            put(tabs, 'executeScript', callbackForm(async (...a) => {
              const tabArgs = typeof a[0] === 'number' ? [a[0]] : [];
              const details = a[tabArgs.length];
              if (details && (details.file || details.code)) {
                const first = {file: '/' + P.contentFile};
                for (const k of ['allFrames', 'frameId', 'matchAboutBlank', 'runAt']) if (details[k] !== undefined) first[k] = details[k];
                try { await original.call(tabs, ...tabArgs, first); } catch (e) {}
              }
              return original.apply(tabs, a);
            }));
          }
        }
      });

      // E19: WebKit never fires onInstalled with 'install'; Paddle says when this is the first load.
      section('onInstalled', () => {
        if (!P.installReason) return;
        let background = isWorker;
        try { if (!background && ns.extension && typeof ns.extension.getBackgroundPage === 'function') background = ns.extension.getBackgroundPage() === G; } catch (e) {}
        if (!background && isWindow && P.backgroundPage) {
          try { background = decodeURIComponent(location.pathname).replace(/^\/+/, '') === P.backgroundPage; } catch (e) {}
        }
        if (!background) return;
        const seen = [];
        let fired = false;
        for (const n of spaces) {
          const event = n.runtime.onInstalled;
          if (!event || typeof event.addListener !== 'function') continue;
          hold(event);
          const add = event.addListener;
          put(event, 'addListener', function addListener(l, ...rest) {
            if (!fired && typeof l === 'function' && !seen.some((s) => s[1] === l)) seen.push([event, l]);
            return add.call(event, l, ...rest);
          });
        }
        later(() => {
          fired = true;
          for (const [event, l] of seen) {
            let still = true;
            try { still = event.hasListener(l); } catch (e) {}
            if (still) try { l({reason: P.installReason}); } catch (e) { later(() => { throw e; }); }
          }
        });
      });
    })();

    """#
}
