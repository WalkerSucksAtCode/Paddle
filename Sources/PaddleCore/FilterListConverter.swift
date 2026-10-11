import Foundation

/// Converts Adblock Plus-syntax filter lists (EasyList, EasyPrivacy, uBlock-style basics) into WebKit
/// content rule list JSON. WebKit compiles that JSON once and enforces it natively, with no extension
/// process or per-request JavaScript, which is why blocking stays cheap.
///
/// Supported: `||host^` / `|anchor` / `*` / `^` network rules with common options (`third-party`, `domain=`,
/// resource types, `match-case`), `@@` exceptions (including `$document` site allowlisting), and `##` element
/// hiding (generic and per-domain). Skipped: regex rules, scriptlets, `#@#`, extended selectors, and options
/// WebKit cannot express (`redirect`, `csp`, `removeparam`, ...). Skipped lines are counted, never guessed.
public enum FilterListConverter {
    public static let maxRulesPerList = 150_000

    public struct Result: Sendable {
        public var json: String
        public var ruleCount: Int
        public var skippedLines: Int
        public var truncated: Bool
    }

    public static func convert(_ text: String, cosmeticChunkSize: Int = 32) -> Result {
        var blocks: [Rule] = []
        var exceptions: [Rule] = []
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:]
        var domainOrder: [String] = []
        var skipped = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

            if unsupportedMarkers.contains(where: line.contains) {
                skipped += 1
                continue
            }

            if let hide = line.range(of: "##") {
                let domains = String(line[..<hide.lowerBound])
                let selector = String(line[hide.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard isSupportedSelector(selector) else { skipped += 1; continue }
                if domains.isEmpty {
                    genericSelectors.append(selector)
                } else {
                    guard parseDomains(domains, separator: ",") != nil else { skipped += 1; continue }
                    if domainSelectors[domains] == nil { domainOrder.append(domains) }
                    domainSelectors[domains, default: []].append(selector)
                }
                continue
            }

            guard let rule = networkRule(line) else { skipped += 1; continue }
            if rule.action.type == "ignore-previous-rules" {
                exceptions.append(rule)
            } else {
                blocks.append(rule)
            }
        }

        var cosmetic: [Rule] = []
        for chunk in stride(from: 0, to: genericSelectors.count, by: cosmeticChunkSize) {
            let selectors = genericSelectors[chunk..<min(chunk + cosmeticChunkSize, genericSelectors.count)]
            cosmetic.append(Rule(
                trigger: Trigger(urlFilter: ".*"),
                action: Action(type: "css-display-none", selector: selectors.joined(separator: ", "))
            ))
        }
        for key in domainOrder {
            guard let (ifDomains, unlessDomains) = parseDomains(key, separator: ","),
                  let selectors = domainSelectors[key] else { continue }
            var trigger = Trigger(urlFilter: ".*")
            if !ifDomains.isEmpty { trigger.ifDomain = ifDomains } else { trigger.unlessDomain = unlessDomains }
            for chunk in stride(from: 0, to: selectors.count, by: cosmeticChunkSize) {
                let part = selectors[chunk..<min(chunk + cosmeticChunkSize, selectors.count)]
                cosmetic.append(Rule(trigger: trigger, action: Action(type: "css-display-none", selector: part.joined(separator: ", "))))
            }
        }

        // Exceptions must come last: `ignore-previous-rules` only cancels rules listed before it.
        var rules = blocks + cosmetic
        let room = maxRulesPerList - exceptions.count
        let truncated = rules.count > room
        if truncated { rules.removeLast(rules.count - room) }
        rules += exceptions

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        return Result(json: String(decoding: data, as: UTF8.self), ruleCount: rules.count, skippedLines: skipped, truncated: truncated)
    }

    // MARK: - Network rules

    static func networkRule(_ line: String) -> Rule? {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        var pattern = body
        var options: [Substring] = []
        if let dollar = body.lastIndex(of: "$") {
            let tail = body[body.index(after: dollar)...]
            // Options never contain "/", URL paths almost always do. Unknown options reject the rule below.
            if !tail.isEmpty, !tail.contains("/") {
                pattern = body[..<dollar]
                options = tail.split(separator: ",")
            }
        }

        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }  // regex rule
        guard pattern.allSatisfy(\.isASCII) else { return nil }

        var trigger = Trigger(urlFilter: "")
        var caseSensitive = false
        var resourceTypes: Set<String> = []
        var excludedTypes: Set<String> = []
        var isDocumentAllowlist = false

        for raw in options {
            let negated = raw.hasPrefix("~")
            let option = negated ? raw.dropFirst() : raw
            let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            let value = option.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)

            switch name {
            case "third-party", "3p":
                trigger.loadType = [negated ? "first-party" : "third-party"]
            case "first-party", "1p":
                trigger.loadType = [negated ? "third-party" : "first-party"]
            case "domain", "from":
                guard !negated, let value, let (ifs, unlesses) = parseDomains(value, separator: "|") else { return nil }
                if !ifs.isEmpty { trigger.ifDomain = ifs } else { trigger.unlessDomain = unlesses }
            case "match-case":
                caseSensitive = true
            case "important":
                break
            case "document", "doc":
                guard isException, !negated else { return nil }
                isDocumentAllowlist = true
            default:
                guard let types = resourceTypeMap[name] else { return nil }  // option WebKit can't express
                if negated { excludedTypes.formUnion(types) } else { resourceTypes.formUnion(types) }
            }
        }

        if isDocumentAllowlist {
            // `@@||example.com^$document`: turn blocking off for the whole site.
            guard let host = plainHost(pattern) else { return nil }
            var allow = Trigger(urlFilter: ".*")
            allow.ifDomain = ["*" + host]
            return Rule(trigger: allow, action: Action(type: "ignore-previous-rules"))
        }

        if !excludedTypes.isEmpty {
            resourceTypes = (resourceTypes.isEmpty ? allResourceTypes : resourceTypes).subtracting(excludedTypes)
            if resourceTypes.isEmpty { return nil }
        }
        if !resourceTypes.isEmpty { trigger.resourceType = resourceTypes.sorted() }

        let source = caseSensitive ? String(pattern) : pattern.lowercased()
        guard let filter = urlFilter(source) else { return nil }
        // A bare `*` or empty pattern is only acceptable when something else narrows the rule.
        if filter == ".*", trigger.ifDomain == nil, trigger.unlessDomain == nil, trigger.resourceType == nil { return nil }
        trigger.urlFilter = filter
        if caseSensitive { trigger.urlFilterIsCaseSensitive = true }

        return Rule(trigger: trigger, action: Action(type: isException ? "ignore-previous-rules" : "block"))
    }

    /// ABP pattern to a WebKit url-filter (a restricted regex: no `|`, no `{n}`).
    static func urlFilter(_ pattern: String) -> String? {
        var p = Substring(pattern)
        var out = ""
        if p.hasPrefix("||") {
            out = "^[a-z][a-z0-9+.-]*://([^/]*\\.)?"
            p = p.dropFirst(2)
        } else if p.hasPrefix("|") {
            out = "^"
            p = p.dropFirst()
        }
        var anchoredEnd = false
        if p.hasSuffix("|") {
            anchoredEnd = true
            p = p.dropLast()
        }

        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-z0-9_.%-]"
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        if anchoredEnd { out += "$" }
        if out.isEmpty || out == "^" { return ".*" }
        return out
    }

    /// `example.com` from `||example.com^`, or nil if the pattern is not just a host.
    static func plainHost(_ pattern: Substring) -> String? {
        var p = pattern
        guard p.hasPrefix("||") else { return nil }
        p = p.dropFirst(2)
        if p.hasSuffix("^") { p = p.dropLast() }
        let host = p.lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }

    /// Splits `a.com,~b.a.com` into WebKit `if-domain` / `unless-domain` lists (`*` prefix = include subdomains).
    /// WebKit cannot combine both in one trigger, so when positives exist the negatives are dropped.
    static func parseDomains(_ list: String, separator: Character) -> ([String], [String])? {
        var ifs: [String] = []
        var unlesses: [String] = []
        for raw in list.split(separator: separator) {
            let negated = raw.hasPrefix("~")
            let domain = (negated ? raw.dropFirst() : raw).lowercased()
            guard !domain.isEmpty, domain.allSatisfy({ ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "." || $0 == "-" }),
                  !domain.hasSuffix(".") else { continue }
            if negated { unlesses.append("*" + domain) } else { ifs.append("*" + domain) }
        }
        if ifs.isEmpty && unlesses.isEmpty { return nil }
        return (ifs, unlesses)
    }

    static func isSupportedSelector(_ selector: String) -> Bool {
        !selector.isEmpty && selector.allSatisfy(\.isASCII) && !extendedSelectorMarkers.contains(where: selector.contains)
    }

    static let unsupportedMarkers = ["#@#", "#?#", "#$#", "#%#", "#@$#", "#@?#", "$$", "##+js(", "##^", ":style("]
    static let extendedSelectorMarkers = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":matches-css", ":upward(", ":remove(",
        ":min-text-length(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(",
        ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":remove-attr(", ":remove-class(",
    ]

    static let allResourceTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "websocket", "other",
    ]

    static let resourceTypeMap: [String: Set<String>] = [
        "script": ["script"],
        "image": ["image", "svg-document"],
        "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["raw"], "xhr": ["raw"],
        "subdocument": ["document"], "frame": ["document"],
        "websocket": ["websocket"],
        "ping": ["ping"], "beacon": ["ping"],
        "popup": ["popup"],
        "object": ["other"], "object-subrequest": ["other"], "other": ["other"],
    ]

    // MARK: - JSON model

    struct Rule: Encodable, Sendable {
        var trigger: Trigger
        var action: Action
    }

    struct Trigger: Encodable, Sendable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        init(urlFilter: String) { self.urlFilter = urlFilter }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    struct Action: Encodable, Sendable {
        var type: String
        var selector: String?
    }
}
