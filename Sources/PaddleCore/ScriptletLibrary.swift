import Foundation

/// Paddle's own JavaScript for each `ScriptletName`, written from uBlock Origin's documented behaviour (not its
/// source). A list's arguments are untrusted strings: they reach JavaScript only as one JSON-encoded array literal,
/// passed to the scriptlet function, never spliced into code.
///
/// Each script is meant for the page world at document start (a `WKUserScript`, `.atDocumentStart`, `.page`). It is
/// an IIFE holding the shared helpers it needs and the scriptlet function; everything runs inside try/catch, so a bad
/// argument or a missing API makes it return quietly instead of throwing into the page.
public enum ScriptletLibrary {
    /// A complete script: helpers, the scriptlet function, and the call with `arguments` as JSON string literals.
    public static func source(for name: ScriptletName, arguments: [String]) -> String {
        """
        (function () {
        'use strict';
        try {
        \(prelude(for: name))
        const scriptlet = \(body(for: name));
        scriptlet.apply(null, \(jsonArray(arguments)));
        } catch (e) {}
        })();

        """
    }

    /// The helper declarations `body(for:)` expects in scope (the core block plus the ones this scriptlet uses).
    public static func prelude(for name: ScriptletName) -> String {
        ([Helper.core] + helpers(for: name)).map(\.source).joined(separator: "\n")
    }

    /// The scriptlet's function expression. It refers to helpers from `prelude(for:)`.
    public static func body(for name: ScriptletName) -> String {
        switch name {
        case .setConstant: setConstant
        case .abortOnPropertyRead: abortOnPropertyRead
        case .abortOnPropertyWrite: abortOnPropertyWrite
        case .abortCurrentScript: abortCurrentScript
        case .abortOnStackTrace: abortOnStackTrace
        case .noSetTimeoutIf: noTimerIf.replacingOccurrences(of: "__TIMER__", with: "setTimeout")
        case .noSetIntervalIf: noTimerIf.replacingOccurrences(of: "__TIMER__", with: "setInterval")
        case .addEventListenerDefuser: addEventListenerDefuser
        case .jsonPrune: jsonPrune
        case .jsonPruneFetchResponse: jsonPruneFetchResponse
        case .jsonPruneXHRResponse: jsonPruneXHRResponse
        case .noFetchIf: noFetchIf
        case .noXHRIf: noXHRIf
        case .noEvalIf: noEvalIf
        case .noWindowOpenIf: noWindowOpenIf
        case .removeAttr: removeAttr
        case .removeClass: removeClass
        case .removeNodeText: removeNodeText
        case .nanoSetIntervalBooster: timerBooster.replacingOccurrences(of: "__TIMER__", with: "setInterval")
        case .nanoSetTimeoutBooster: timerBooster.replacingOccurrences(of: "__TIMER__", with: "setTimeout")
        case .noWebRTC: noWebRTC
        }
    }

    /// The arguments as a JSON array of strings: the only way list text enters a script.
    static func jsonArray(_ arguments: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    enum Helper {
        case core, chain, delay, prune, request, dom

        var source: String {
            switch self {
            case .core: ScriptletLibrary.coreHelpers
            case .chain: ScriptletLibrary.chainHelpers
            case .delay: ScriptletLibrary.delayHelpers
            case .prune: ScriptletLibrary.pruneHelpers
            case .request: ScriptletLibrary.requestHelpers
            case .dom: ScriptletLibrary.domHelpers
            }
        }
    }

    static func helpers(for name: ScriptletName) -> [Helper] {
        switch name {
        case .setConstant, .abortOnPropertyRead, .abortOnPropertyWrite, .abortCurrentScript, .abortOnStackTrace: [.chain]
        case .noSetTimeoutIf, .noSetIntervalIf: [.delay]
        case .jsonPrune: [.prune]
        case .jsonPruneFetchResponse, .jsonPruneXHRResponse: [.prune, .request]
        case .noFetchIf, .noXHRIf: [.request]
        case .removeAttr, .removeClass: [.dom]
        case .addEventListenerDefuser, .noEvalIf, .noWindowOpenIf, .removeNodeText, .nanoSetIntervalBooster,
             .nanoSetTimeoutBooster, .noWebRTC: []
        }
    }

    /// Natives captured before page scripts run; the needle matcher (`/regex/flags`, leading `!` negates, otherwise a
    /// literal substring, or the whole string when `exact`); function text; and Proxy-wrapping a method.
    static let coreHelpers = #"""
    const P = {
      apply: Reflect.apply, defineProperty: Object.defineProperty, getOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
      keys: Object.keys, hasOwn: Object.prototype.hasOwnProperty, Proxy: window.Proxy, RegExp: window.RegExp,
      Error: window.Error, ReferenceError: window.ReferenceError, Promise: window.Promise, then: Promise.prototype.then,
      fnToString: Function.prototype.toString, JSONParse: JSON.parse, JSONStringify: JSON.stringify,
      setTimeout: window.setTimeout, URL: window.URL,
    };
    const isObj = v => v !== null && (typeof v === 'object' || typeof v === 'function');
    const noop = function () {};
    function matcher(raw, exact) {
      let s = raw === undefined ? '' : String(raw), not = false;
      if (s.charAt(0) === '!') { not = true; s = s.slice(1); }
      let re = /^/;
      if (s !== '') {
        // `/re/flags` only with real regex flags, so a path-like needle such as `/ads/banner` stays a substring.
        const m = /^\/(.+)\/([dgimsuvy]*)$/.exec(s);
        if (m) re = new P.RegExp(m[1], m[2].replace(/[gy]/g, ''));
        else {
          const escaped = s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          re = new P.RegExp(exact ? '^' + escaped + '$' : escaped);
        }
      }
      return { empty: s === '', not, test: t => re.test(String(t)) !== not };
    }
    function fnText(f) {
      try { return typeof f === 'function' ? P.apply(P.fnToString, f, []) : String(f); } catch (e) { return ''; }
    }
    function wrapApply(owner, prop, trap) {
      const target = owner[prop];
      if (typeof target !== 'function') return false;
      owner[prop] = new P.Proxy(target, { apply: trap });
      return true;
    }
    """#

    /// Property-chain traps that wait for missing parents (`a.b.c` where `a` doesn't exist yet), and the abort error
    /// (a ReferenceError whose uncaught report is suppressed).
    static let chainHelpers = #"""
    function onChain(root, chain, leaf) {
      const dot = chain.indexOf('.');
      if (dot === -1) { if (chain !== '') leaf(root, chain); return; }
      const prop = chain.slice(0, dot), rest = chain.slice(dot + 1);
      if (prop === '' || rest === '') return;
      const current = root[prop];
      if (isObj(current)) { onChain(current, rest, leaf); return; }
      const desc = P.getOwnPropertyDescriptor(root, prop);
      if (desc && desc.configurable === false) return;
      const oldGet = desc && desc.get, oldSet = desc && desc.set;
      let value = current;
      P.defineProperty(root, prop, {
        configurable: true, enumerable: desc ? desc.enumerable : true,
        get() { return oldGet ? P.apply(oldGet, this, []) : value; },
        set(v) {
          if (oldSet) P.apply(oldSet, this, [v]); else value = v;
          if (isObj(v)) { try { onChain(v, rest, leaf); } catch (e) {} }
        },
      });
    }
    let abortMagic;
    function abortError() {
      if (abortMagic === undefined) {
        abortMagic = 'paddle-abort-' + Math.random().toString(36).slice(2);
        const magic = abortMagic;
        window.addEventListener('error', e => { if (String(e.message).includes(magic)) e.preventDefault(); }, true);
      }
      return new P.ReferenceError(abortMagic);
    }
    function guardLeaf(check) {
      return (owner, prop) => {
        const desc = P.getOwnPropertyDescriptor(owner, prop);
        if (desc && desc.configurable === false) return;
        const oldGet = desc && desc.get, oldSet = desc && desc.set;
        let value = desc ? desc.value : owner[prop];
        P.defineProperty(owner, prop, {
          configurable: true, enumerable: desc ? desc.enumerable : true,
          get() { check(); return oldGet ? P.apply(oldGet, this, []) : value; },
          set(v) { check(); if (oldSet) P.apply(oldSet, this, [v]); else value = v; },
        });
      };
    }
    """#

    /// A delay test: `N` exact, `<N`, `>N`, `N-M`, each negatable with a leading `!`; empty matches any delay.
    static let delayHelpers = #"""
    function delayMatcher(raw) {
      let s = String(raw === undefined ? '' : raw).trim(), not = false;
      if (s === '') return { empty: true, test: () => true };
      if (s.charAt(0) === '!') { not = true; s = s.slice(1); }
      let m, test;
      if ((m = /^(\d+)-(\d+)$/.exec(s))) { const lo = +m[1], hi = +m[2]; test = d => d >= lo && d <= hi; }
      else if ((m = /^([<>])(\d+)$/.exec(s))) { const n = +m[2]; test = m[1] === '<' ? d => d < n : d => d > n; }
      else if (/^\d+$/.test(s)) { const n = +s; test = d => d === n; }
      else return null;
      return { empty: false, test: d => test(Number(d) || 0) !== not };
    }
    """#

    /// JSON pruning: space-separated dotted paths; a `[]` segment means every key or array item at that level.
    static let pruneHelpers = #"""
    function pathOwners(node, segs, i, out) {
      if (!isObj(node)) return;
      const seg = segs[i];
      const keys = seg === '[]' ? P.keys(node) : [seg];
      for (const k of keys) {
        if (i === segs.length - 1) { if (P.apply(P.hasOwn, node, [k])) out.push([node, k]); }
        else pathOwners(node[k], segs, i + 1, out);
      }
    }
    function makePruner(rawPrune, rawNeed) {
      const split = s => String(s === undefined ? '' : s).split(/\s+/).filter(p => p !== '').map(p => p.split('.'));
      const prune = split(rawPrune), need = split(rawNeed);
      if (prune.length === 0) return null;
      return obj => {
        if (!isObj(obj)) return false;
        for (const segs of need) { const found = []; pathOwners(obj, segs, 0, found); if (found.length === 0) return false; }
        let changed = false;
        for (const segs of prune) {
          const found = [];
          pathOwners(obj, segs, 0, found);
          for (const [owner, key] of found) { try { if (delete owner[key]) changed = true; } catch (e) {} }
        }
        return changed;
      };
    }
    """#

    /// Request needles: space-separated `prop:value` tokens over a request's details (a token without a known prop,
    /// such as a plain URL piece, tests the URL; `*` matches any request). All tokens must match.
    static let requestHelpers = #"""
    const requestKeys = ['url', 'method', 'body', 'mode', 'credentials', 'cache', 'redirect', 'referrer', 'referrerPolicy', 'integrity', 'keepalive'];
    function requestMatcher(raw) {
      const tests = [];
      for (const token of String(raw === undefined ? '' : raw).split(/\s+/)) {
        if (token === '') continue;
        const i = token.indexOf(':');
        let key = 'url', value = token;
        if (i > 0 && requestKeys.includes(token.slice(0, i))) { key = token.slice(0, i); value = token.slice(i + 1); }
        tests.push([key, matcher(value === '*' ? '' : value)]);
      }
      if (tests.length === 0) return null;
      return details => tests.every(([k, m]) => m.test(details[k] === undefined ? '' : details[k]));
    }
    function absoluteURL(u) {
      try { return new P.URL(String(u), document.baseURI).href; } catch (e) { return String(u); }
    }
    function fetchDetails(args) {
      const d = {}, input = args[0], init = args[1];
      if (input instanceof window.Request) {
        for (const k of requestKeys) { try { const v = input[k]; if (!isObj(v) && v !== undefined) d[k] = String(v); } catch (e) {} }
      } else d.url = String(input);
      if (isObj(init)) {
        for (const k of requestKeys) { if (k !== 'url' && init[k] !== undefined && !isObj(init[k])) d[k] = String(init[k]); }
      }
      d.url = absoluteURL(d.url);
      if (d.method === undefined) d.method = 'GET';
      d.method = d.method.toUpperCase();
      return d;
    }
    function optionPairs(rest) {
      const out = {};
      for (let i = 0; i + 1 < rest.length; i += 2) out[String(rest[i])] = String(rest[i + 1]);
      return out;
    }
    """#

    /// Runs `fn` when `behavior` says: `asap` now, `complete` at load, otherwise at DOMContentLoaded.
    static let domHelpers = #"""
    function runAt(behavior, fn) {
      const when = /\bcomplete\b/.test(behavior) ? 'complete' : /\basap\b/.test(behavior) ? 'asap' : 'interactive';
      const state = document.readyState;
      if (when === 'asap' || state === 'complete' || (when === 'interactive' && state === 'interactive')) { fn(); return; }
      const target = when === 'complete' ? window : document;
      const type = when === 'complete' ? 'load' : 'DOMContentLoaded';
      target.addEventListener(type, function once() { target.removeEventListener(type, once, true); fn(); }, true);
    }
    function stripLater(behavior, names, strip) {
      strip();
      const observer = new MutationObserver(strip);
      observer.observe(document, { attributes: true, attributeFilter: names, childList: true, subtree: true });
      if (/\bstay\b/.test(behavior)) return;
      if (document.readyState === 'complete') observer.disconnect();
      else window.addEventListener('load', () => observer.disconnect(), { once: true, capture: true });
    }
    """#

    // MARK: - Scriptlets

    /// Skipped: uBO's extra `as, function|callback|resolved|rejected` and `runAt` options; quoted literal strings.
    static let setConstant = #"""
    function (chain, raw) {
      chain = String(chain === undefined ? '' : chain);
      raw = String(raw === undefined ? '' : raw);
      if (chain === '') return;
      let value;
      switch (raw) {
        case 'undefined': value = undefined; break;
        case 'true': value = true; break;
        case 'false': value = false; break;
        case 'null': value = null; break;
        case "''": value = ''; break;
        case 'yes': case 'no': value = raw; break;
        case 'NaN': value = NaN; break;
        case 'Infinity': value = Infinity; break;
        case 'noopFunc': value = function () {}; break;
        case 'trueFunc': value = function () { return true; }; break;
        case 'falseFunc': value = function () { return false; }; break;
        case 'throwFunc': value = function () { throw ''; }; break;
        case 'noopCallbackFunc': value = function () { return function () {}; }; break;
        case 'emptyObj': case '{}': value = {}; break;
        case 'emptyArr': case '[]': value = []; break;
        default:
          if (!/^-?\d+$/.test(raw)) return;
          value = parseInt(raw, 10);
          if (isNaN(value) || Math.abs(value) > 0x7FFF) return;
      }
      onChain(window, chain, (owner, prop) => {
        const desc = P.getOwnPropertyDescriptor(owner, prop);
        if (desc && desc.configurable === false) return;
        P.defineProperty(owner, prop, {
          configurable: true, enumerable: desc ? desc.enumerable : true,
          get() { return value; },
          set(v) {},
        });
      });
    }
    """#

    static let abortOnPropertyRead = #"""
    function (chain) {
      chain = String(chain === undefined ? '' : chain);
      if (chain === '') return;
      onChain(window, chain, (owner, prop) => {
        const desc = P.getOwnPropertyDescriptor(owner, prop);
        if (desc && desc.configurable === false) return;
        P.defineProperty(owner, prop, { configurable: true, get() { throw abortError(); }, set(v) {} });
      });
    }
    """#

    static let abortOnPropertyWrite = #"""
    function (chain) {
      chain = String(chain === undefined ? '' : chain);
      if (chain === '') return;
      onChain(window, chain, (owner, prop) => {
        const desc = P.getOwnPropertyDescriptor(owner, prop);
        if (desc && desc.configurable === false) return;
        const value = owner[prop];
        P.defineProperty(owner, prop, { configurable: true, get() { return value; }, set(v) { throw abortError(); } });
      });
    }
    """#

    /// The needle is tested against the running script's `src` (if any) and text joined; `context` against its `src`.
    /// Skipped: fetching the text of external scripts (only their URL is seen) and decoding `data:` script URLs.
    static let abortCurrentScript = #"""
    function (chain, rawNeedle, rawContext) {
      chain = String(chain === undefined ? '' : chain);
      if (chain === '') return;
      const needle = matcher(rawNeedle);
      const context = rawContext ? matcher(rawContext) : null;
      const ScriptElement = window.HTMLScriptElement;
      const check = () => {
        const s = document.currentScript;
        if (!(s instanceof ScriptElement)) return;
        if (context && !context.test(s.src)) return;
        const text = s.src ? s.src + '\n' + s.textContent : s.textContent;
        if (needle.test(text)) throw abortError();
      };
      onChain(window, chain, guardLeaf(check));
    }
    """#

    /// Skipped: uBO's `inlineScript` / `injectedScript` stack tokens and its stack-line normalisation; the needle is
    /// tested against the raw `Error().stack`.
    static let abortOnStackTrace = #"""
    function (chain, rawNeedle) {
      chain = String(chain === undefined ? '' : chain);
      if (chain === '' || !rawNeedle) return;
      const needle = matcher(rawNeedle);
      const check = () => { if (needle.test(new P.Error().stack || '')) throw abortError(); };
      onChain(window, chain, guardLeaf(check));
    }
    """#

    /// Both arguments empty is uBO's logging mode; Paddle has no scriptlet log, so that does nothing.
    static let noTimerIf = #"""
    function (rawNeedle, rawDelay) {
      const needle = matcher(rawNeedle), delay = delayMatcher(rawDelay);
      if (delay === null || (needle.empty && !needle.not && delay.empty)) return;
      wrapApply(window, '__TIMER__', (target, thisArg, args) => {
        try { if (needle.test(fnText(args[0])) && delay.test(args[1])) args[0] = function () {}; } catch (e) {}
        return P.apply(target, thisArg, args);
      });
    }
    """#

    /// The type is matched whole (`click` doesn't match `dblclick`) unless it is a regex. Both empty is uBO's logging
    /// mode and does nothing here.
    static let addEventListenerDefuser = #"""
    function (rawType, rawPattern) {
      if (!rawType && !rawPattern) return;
      const type = matcher(rawType, true), pattern = matcher(rawPattern);
      wrapApply(EventTarget.prototype, 'addEventListener', (target, thisArg, args) => {
        let hit = false;
        try {
          const h = args[1];
          const text = typeof h === 'function' ? fnText(h)
            : (isObj(h) && typeof h.handleEvent === 'function') ? fnText(h.handleEvent) : String(h);
          hit = type.test(String(args[0])) && pattern.test(text);
        } catch (e) {}
        if (hit) return;
        return P.apply(target, thisArg, args);
      });
    }
    """#

    /// Required paths must all exist for pruning to happen. The optional third argument is a needle tested against
    /// the caller's stack. Skipped: uBO's `[-]` / `{-}` array-item forms and its `*`-key wildcards (only `[]`).
    static let jsonPrune = #"""
    function (rawPrune, rawNeed, rawStack) {
      const prune = makePruner(rawPrune, rawNeed);
      if (!prune) return;
      const stack = rawStack ? matcher(rawStack) : null;
      wrapApply(JSON, 'parse', (target, thisArg, args) => {
        const result = P.apply(target, thisArg, args);
        try { if (!stack || stack.test(new P.Error().stack || '')) prune(result); } catch (e) {}
        return result;
      });
    }
    """#

    /// Extra arguments are option pairs; `propsToMatch` (request needles) is supported. Skipped: other uBO options.
    static let jsonPruneFetchResponse = #"""
    function (rawPrune, rawNeed, ...rest) {
      const prune = makePruner(rawPrune, rawNeed);
      if (!prune) return;
      const options = optionPairs(rest);
      const match = options.propsToMatch ? requestMatcher(options.propsToMatch) : null;
      if (options.propsToMatch && !match) return;
      const Resp = window.Response, clone = Resp.prototype.clone, text = Resp.prototype.text;
      wrapApply(window, 'fetch', (target, thisArg, args) => {
        let wanted = true;
        try { wanted = !match || match(fetchDetails(args)); } catch (e) { wanted = false; }
        const pending = P.apply(target, thisArg, args);
        if (!wanted) return pending;
        return P.apply(P.then, pending, [resp => {
          // Only JSON with a body: reading a stream (server-sent events, long polls) would never finish.
          let copy;
          try {
            const type = String(resp.headers.get('content-type') || '');
            if (resp.body === null || !/json/i.test(type)) return resp;
            copy = P.apply(clone, resp, []);
          } catch (e) { return resp; }
          return P.apply(P.then, P.apply(text, copy, []), [body => {
            try {
              const obj = P.JSONParse(body);
              if (!prune(obj)) return resp;
              const out = new Resp(P.JSONStringify(obj), { status: resp.status, statusText: resp.statusText, headers: resp.headers });
              for (const k of ['url', 'redirected', 'type']) P.defineProperty(out, k, { value: resp[k] });
              return out;
            } catch (e) { return resp; }
          }, () => resp]);
        }]);
      });
    }
    """#

    /// Extra arguments are option pairs; `propsToMatch` (needles over `method` and `url`) is supported.
    static let jsonPruneXHRResponse = #"""
    function (rawPrune, rawNeed, ...rest) {
      const prune = makePruner(rawPrune, rawNeed);
      if (!prune) return;
      const options = optionPairs(rest);
      const match = options.propsToMatch ? requestMatcher(options.propsToMatch) : null;
      if (options.propsToMatch && !match) return;
      const XP = XMLHttpRequest.prototype, state = new WeakMap();
      const responseGet = P.getOwnPropertyDescriptor(XP, 'response').get;
      const textGet = P.getOwnPropertyDescriptor(XP, 'responseText').get;
      wrapApply(XP, 'open', (target, xhr, args) => {
        try {
          const wanted = !match || match({ method: String(args[0]).toUpperCase(), url: absoluteURL(args[1]) });
          if (wanted) state.set(xhr, {}); else state.delete(xhr);
        } catch (e) {}
        return P.apply(target, xhr, args);
      });
      const pruned = xhr => {
        const st = state.get(xhr);
        if (!st || xhr.readyState !== 4) return undefined;
        if (!st.done) {
          st.done = true;
          const type = xhr.responseType;
          if (type === 'json') { const obj = P.apply(responseGet, xhr, []); prune(obj); st.obj = obj; }
          else if (type === '' || type === 'text') {
            try { const obj = P.JSONParse(P.apply(textGet, xhr, [])); if (prune(obj)) st.text = P.JSONStringify(obj); } catch (e) {}
          }
        }
        return st;
      };
      for (const [prop, getter] of [['response', responseGet], ['responseText', textGet]]) {
        P.defineProperty(XP, prop, {
          configurable: true, enumerable: true,
          get() {
            const raw = P.apply(getter, this, []);
            try {
              const st = pruned(this);
              if (st && st.obj !== undefined && prop === 'response') return st.obj;
              if (st && st.text !== undefined) return st.text;
            } catch (e) {}
            return raw;
          },
        });
      }
    }
    """#

    /// The body token is `''` (default), `emptyStr`, `emptyObj` or `emptyArr`. Skipped: uBO's `war:` resources,
    /// `length:` random bodies and `opaque` response type; any other body token makes the scriptlet do nothing.
    static let noFetchIf = #"""
    function (rawProps, rawBody) {
      const match = requestMatcher(rawProps);
      if (!match) return;
      const bodies = { '': '', emptyStr: '', emptyObj: '{}', emptyArr: '[]' };
      const key = String(rawBody === undefined ? '' : rawBody);
      if (!P.apply(P.hasOwn, bodies, [key])) return;
      const body = bodies[key], Resp = window.Response;
      wrapApply(window, 'fetch', (target, thisArg, args) => {
        let details;
        try { details = fetchDetails(args); if (!match(details)) details = undefined; } catch (e) { details = undefined; }
        if (details === undefined) return P.apply(target, thisArg, args);
        const resp = new Resp(body, { status: 200, statusText: 'OK' });
        try { P.defineProperty(resp, 'url', { value: details.url }); } catch (e) {}
        return new P.Promise(resolve => resolve(resp));
      });
    }
    """#

    /// Needles test `method` and `url` (from `open`). The request is never sent; `send` answers with an empty 200.
    /// Skipped: uBO's directive argument (`randomize` / `length:` response text); the fake body is always empty.
    static let noXHRIf = #"""
    function (rawProps) {
      const match = requestMatcher(rawProps);
      if (!match) return;
      const XP = XMLHttpRequest.prototype, blocked = new WeakMap(), faked = new WeakMap();
      wrapApply(XP, 'open', (target, xhr, args) => {
        try {
          // A reused request object loses the fake answer of its last blocked request.
          for (const k of faked.get(xhr) || []) delete xhr[k];
          faked.delete(xhr);
          const details = { method: String(args[0]).toUpperCase(), url: absoluteURL(args[1]) };
          if (match(details)) blocked.set(xhr, details); else blocked.delete(xhr);
        } catch (e) {}
        return P.apply(target, xhr, args);
      });
      wrapApply(XP, 'send', (target, xhr, args) => {
        const details = blocked.get(xhr);
        if (!details) return P.apply(target, xhr, args);
        P.apply(P.setTimeout, window, [() => {
          try {
            const type = xhr.responseType;
            const response = type === 'arraybuffer' ? new ArrayBuffer(0) : type === 'blob' ? new Blob([])
              : (type === 'json' || type === 'document') ? null : '';
            const fake = { readyState: 4, status: 200, statusText: 'OK', response, responseURL: details.url };
            if (type === '' || type === 'text') fake.responseText = '';
            for (const k of P.keys(fake)) P.defineProperty(xhr, k, { value: fake[k], configurable: true });
            faked.set(xhr, P.keys(fake));
            xhr.dispatchEvent(new Event('readystatechange'));
            for (const type of ['load', 'loadend']) xhr.dispatchEvent(new ProgressEvent(type));
          } catch (e) {}
        }, 1]);
      });
    }
    """#

    /// An empty needle blocks every `eval`. Wrapping makes page calls indirect evals (global scope), as in uBO.
    static let noEvalIf = #"""
    function (rawNeedle) {
      const needle = matcher(rawNeedle);
      wrapApply(window, 'eval', (target, thisArg, args) => {
        let hit = false;
        try { hit = needle.test(String(args[0])); } catch (e) {}
        if (hit) return undefined;
        return P.apply(target, thisArg, args);
      });
    }
    """#

    /// The needle tests the URL; an empty needle matches every call. A match gets a harmless stub window.
    /// Skipped: uBO's `delay` and `decoy` arguments (a decoy iframe or object kept for some seconds).
    static let noWindowOpenIf = #"""
    function (rawNeedle) {
      const needle = matcher(rawNeedle);
      wrapApply(window, 'open', (target, thisArg, args) => {
        let hit = false;
        try { hit = needle.test(args[0] === undefined ? '' : String(args[0])); } catch (e) {}
        if (!hit) return P.apply(target, thisArg, args);
        const stub = {
          closed: false, opener: null, name: '', length: 0, location: { href: 'about:blank' },
          close() { stub.closed = true; }, focus: noop, blur: noop, postMessage: noop,
          addEventListener: noop, removeEventListener: noop,
        };
        stub.window = stub.self = stub;
        return stub;
      });
    }
    """#

    /// Names separated by `|`; the default selector is every element carrying one. Behaviour tokens: `asap` (start at
    /// document start), `complete` (start at load), `stay` (keep watching after load; otherwise added nodes are
    /// handled until the load event).
    static let removeAttr = #"""
    function (rawNames, rawSelector, rawBehavior) {
      const names = String(rawNames === undefined ? '' : rawNames).split('|').map(s => s.trim()).filter(s => s !== '');
      if (names.length === 0) return;
      const behavior = String(rawBehavior === undefined ? '' : rawBehavior);
      const selector = rawSelector ? String(rawSelector) : names.map(n => '[' + CSS.escape(n) + ']').join(',');
      document.createDocumentFragment().querySelector(selector);
      const strip = () => {
        try {
          for (const el of document.querySelectorAll(selector)) {
            for (const n of names) { try { if (el.hasAttribute(n)) el.removeAttribute(n); } catch (e) {} }
          }
        } catch (e) {}
      };
      runAt(behavior, () => stripLater(behavior, names, strip));
    }
    """#

    /// Classes separated by `|`; with a selector, those classes are removed from its matches. Behaviour as remove-attr.
    static let removeClass = #"""
    function (rawNames, rawSelector, rawBehavior) {
      const names = String(rawNames === undefined ? '' : rawNames).split('|').map(s => s.trim()).filter(s => s !== '');
      if (names.length === 0) return;
      const behavior = String(rawBehavior === undefined ? '' : rawBehavior);
      const selector = rawSelector ? String(rawSelector) : names.map(n => '.' + CSS.escape(n)).join(',');
      document.createDocumentFragment().querySelector(selector);
      const strip = () => {
        try {
          for (const el of document.querySelectorAll(selector)) {
            for (const n of names) { try { el.classList.remove(n); } catch (e) {} }
          }
        } catch (e) {}
      };
      runAt(behavior, () => stripLater(behavior, ['class'], strip));
    }
    """#

    /// Node name matched whole and case-insensitively (`#text`, `script`, or a regex); matching nodes' text is
    /// emptied, including inline scripts before they run. Skipped: uBO's extra `condition` / `quitAfter` options.
    static let removeNodeText = #"""
    function (rawName, rawNeedle) {
      if (!rawName || !rawNeedle) return;
      const name = matcher(String(rawName).toLowerCase(), true), needle = matcher(rawNeedle);
      const check = node => {
        try { if (name.test(node.nodeName.toLowerCase()) && needle.test(node.textContent)) node.textContent = ''; } catch (e) {}
      };
      const scan = root => {
        check(root);
        if (!root.firstChild) return;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        let n;
        while ((n = walker.nextNode())) check(n);
      };
      new MutationObserver(records => {
        for (const r of records) for (const n of r.addedNodes) scan(n);
      }).observe(document, { childList: true, subtree: true });
      if (document.documentElement) scan(document.documentElement);
    }
    """#

    /// Needle (empty or `*` = any callback), delay (default 1000, `*` = any), boost factor (default 0.05, clamped to
    /// 0.001…50). Matching timers get `delay × boost`.
    static let timerBooster = #"""
    function (rawNeedle, rawDelay, rawBoost) {
      const needle = matcher(rawNeedle === '*' ? '' : rawNeedle);
      const anyDelay = rawDelay === '*';
      let delay = parseInt(rawDelay, 10);
      if (isNaN(delay)) delay = 1000;
      let boost = parseFloat(rawBoost);
      if (!isFinite(boost)) boost = 0.05;
      boost = Math.min(50, Math.max(0.001, boost));
      wrapApply(window, '__TIMER__', (target, thisArg, args) => {
        try {
          if ((anyDelay || Number(args[1]) === delay) && needle.test(fnText(args[0]))) args[1] = (Number(args[1]) || 0) * boost;
        } catch (e) {}
        return P.apply(target, thisArg, args);
      });
    }
    """#

    /// Replaces each peer-connection constructor that exists with an inert one: no ICE, no data channels.
    static let noWebRTC = #"""
    function () {
      const resolved = () => new P.Promise(resolve => resolve());
      const channel = () => ({ readyState: 'closed', label: '', close: noop, send: noop, addEventListener: noop, removeEventListener: noop });
      class PeerConnection extends EventTarget {
        constructor() { super(); }
        get connectionState() { return 'closed'; }
        get iceConnectionState() { return 'closed'; }
        get iceGatheringState() { return 'complete'; }
        get signalingState() { return 'closed'; }
        get localDescription() { return null; }
        get remoteDescription() { return null; }
        close() {}
        createDataChannel() { return channel(); }
        createOffer() { return resolved(); }
        createAnswer() { return resolved(); }
        setLocalDescription() { return resolved(); }
        setRemoteDescription() { return resolved(); }
        addIceCandidate() { return resolved(); }
        getStats() { return new P.Promise(resolve => resolve(new Map())); }
        getSenders() { return []; }
        getReceivers() { return []; }
        getTransceivers() { return []; }
        addTrack() {}
        removeTrack() {}
        addTransceiver() {}
        getConfiguration() { return {}; }
        setConfiguration() {}
      }
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection']) {
        if (typeof window[name] !== 'function') continue;
        try { window[name] = PeerConnection; } catch (e) {}
      }
    }
    """#
}
