import Foundation

/// The compatibility prelude for extensions built for Chrome or Firefox rather than Safari, and the manifest and
/// popup edits that put it in place. Pure text transforms; `ExtensionOverlay` applies them to a cloned folder.
///
/// Why: WebKit delivers extension events to a JavaScript context only while `browser` or `chrome` is still the
/// original namespace object. Proton Pass replaces both with Proxies one tick after loading, after which its
/// background and content scripts hear nothing; it also calls `runtime.onUpdateAvailable.addListener`, which WebKit
/// doesn't provide, and that throw aborts the rest of its startup. The prelude runs first in each of those contexts,
/// pins the two globals (writes are ignored instead of throwing) and stubs the missing event.
public enum ExtensionCompat {
    public static let preludeFileName = "paddle-prelude.js"

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

    /// Proton Pass's Firefox build. Its popup reads `tabs.getCurrent()` to tell a popup from a tab; WebKit returns a
    /// tab (or null) instead of undefined, so the popup lays itself out at tab size (356×338) instead of 600×430.
    public static let protonPassGeckoID = "78272b6fa58f4a1abaac99321d503a20@proton.me"
    static let protonPassPopupCSS = ":root{--popup-width:600px!important;--popup-height:430px!important}html,body{width:600px!important;height:430px!important}"
    /// Marks the `<style>` the overlay adds, so a second pass leaves the page alone.
    static let styleMarker = "data-paddle-compat"

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
        /// The prelude is first in `background.scripts`.
        public let backgroundPatched: Bool
        /// The prelude is first in the `js` of at least one of the extension's own isolated-world content scripts.
        public let contentScriptsPatched: Bool
        /// The background kind left as it is, if the extension has one and it isn't a non-empty `scripts` array.
        public let unpatchedBackground: UnpatchedBackground?

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

    /// `browser_specific_settings.gecko.id`, if any.
    public static func geckoID(manifest: [String: Any]) -> String? {
        ((manifest["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any])?["id"] as? String
    }

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

    /// CSS the overlay adds to this extension's popup page, if it needs any.
    public static func popupCSS(forGeckoID id: String?) -> String? {
        id == protonPassGeckoID ? protonPassPopupCSS : nil
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

    /// Puts the prelude first in a non-empty `background.scripts` and first in the `js` of each of the extension's
    /// own isolated-world content scripts, so it runs before them in exactly the frames they already run in. No
    /// content script is added and no match pattern changes, so the extension's requested hosts stay as they were.
    /// Edits the text in place so every other byte of the file stays as it was (key order, indentation, escapes).
    /// Idempotent: a list that already starts with the prelude is left alone. A `service_worker` or `page`
    /// background (or one whose `scripts` is empty, which WebKit ignores in favour of either) is left unpatched and
    /// reported as such.
    public static func patchManifest(_ data: Data) throws -> ManifestPatch {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PatchError.notAnObject }
        var bytes = [UInt8](data)
        let scanner = JSONScanner(bytes)
        let start = scanner.skipWhitespace(0)
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { throw PatchError.notAnObject }
        let members = try scanner.members(ofObjectAt: start)

        // Insertions are collected as offsets into the original text and applied back to front, so none moves another.
        var edits: [JSONScanner.Edit] = []
        var backgroundPatched = false
        var unpatched: UnpatchedBackground?
        var contentPatched = false
        let prelude = "\"\(preludeFileName)\""

        if let background = root["background"] as? [String: Any] {
            if let scripts = background["scripts"] as? [Any], !scripts.isEmpty {
                if scripts.first as? String != preludeFileName {
                    guard let backgroundMember = members.first(where: { $0.key == "background" }),
                          bytes[backgroundMember.valueStart] == UInt8(ascii: "{"),
                          let scriptsMember = try scanner.members(ofObjectAt: backgroundMember.valueStart).first(where: { $0.key == "scripts" }),
                          bytes[scriptsMember.valueStart] == UInt8(ascii: "[") else {
                        throw PatchError.malformed("background.scripts is not an array")
                    }
                    edits.append(scanner.insertion(ofFirstElement: prelude, intoArrayAt: scriptsMember.valueStart))
                }
                backgroundPatched = true
            } else if background["service_worker"] != nil {
                unpatched = .serviceWorker
            } else if background["page"] != nil {
                unpatched = .page
            }
        }

        if let entries = root["content_scripts"] as? [Any],
           let contentMember = members.first(where: { $0.key == "content_scripts" }),
           bytes[contentMember.valueStart] == UInt8(ascii: "[") {
            let elements = try scanner.elements(ofArrayAt: contentMember.valueStart)
            guard elements.count == entries.count else { throw PatchError.malformed("content_scripts did not scan") }
            for (entry, element) in zip(entries, elements) where takesPrelude(entry) {
                contentPatched = true
                if ((entry as? [String: Any])?["js"] as? [Any])?.first as? String == preludeFileName { continue }
                guard bytes[element] == UInt8(ascii: "{"),
                      let jsMember = try scanner.members(ofObjectAt: element).first(where: { $0.key == "js" }),
                      bytes[jsMember.valueStart] == UInt8(ascii: "[") else {
                    throw PatchError.malformed("a content_scripts entry's js is not an array")
                }
                edits.append(scanner.insertion(ofFirstElement: prelude, intoArrayAt: jsMember.valueStart))
            }
        }

        for edit in edits.sorted(by: { $0.at > $1.at }) {
            bytes.insert(contentsOf: edit.text, at: edit.at)
        }
        let result = Data(bytes)

        // The edit must still parse, say what it was meant to say, and ask for the same hosts.
        guard let check = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw PatchError.malformed("the rewritten manifest does not parse")
        }
        if backgroundPatched, ((check["background"] as? [String: Any])?["scripts"] as? [Any])?.first as? String != preludeFileName {
            throw PatchError.malformed("the prelude did not land first in background.scripts")
        }
        let checkEntries = (check["content_scripts"] as? [Any]) ?? []
        guard checkEntries.count == ((root["content_scripts"] as? [Any])?.count ?? 0),
              checkEntries.filter(takesPrelude).allSatisfy({ (($0 as? [String: Any])?["js"] as? [Any])?.first as? String == preludeFileName }) else {
            throw PatchError.malformed("the prelude did not land first in every content script")
        }
        guard contentScriptPatterns(manifest: check) == contentScriptPatterns(manifest: root) else {
            throw PatchError.malformed("the rewrite changed the content scripts' match patterns")
        }
        return ManifestPatch(
            data: result, backgroundPatched: backgroundPatched, contentScriptsPatched: contentPatched,
            unpatchedBackground: unpatched
        )
    }

    // MARK: - Popup page

    /// Adds `<style data-paddle-compat>css</style>` to the page, before `</head>` (else before `<body`, else at the
    /// end). Idempotent: a page that already carries the marker is returned as it is. Not UTF-8: returned unchanged.
    public static func insertStyle(_ css: String, into html: Data) -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        guard !text.contains(styleMarker) else { return html }
        let style = "<style \(styleMarker)>\(css)</style>"
        for needle in ["</head>", "<body"] {
            if let range = text.range(of: needle, options: .caseInsensitive) {
                return Data(text.replacingCharacters(in: range.lowerBound..<range.lowerBound, with: style).utf8)
            }
        }
        return Data((text + style).utf8)
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

    /// One insertion: `text` goes before index `at`.
    typealias Edit = (at: Int, text: [UInt8])

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
            return (afterOpen, Array(text.utf8))
        }
        return (afterOpen, whitespace + Array(text.utf8) + [UInt8(ascii: ",")])
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
