import Foundation

/// The compatibility prelude for extensions built for Chrome or Firefox rather than Safari, and the manifest edits
/// that put it in place. Pure text transforms; `ExtensionOverlay` applies them to a cloned folder.
///
/// Why: WebKit delivers extension events to a JavaScript context only while `browser` or `chrome` is still the
/// original namespace object. Proton Pass replaces both with Proxies one tick after loading, after which its
/// background and content scripts hear nothing; it also calls `runtime.onUpdateAvailable.addListener`, which WebKit
/// doesn't provide, and that throw aborts the rest of its startup. The prelude runs first in each of those contexts,
/// pins the two globals (writes are ignored instead of throwing) and stubs the missing event.
public enum ExtensionCompat {
    public static let preludeFileName = "paddle-prelude.js"
    /// The slim, JS-only prelude for content scripts (personas `chrome` and `firefox`).
    public static let contentFileName = "paddle-content.js"
    /// The service-worker wrapper, written in the original worker's directory.
    public static let serviceWorkerWrapperName = "paddle-sw.js"
    /// The reserved native-messaging id Paddle answers itself (the compat bus).
    public static let busID = "com.walker.paddle.compat"
    /// Permission names WebKit knows (`WKWebExtensionPermission`, macOS 27 SDK). Others are dropped from the
    /// manifest by WebKit, and `permissions.contains` with one of them fails (E23), so the prelude answers them.
    public static let webKitPermissionNames: Set<String> = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
        "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging",
        "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest",
    ]

    /// The prelude, as verified in the wave 4b probe, plus a `requestIdleCallback` stand-in: WebKit ships that API
    /// switched off, and Proton Pass's form detector calls it without a fallback. Paddle also switches WebKit's own
    /// on (WebEnvironment); the stand-in covers a WebKit without that private switch.
    public static let prelude = """
    // Paddle compat prelude: runs first in every extension JS context it is listed in (background, content-script world).
    (() => {
      const ns = globalThis.browser || globalThis.chrome;
      if (!(ns && ns.runtime && ns.runtime.id)) return;            // a web page's own world: do nothing
      if (typeof globalThis.requestIdleCallback !== 'function') {
        globalThis.requestIdleCallback = (cb) => setTimeout(() => { const s = performance.now(); cb({didTimeout: false, timeRemaining: () => Math.max(0, 50 - (performance.now() - s))}); }, 1);
        globalThis.cancelIdleCallback = (id) => clearTimeout(id);
      }
      if (!ns.runtime.onUpdateAvailable) {
        ns.runtime.onUpdateAvailable = {addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; }};
      }
      for (const k of ['browser', 'chrome']) {
        const v = globalThis[k];
        if (v) try { Object.defineProperty(globalThis, k, {get: () => v, set: () => {}, enumerable: true, configurable: false}); } catch (e) {}
      }
    })();

    """

    public enum PatchError: Error, Equatable, LocalizedError {
        case notAnObject
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject: "manifest.json is not a JSON object"
            case .malformed(let why): "manifest.json: \(why)"
            }
        }
    }

    /// A background the prelude can't go first in: WebKit runs a worker from one file, and a background page loads
    /// its own scripts from HTML.
    public enum UnpatchedBackground: String, Sendable, Codable {
        case serviceWorker = "service_worker"
        case page
    }

    /// What `patchManifest` did.
    public struct ManifestPatch: Equatable, Sendable {
        public let data: Data
        /// `none` for the 4b patch, else the persona whose v2 patch this is.
        public let persona: Persona
        /// The prelude runs first in the background: first in `background.scripts`, or (v2) through the worker
        /// wrapper or the background page's script tag.
        public let backgroundPatched: Bool
        /// The prelude is first in the `js` of at least one of the extension's own isolated-world content scripts.
        public let contentScriptsPatched: Bool
        /// The background kind left as it is, if the extension has one and it isn't a non-empty `scripts` array.
        public let unpatchedBackground: UnpatchedBackground?
        /// The `paddle-sw.js` the overlay must write (v2, a service-worker background).
        public let serviceWorkerWrapper: GeneratedFile?
        /// The background page (v2), relative to the root; the overlay tags it with every other page.
        public let backgroundPage: String?

        /// The manifest differs from the original (or already carried the prelude).
        public var preludeApplied: Bool { backgroundPatched || contentScriptsPatched }
    }

    // MARK: - Decisions

    /// Extensions built for Safari (`browser_specific_settings.safari` in the manifest) run as they are; the rest get
    /// the prelude.
    public static func needsPrelude(manifest: [String: Any]) -> Bool {
        let settings = manifest["browser_specific_settings"] as? [String: Any]
        return settings?["safari"] == nil
    }

    /// The gecko id (`browser_specific_settings.gecko.id`, else `applications.gecko.id`), if any.
    public static func geckoID(manifest: [String: Any]) -> String? { Persona.geckoID(manifest: manifest) }

    /// The popup page named by `action` / `browser_action` / `page_action`, relative to the extension root, as plain
    /// path components. Nil when there is none, or when it climbs out of the root (a `..` component).
    public static func popupPath(manifest: [String: Any]) -> String? {
        for key in ["action", "browser_action", "page_action"] {
            if let popup = (manifest[key] as? [String: Any])?["default_popup"] as? String {
                let cleaned = popup.prefix { $0 != "?" && $0 != "#" }
                let components = cleaned.split(separator: "/").map(String.init).filter { $0 != "." }
                guard !components.isEmpty, !components.contains("..") else { return nil }
                return components.joined(separator: "/")
            }
        }
        return nil
    }

    /// Runtime errors the prelude causes on purpose: strict-mode code assigning to the pinned `browser` / `chrome`
    /// globals is told the property is read-only. JavaScriptCore's message doesn't name the property, so callers
    /// apply this only to extensions that run the prelude.
    public static func isHarmlessError(_ text: String) -> Bool {
        text.contains("Attempted to assign to readonly property")
    }

    /// Every match pattern string the manifest's content scripts name (`matches` and `exclude_matches`). The patch
    /// must leave this set as it was: WebKit counts content-script matches as requested hosts.
    public static func contentScriptPatterns(manifest: [String: Any]) -> Set<String> {
        var patterns: Set<String> = []
        for entry in (manifest["content_scripts"] as? [Any]) ?? [] {
            guard let entry = entry as? [String: Any] else { continue }
            for key in ["matches", "exclude_matches"] {
                for pattern in (entry[key] as? [Any]) ?? [] { if let pattern = pattern as? String { patterns.insert(pattern) } }
            }
        }
        return patterns
    }

    /// A content-script entry the prelude goes first in: one with scripts, in the extension's isolated world (a
    /// `MAIN`-world script runs in the page's world, where the prelude does nothing).
    static func takesPrelude(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any], let js = entry["js"] as? [Any], !js.isEmpty else { return false }
        if let world = entry["world"] as? String, world.uppercased() == "MAIN" { return false }
        return true
    }

    // MARK: - Manifest

    /// A file the overlay writes next to the patched manifest.
    public struct GeneratedFile: Equatable, Sendable {
        /// Relative to the extension root.
        public let path: String
        public let contents: String
    }

    /// The patch for the 4b prelude (persona `none`).
    public static func patchManifest(_ data: Data) throws -> ManifestPatch {
        try patchManifest(data, persona: .none)
    }

    /// Puts the prelude in front of the extension's own code, editing the text in place so every other byte of
    /// the file stays as it was (key order, indentation, escapes). Idempotent. No content script is added and no
    /// match pattern changes, so the extension's requested hosts stay as they were.
    ///
    /// Every persona: `paddle-prelude.js` first in a non-empty `background.scripts`.
    ///
    /// `none` (wave 4b): `paddle-prelude.js` first in the `js` of each isolated-world content script; a
    /// `service_worker` or `page` background is left as it is and reported in `unpatchedBackground`.
    ///
    /// `chrome` / `firefox` (wave 4c):
    /// - `background.service_worker` points at `paddle-sw.js` in the original worker's directory (E1: a wrapper at
    ///   the root breaks the worker's relative imports), which loads `/paddle-prelude.js` and then the worker, by
    ///   `importScripts` for a classic worker and `import` for `"type": "module"`. The wrapper is in
    ///   `serviceWorkerWrapper`.
    /// - A `background.page` is reported in `backgroundPage`; the overlay puts the prelude's `<script>` tag first in
    ///   it, as in every other `.html` file (`insertScriptTag(into:src:)`).
    /// - `paddle-content.js` (the slim prelude) first in the `js` of each isolated-world content script.
    ///
    /// `native` gets no overlay; callers don't patch it (it is treated as `none` here).
    public static func patchManifest(_ data: Data, persona: Persona) throws -> ManifestPatch {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PatchError.notAnObject }
        let v2 = persona.runsPersonaPrelude
        let contentFile = v2 ? contentFileName : preludeFileName
        var bytes = [UInt8](data)
        let scanner = JSONScanner(bytes)
        let start = scanner.skipWhitespace(0)
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { throw PatchError.notAnObject }
        let members = try scanner.members(ofObjectAt: start)

        // Edits are collected as offsets into the original text and applied back to front, so none moves another.
        var edits: [JSONScanner.Edit] = []
        var backgroundPatched = false
        var unpatched: UnpatchedBackground?
        var contentPatched = false
        var wrapper: GeneratedFile?
        var backgroundPage: String?

        if let background = root["background"] as? [String: Any] {
            func backgroundMembers() throws -> [JSONScanner.Member] {
                guard let member = members.first(where: { $0.key == "background" }), bytes[member.valueStart] == UInt8(ascii: "{") else {
                    throw PatchError.malformed("background is not an object")
                }
                return try scanner.members(ofObjectAt: member.valueStart)
            }
            if let scripts = background["scripts"] as? [Any], !scripts.isEmpty {
                if scripts.first as? String != preludeFileName {
                    guard let scriptsMember = try backgroundMembers().first(where: { $0.key == "scripts" }),
                          bytes[scriptsMember.valueStart] == UInt8(ascii: "[") else {
                        throw PatchError.malformed("background.scripts is not an array")
                    }
                    edits.append(scanner.insertion(ofFirstElement: "\"\(preludeFileName)\"", intoArrayAt: scriptsMember.valueStart))
                }
                backgroundPatched = true
            }
            if v2, let worker = background["service_worker"] as? String,
               let made = serviceWorkerWrapper(for: worker, module: (background["type"] as? String)?.lowercased() == "module") {
                if !made.contents.isEmpty {
                    guard let workerMember = try backgroundMembers().first(where: { $0.key == "service_worker" }) else {
                        throw PatchError.malformed("background.service_worker did not scan")
                    }
                    edits.append((workerMember.valueStart, workerMember.valueEnd - workerMember.valueStart, Array(jsonString(made.path).utf8)))
                    wrapper = made
                } else {
                    // Already pointing at a wrapper (a manifest patched before): nothing to regenerate from.
                    wrapper = nil
                }
                backgroundPatched = true
            }
            if v2, let page = background["page"] as? String, let path = containedPath(page) {
                backgroundPage = path
                backgroundPatched = true
            }
            if !backgroundPatched {
                if background["service_worker"] != nil {
                    unpatched = .serviceWorker
                } else if background["page"] != nil {
                    unpatched = .page
                }
            }
        }

        if let entries = root["content_scripts"] as? [Any],
           let contentMember = members.first(where: { $0.key == "content_scripts" }),
           bytes[contentMember.valueStart] == UInt8(ascii: "[") {
            let elements = try scanner.elements(ofArrayAt: contentMember.valueStart)
            guard elements.count == entries.count else { throw PatchError.malformed("content_scripts did not scan") }
            for (entry, element) in zip(entries, elements) where takesPrelude(entry) {
                contentPatched = true
                if ((entry as? [String: Any])?["js"] as? [Any])?.first as? String == contentFile { continue }
                guard bytes[element] == UInt8(ascii: "{"),
                      let jsMember = try scanner.members(ofObjectAt: element).first(where: { $0.key == "js" }),
                      bytes[jsMember.valueStart] == UInt8(ascii: "[") else {
                    throw PatchError.malformed("a content_scripts entry's js is not an array")
                }
                edits.append(scanner.insertion(ofFirstElement: "\"\(contentFile)\"", intoArrayAt: jsMember.valueStart))
            }
        }

        for edit in edits.sorted(by: { $0.at > $1.at }) {
            bytes.replaceSubrange(edit.at..<(edit.at + edit.length), with: edit.text)
        }
        let result = Data(bytes)

        // The edit must still parse, say what it was meant to say, and ask for the same hosts.
        guard let check = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw PatchError.malformed("the rewritten manifest does not parse")
        }
        let checkBackground = check["background"] as? [String: Any]
        if let scripts = (root["background"] as? [String: Any])?["scripts"] as? [Any], !scripts.isEmpty,
           (checkBackground?["scripts"] as? [Any])?.first as? String != preludeFileName {
            throw PatchError.malformed("the prelude did not land first in background.scripts")
        }
        if let wrapper, checkBackground?["service_worker"] as? String != wrapper.path {
            throw PatchError.malformed("background.service_worker does not name the wrapper")
        }
        let checkEntries = (check["content_scripts"] as? [Any]) ?? []
        guard checkEntries.count == ((root["content_scripts"] as? [Any])?.count ?? 0),
              checkEntries.filter(takesPrelude).allSatisfy({ (($0 as? [String: Any])?["js"] as? [Any])?.first as? String == contentFile }) else {
            throw PatchError.malformed("the prelude did not land first in every content script")
        }
        guard contentScriptPatterns(manifest: check) == contentScriptPatterns(manifest: root) else {
            throw PatchError.malformed("the rewrite changed the content scripts' match patterns")
        }
        return ManifestPatch(
            data: result, persona: v2 ? persona : .none, backgroundPatched: backgroundPatched,
            contentScriptsPatched: contentPatched, unpatchedBackground: unpatched,
            serviceWorkerWrapper: wrapper, backgroundPage: backgroundPage
        )
    }

    /// The `paddle-sw.js` wrapper for a worker at `worker` (a manifest path): it sits in the worker's directory so
    /// the worker's relative `importScripts` / `import`s resolve as before (E1), loads `/paddle-prelude.js` first,
    /// then the worker by its file name. Nil for a path that climbs out of the root.
    public static func serviceWorkerWrapper(for worker: String, module: Bool) -> GeneratedFile? {
        guard let path = containedPath(worker) else { return nil }
        var components = path.split(separator: "/").map(String.init)
        let file = components.removeLast()
        // Already the wrapper (a manifest patched before): empty contents mean "leave it".
        if file == serviceWorkerWrapperName { return GeneratedFile(path: path, contents: "") }
        let wrapperPath = (components + [serviceWorkerWrapperName]).joined(separator: "/")
        let prelude = jsonString("/" + preludeFileName)
        let target = jsonString(urlComponent(file))
        let source = module
            ? "// Paddle: the compat prelude, then the extension's own module worker.\nimport \(prelude);\nimport \(jsonString("./" + urlComponent(file)));\n"
            : "// Paddle: the compat prelude, then the extension's own worker.\nimportScripts(\(prelude), \(target));\n"
        return GeneratedFile(path: wrapperPath, contents: source)
    }

    /// A manifest path as plain components relative to the root (query, fragment, leading "/" and "." dropped);
    /// nil when empty or when it has a `..` component.
    static func containedPath(_ path: String) -> String? {
        let components = cleanedPath(path).split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    static func cleanedPath(_ path: String) -> String {
        String(path.prefix { $0 != "?" && $0 != "#" }.drop { $0 == "/" })
    }

    /// A file name as a relative URL: percent-encoded where a URL needs it (spaces, `#`, `?`, `%`).
    static func urlComponent(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%;/")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// `s` as a JSON (and JavaScript) string literal.
    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    // MARK: - Extension pages

    /// The tag that loads the prelude in an extension page.
    public static func preludeScriptTag(src: String = "/" + preludeFileName) -> String {
        "<script src=\"\(src)\"></script>"
    }

    /// Adds `<script src="src"></script>` to an HTML page so it runs before the page's own scripts: right after
    /// the `<head>` tag, or before the first `<script` if one comes earlier; without a head, after the `<html>`
    /// tag, else before `<body`, else after a doctype, else at the start. Idempotent; a page that isn't UTF-8 is
    /// returned unchanged. An extension page's CSP allows it (`'self'`).
    public static func insertScriptTag(into html: Data, src: String) -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        let tag = preludeScriptTag(src: src)
        guard !text.contains(tag) else { return html }
        var at: String.Index?
        if let head = text.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) { at = head.upperBound }
        if let script = text.range(of: "<script", options: .caseInsensitive), at.map({ script.lowerBound < $0 }) ?? true {
            at = script.lowerBound
        }
        if at == nil, let tagRange = text.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) { at = tagRange.upperBound }
        if at == nil, let body = text.range(of: "<body", options: .caseInsensitive) { at = body.lowerBound }
        if at == nil, let doctype = text.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) { at = doctype.upperBound }
        let index = at ?? text.startIndex
        return Data(text.replacingCharacters(in: index..<index, with: tag).utf8)
    }
}

/// Finds members and values in JSON text without reshaping it. Structural characters are ASCII, so it walks UTF-8
/// bytes; strings are skipped with their escapes.
struct JSONScanner {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    struct Member {
        let key: String
        let valueStart: Int
        let valueEnd: Int
    }

    /// One edit: `length` bytes from index `at` are replaced by `text` (0 for an insertion).
    typealias Edit = (at: Int, length: Int, text: [UInt8])

    func skipWhitespace(_ i: Int) -> Int {
        var i = i
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        return i
    }

    /// The members of the object whose `{` is at `start`.
    func members(ofObjectAt start: Int) throws -> [Member] {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { throw ExtensionCompat.PatchError.malformed("expected an object") }
        var members: [Member] = []
        var i = skipWhitespace(start + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { return [] }
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\"") else { throw ExtensionCompat.PatchError.malformed("expected a key") }
            let keyEnd = try endOfString(at: i)
            let key = try decodeString(Array(bytes[i..<keyEnd]))
            i = skipWhitespace(keyEnd)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ExtensionCompat.PatchError.malformed("expected ':'") }
            let valueStart = skipWhitespace(i + 1)
            let valueEnd = try endOfValue(at: valueStart)
            members.append(Member(key: key, valueStart: valueStart, valueEnd: valueEnd))
            i = skipWhitespace(valueEnd)
            guard i < bytes.count else { break }
            if bytes[i] == UInt8(ascii: ",") {
                i = skipWhitespace(i + 1)
            } else if bytes[i] == UInt8(ascii: "}") {
                return members
            } else {
                throw ExtensionCompat.PatchError.malformed("expected ',' or '}'")
            }
        }
        throw ExtensionCompat.PatchError.malformed("unterminated object")
    }

    /// The start index of each element of the array whose `[` is at `start`.
    func elements(ofArrayAt start: Int) throws -> [Int] {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "[") else { throw ExtensionCompat.PatchError.malformed("expected an array") }
        var starts: [Int] = []
        var i = skipWhitespace(start + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { return [] }
        while i < bytes.count {
            starts.append(i)
            i = skipWhitespace(try endOfValue(at: i))
            guard i < bytes.count else { break }
            if bytes[i] == UInt8(ascii: ",") {
                i = skipWhitespace(i + 1)
            } else if bytes[i] == UInt8(ascii: "]") {
                return starts
            } else {
                throw ExtensionCompat.PatchError.malformed("expected ',' or ']'")
            }
        }
        throw ExtensionCompat.PatchError.malformed("unterminated array")
    }

    /// Inserts `text` as the first element of the array whose `[` is at `open`, keeping the array's own whitespace
    /// so a pretty-printed file stays pretty.
    func insertion(ofFirstElement text: String, intoArrayAt open: Int) -> Edit {
        let afterOpen = open + 1
        let next = skipWhitespace(afterOpen)
        let whitespace = Array(bytes[afterOpen..<next])
        if next < bytes.count, bytes[next] == UInt8(ascii: "]") {
            return (afterOpen, 0, Array(text.utf8))
        }
        return (afterOpen, 0, whitespace + Array(text.utf8) + [UInt8(ascii: ",")])
    }

    /// Index just past the string whose opening quote is at `i`.
    func endOfString(at i: Int) throws -> Int {
        var j = i + 1
        while j < bytes.count {
            switch bytes[j] {
            case UInt8(ascii: "\\"): j += 2
            case UInt8(ascii: "\""): return j + 1
            default: j += 1
            }
        }
        throw ExtensionCompat.PatchError.malformed("unterminated string")
    }

    /// Index just past the value that starts at `i`.
    func endOfValue(at i: Int) throws -> Int {
        guard i < bytes.count else { throw ExtensionCompat.PatchError.malformed("missing value") }
        switch bytes[i] {
        case UInt8(ascii: "\""):
            return try endOfString(at: i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var j = i
            while j < bytes.count {
                switch bytes[j] {
                case UInt8(ascii: "\""): j = try endOfString(at: j)
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    j += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    j += 1
                    if depth == 0 { return j }
                default: j += 1
                }
            }
            throw ExtensionCompat.PatchError.malformed("unterminated container")
        default:
            var j = i
            while j < bytes.count {
                let b = bytes[j]
                if b == UInt8(ascii: ",") || b == UInt8(ascii: "}") || b == UInt8(ascii: "]") || b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { break }
                j += 1
            }
            guard j > i else { throw ExtensionCompat.PatchError.malformed("missing value") }
            return j
        }
    }

    /// The text of a JSON string token (quotes included), with its escapes resolved.
    private func decodeString(_ token: [UInt8]) throws -> String {
        guard let array = try? JSONSerialization.jsonObject(with: Data([UInt8(ascii: "[")] + token + [UInt8(ascii: "]")])) as? [Any],
              let string = array.first as? String else {
            throw ExtensionCompat.PatchError.malformed("bad key string")
        }
        return string
    }
}
