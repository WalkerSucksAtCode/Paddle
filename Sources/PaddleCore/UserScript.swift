import Foundation

/// A user script loaded from the `userscripts` folder. Understands the common Greasemonkey/Tampermonkey
/// header (`@name`, `@match`, `@include`, `@exclude`, `@run-at`, `@noframes`, `@inject-into`).
/// A file without a header runs on every page. `GM_*` APIs are not provided.
public struct UserScript: Sendable, Equatable {
    public enum RunAt: String, Sendable {
        case documentStart = "document-start"
        case documentEnd = "document-end"
        case documentIdle = "document-idle"
    }

    public var name: String
    /// Regular expressions (shared syntax between Swift and JavaScript) a URL must match one of.
    public var includeRegexes: [String]
    public var excludeRegexes: [String]
    public var runAt: RunAt
    public var mainFrameOnly: Bool
    /// `@inject-into content`: run in an isolated world the page's scripts cannot see.
    public var isolated: Bool
    public var source: String

    public init(fileName: String, source: String) {
        var name = (fileName as NSString).deletingPathExtension
        var includes: [String] = []
        var excludes: [String] = []
        var runAt = RunAt.documentEnd
        var mainFrameOnly = false
        var isolated = false

        for (key, value) in Self.headerEntries(source) {
            switch key {
            case "name": name = value
            case "match": if let r = Self.regex(forMatchPattern: value) { includes.append(r) }
            case "include": includes.append(Self.regex(forGlobOrRegex: value))
            case "exclude": excludes.append(Self.regex(forGlobOrRegex: value))
            case "exclude-match": if let r = Self.regex(forMatchPattern: value) { excludes.append(r) }
            case "run-at": runAt = RunAt(rawValue: value) ?? .documentEnd
            case "noframes": mainFrameOnly = true
            case "inject-into": isolated = value == "content"
            default: break
            }
        }

        self.name = name
        self.includeRegexes = includes.isEmpty ? [".*"] : includes
        self.excludeRegexes = excludes
        self.runAt = runAt
        self.mainFrameOnly = mainFrameOnly
        self.isolated = isolated
        self.source = source
    }

    public func matches(_ url: String) -> Bool {
        func any(_ patterns: [String]) -> Bool {
            patterns.contains { pattern in
                guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
                return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            }
        }
        return any(includeRegexes) && !any(excludeRegexes)
    }

    /// The script wrapped so it only runs on matching URLs (WebKit injects user scripts into every page).
    public var wrappedSource: String {
        func jsArray(_ patterns: [String]) -> String {
            let literals = patterns.map { pattern -> String in
                let data = (try? JSONSerialization.data(withJSONObject: [pattern], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
                let json = String(decoding: data, as: UTF8.self)
                return "new RegExp(\(json.dropFirst().dropLast()))"
            }
            return "[" + literals.joined(separator: ", ") + "]"
        }
        return """
        (function () {
        const __paddleHref = location.href;
        if (!\(jsArray(includeRegexes)).some(r => r.test(__paddleHref))) return;
        if (\(jsArray(excludeRegexes)).some(r => r.test(__paddleHref))) return;
        \(source)
        })();
        """
    }

    // MARK: - Header parsing

    static func headerEntries(_ source: String) -> [(String, String)] {
        guard let start = source.range(of: "==UserScript=="),
              let end = source.range(of: "==/UserScript==", range: start.upperBound..<source.endIndex)
        else { return [] }

        return source[start.upperBound..<end.lowerBound]
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                guard let at = line.firstIndex(of: "@") else { return nil }
                let rest = line[line.index(after: at)...]
                let key = rest.prefix { !$0.isWhitespace }
                let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                return (String(key), value)
            }
    }

    // MARK: - Pattern conversion

    /// Chrome-style match pattern (`*://*.example.com/*`, `<all_urls>`) to an anchored regex.
    static func regex(forMatchPattern pattern: String) -> String? {
        if pattern == "<all_urls>" { return "^(https?|file)://" }
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let scheme = String(pattern[..<schemeEnd.lowerBound])
        let afterScheme = pattern[schemeEnd.upperBound...]
        let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let host = String(afterScheme[..<slash])
        let path = afterScheme[slash...].isEmpty ? "/*" : String(afterScheme[slash...])

        let schemeRegex: String
        switch scheme {
        case "*": schemeRegex = "https?"
        case "http", "https", "file": schemeRegex = scheme
        default: return nil
        }

        let hostRegex: String
        if host == "*" {
            hostRegex = "[^/]*"
        } else if host.hasPrefix("*.") {
            hostRegex = "([^/]*\\.)?" + escape(String(host.dropFirst(2))) + "(:[0-9]+)?"
        } else {
            hostRegex = escape(host) + "(:[0-9]+)?"
        }

        let pathRegex = path.split(separator: "*", omittingEmptySubsequences: false)
            .map { escape(String($0)) }
            .joined(separator: ".*")
        return "^" + schemeRegex + "://" + hostRegex + pathRegex + "$"
    }

    /// Greasemonkey `@include`/`@exclude`: `/regex/` or a glob where `*` matches anything.
    static func regex(forGlobOrRegex value: String) -> String {
        if value.count > 2, value.hasPrefix("/"), value.hasSuffix("/") {
            return String(value.dropFirst().dropLast())
        }
        if value == "*" { return ".*" }
        return "^" + value.split(separator: "*", omittingEmptySubsequences: false)
            .map { escape(String($0)) }
            .joined(separator: ".*") + "$"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
