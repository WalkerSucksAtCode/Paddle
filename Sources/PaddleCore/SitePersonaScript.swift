import Foundation

/// The page-world script that presents `sitePersonas` to a site's JavaScript: Chrome's or Firefox's browser identity on
/// the listed hosts and their subdomains, and nothing on any other page. The user agent string is separate
/// (`PaddleConfig.pageUserAgent(forHost:)`).
///
/// One script covers every host, as `ScriptletDispatcher` does: its table maps each `sitePersonas` key (normalized)
/// to a persona name, or to "" for `none` and `native`, and the script takes the longest key covering
/// `location.hostname`. Only JSON data goes into the source; no host name becomes code. The script runs in the page's
/// own world, never an extension's.
public enum SitePersonaScript {
    /// The user script for `personas` (`PaddleConfig.sitePersonas`), or "" when no entry is Chrome or Firefox. Install
    /// it at document start in every frame, in the page world.
    public static func source(
        for personas: [String: Persona], versions: BrowserVersions = .current,
        platformVersion: String = CompatPlan.currentPlatformVersion
    ) -> String {
        guard personas.values.contains(where: { $0 == .chrome || $0 == .firefox }) else { return "" }
        let plan = Plan(
            arch: currentArchitecture, brands: Persona.chrome.brands(versions),
            fullBrands: Persona.chrome.brands(versions, full: true), chromeFull: versions.chromeFullVersion,
            platformVersion: platformVersion
        )
        return """
        // Paddle site persona (sitePersonas): generated from config.json at every load, edits are overwritten.
        (() => {
        'use strict';
        const T = new Map(\(json(hostTable(personas))));
        const P = \(json(plan));
        \(body)
        })();

        """
    }

    /// The table the script reads: each `sitePersonas` key normalized (`PaddleConfig.normalizedHost`) with its persona's
    /// name, or "" for `none` and `native`. Keys that normalize alike keep the one `sitePersona(forHost:)` would pick:
    /// the greatest by `PaddleConfig.hostKeyPrecedes`, which sorts last here and so overwrites the others.
    static func hostTable(_ personas: [String: Persona]) -> [[String]] {
        var table: [String: String] = [:]
        for (key, persona) in personas.sorted(by: { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }) {
            table[PaddleConfig.normalizedHost(key)] = persona == .chrome || persona == .firefox ? persona.rawValue : ""
        }
        return table.keys.sorted().map { [$0, table[$0] ?? ""] }
    }

    /// `hostTable` as the JSON the source embeds.
    static func tableJSON(_ personas: [String: Persona]) -> String { json(hostTable(personas)) }

    /// The persona data the script reads as `P`: Chrome's brands at the given versions, and the Mac's platform.
    private struct Plan: Encodable {
        let arch: String
        let brands: [Persona.Brand]
        let fullBrands: [Persona.Brand]
        let chromeFull: String
        let platformVersion: String
    }

    /// `arm` or `x86`, as `getHighEntropyValues` reports the Mac's architecture.
    static let currentArchitecture: String = {
        #if arch(arm64)
        return "arm"
        #else
        return "x86"
        #endif
    }()

    /// `value` as JSON text for a script literal. U+2028 and U+2029 are legal in JS strings since ES2019; escaping them
    /// costs nothing.
    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The script body, inside the closure `source` builds, where `T` (the host table) and `P` (the persona data) are
    /// defined. Every change is configurable: accessors on `Navigator.prototype`, `window.chrome`, and a
    /// `Function.prototype.toString` that answers native-looking text for the functions this script adds (`hide`).
    static let body = #"""
    try {
      const host = String(location.hostname || '').toLowerCase().replace(/\.$/, '');
      if (host === '') return;
      // The longest table key covering the host: the host itself, then each parent domain. "none" is a key too, so a
      // subdomain can opt out of its parent's persona.
      let persona = '';
      for (let h = host; h !== '';) {
        if (T.has(h)) { persona = T.get(h); break; }
        const dot = h.indexOf('.');
        h = dot < 0 ? '' : h.slice(dot + 1);
      }
      if (persona !== 'chrome' && persona !== 'firefox') return;
      const navProto = typeof Navigator === 'function' ? Navigator.prototype : null;
      if (!navProto) return;

      const nativeToString = Function.prototype.toString;
      const shown = new WeakMap();
      const hide = (fn, name) => { shown.set(fn, 'function ' + name + '() { [native code] }'); return fn; };
      const toStringFn = function toString() {
        const text = shown.get(this);
        return text !== undefined ? text : nativeToString.call(this);
      };
      hide(toStringFn, 'toString');
      Object.defineProperty(Function.prototype, 'toString', {value: toStringFn, writable: true, enumerable: false, configurable: true});
      const hideMethods = (obj) => { for (const k of Object.keys(obj)) if (typeof obj[k] === 'function') hide(obj[k], k); };
      const accessor = (obj, name, value) => {
        const get = Object.getOwnPropertyDescriptor({get [name]() { return value; }}, name).get;
        Object.defineProperty(obj, name, {get: hide(get, 'get ' + name), enumerable: true, configurable: true});
      };
      const method = (obj, name, fn) => {
        Object.defineProperty(obj, name, {value: hide(fn, name), writable: true, enumerable: true, configurable: true});
      };

      if (persona === 'chrome') {
        accessor(navProto, 'vendor', 'Google Inc.');
        const copy = (list) => Object.freeze(list.map((b) => Object.freeze({brand: b.brand, version: b.version})));
        const brands = copy(P.brands), fullVersionList = copy(P.fullBrands);
        if (window.isSecureContext) {
          // Chrome exposes userAgentData in secure contexts only.
          const uaProto = {};
          Object.defineProperty(uaProto, Symbol.toStringTag, {value: 'NavigatorUAData', configurable: true});
          accessor(uaProto, 'brands', brands);
          accessor(uaProto, 'mobile', false);
          accessor(uaProto, 'platform', 'macOS');
          const low = () => ({brands, mobile: false, platform: 'macOS'});
          const high = {architecture: P.arch, bitness: '64', fullVersionList, model: '', platformVersion: P.platformVersion,
            uaFullVersion: P.chromeFull, wow64: false, formFactors: ['Desktop']};
          const methods = {
            getHighEntropyValues(hints) {
              if (!Array.isArray(hints)) return Promise.reject(new TypeError("Failed to execute 'getHighEntropyValues' on 'NavigatorUAData': The provided value cannot be converted to a sequence."));
              const out = low();
              for (const h of hints) if (Object.prototype.hasOwnProperty.call(high, h)) out[h] = high[h];
              return Promise.resolve(out);
            },
            toJSON() { return low(); },
          };
          for (const name of Object.keys(methods)) method(uaProto, name, methods[name]);
          accessor(navProto, 'userAgentData', Object.create(uaProto));
        }
        // Chrome's five PDF viewer entries, and the two PDF types they all carry.
        const mimeTypes = ['application/pdf', 'text/pdf'].map((type) => ({type, suffixes: 'pdf', description: 'Portable Document Format', enabledPlugin: null}));
        const plugins = ['PDF Viewer', 'Chrome PDF Viewer', 'Chromium PDF Viewer', 'Microsoft Edge PDF Viewer', 'WebKit built-in PDF'].map((name) => {
          const plugin = {name, filename: 'internal-pdf-viewer', description: 'Portable Document Format', length: mimeTypes.length};
          mimeTypes.forEach((m, i) => { plugin[i] = m; });
          return plugin;
        });
        for (const m of mimeTypes) m.enabledPlugin = plugins[0];
        const listOf = (tag, items, key) => {
          const list = items.slice();
          const api = {
            item(i) { return list[i] || null; },
            namedItem(name) { return list.find((x) => x[key] === name) || null; },
          };
          for (const name of Object.keys(api)) method(list, name, api[name]);
          Object.defineProperty(list, Symbol.toStringTag, {value: tag, configurable: true});
          return Object.freeze(list);
        };
        accessor(navProto, 'plugins', listOf('PluginArray', plugins, 'name'));
        accessor(navProto, 'mimeTypes', listOf('MimeTypeArray', mimeTypes, 'type'));
        // window.chrome as Chrome has it on an ordinary page: no extension ids.
        const app = {
          isInstalled: false,
          InstallState: {DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed'},
          RunningState: {CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running'},
          getDetails() { return null; },
          getIsInstalled() { return false; },
          installState(callback) { if (typeof callback === 'function') setTimeout(() => callback('not_installed'), 0); },
          runningState() { return 'cannot_run'; },
        };
        const chromeObject = {
          app,
          runtime: {},
          loadTimes() {
            const origin = performance.timeOrigin / 1000, now = performance.now() / 1000;
            return {requestTime: origin, startLoadTime: origin, commitLoadTime: origin + now / 2, finishDocumentLoadTime: origin + now,
              finishLoadTime: origin + now, firstPaintTime: origin + now, firstPaintAfterLoadTime: 0, navigationType: 'Other',
              wasFetchedViaSpdy: false, wasNpnNegotiated: false, npnNegotiatedProtocol: 'unknown',
              wasAlternateProtocolAvailable: false, connectionInfo: 'http/1.1'};
          },
          csi() {
            const now = performance.now();
            return {onloadT: Math.round(performance.timeOrigin + now), pageT: Math.round(now), startE: Math.round(performance.timeOrigin), tran: 15};
          },
        };
        hideMethods(app);
        hideMethods(chromeObject);
        Object.defineProperty(window, 'chrome', {value: chromeObject, writable: true, enumerable: true, configurable: true});
      } else {
        // Firefox: an empty vendor, Gecko's own fields, and neither userAgentData nor window.chrome.
        accessor(navProto, 'vendor', '');
        accessor(navProto, 'appVersion', '5.0 (Macintosh)');
        accessor(navProto, 'productSub', '20100101');
        accessor(navProto, 'oscpu', 'Intel Mac OS X 10.15');
        accessor(navProto, 'buildID', '20181001000000');
        if (Object.prototype.hasOwnProperty.call(navProto, 'userAgentData')) delete navProto.userAgentData;
      }
    } catch (e) {}
    """#
}
