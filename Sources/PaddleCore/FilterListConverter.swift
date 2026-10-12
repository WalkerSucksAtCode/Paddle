import Foundation

/// Converts Adblock Plus-syntax filter lists (EasyList, EasyPrivacy, uBlock-style basics) into WebKit
/// content rule list JSON. WebKit compiles that JSON once and enforces it natively, with no extension
/// process or per-request JavaScript, which is why blocking stays cheap.
///
/// Supported: `||host^` / `|anchor` / `*` / `^` network rules with common options (`third-party`, `domain=`,
/// resource types, `match-case`), `@@` exceptions (including `$document` site allowlisting), and `##` element
/// hiding (generic and per-domain). Skipped: regex rules, scriptlets, `#@#`, extended selectors, and options
/// WebKit cannot express (`redirect`, `csp`, `removeparam`, ...). Skipped lines are counted, never guessed.
///
/// Cosmetic selectors are joined 32 to a rule. WebKit silently drops a whole `css-display-none` rule when one
/// member of its selector list is invalid, so selectors it would reject are dropped first: `{style}` and
/// `:style(` rules (CSS injection, which must never become `display: none`), nested `:has`, unbalanced
/// brackets or quotes, and, with `validSelectors`, anything WebKit's own parser refuses.
public enum FilterListConverter {
    public static let maxRulesPerList = 150_000
    /// Part of the compiled-list cache key. Bump it whenever the JSON for the same list text changes, so lists
    /// compiled by the previous converter are recompiled instead of loaded from WebKit's cache.
    public static let converterVersion = 2

    public struct Result: Sendable {
        public var json: String
        public var ruleCount: Int
        /// Lines the converter cannot express, not counting the two kinds below.
        public var skippedLines: Int
        /// `##selector {style}` and `:style(` lines: CSS injection, which a block list cannot do.
        public var styleInjection: Int
        /// `##` selectors dropped because WebKit would reject them (and their chunk-mates with them).
        public var invalidSelectors: Int
        public var truncated: Bool
    }

    public static func convert(_ text: String, cosmeticChunkSize: Int = 32) -> Result {
        let parsed = parse(text)
        return assemble(parsed, chunks: cosmeticChunks(parsed, size: cosmeticChunkSize))
    }

    /// `convert` with a last check by the real parser. `validSelectors` gets selector strings and answers one
    /// Bool each (the app asks a web view's `document.querySelector`). It is called twice: once with every
    /// chunk's joined selector list, then once with the single selectors of the chunks that failed, so a
    /// typical list costs two round trips. Only the failing selectors are dropped; an answer of the wrong
    /// length (the check itself failed) accepts everything, which is the unvalidated result.
    public static func convert(
        _ text: String, cosmeticChunkSize: Int = 32, validSelectors: @Sendable ([String]) async -> [Bool]
    ) async -> Result {
        let parsed = parse(text)
        var chunks = cosmeticChunks(parsed, size: cosmeticChunkSize)
        let chunkOK = await validSelectors(chunks.map(\.selectorList))
        guard chunkOK.count == chunks.count else { return assemble(parsed, chunks: chunks) }

        let suspect = chunks.indices.filter { !chunkOK[$0] }
        let singles = suspect.flatMap { chunks[$0].selectors }
        let singleOK = await validSelectors(singles)
        guard singleOK.count == singles.count else { return assemble(parsed, chunks: chunks) }

        var invalid = 0
        var cursor = 0
        for index in suspect {
            let count = chunks[index].selectors.count
            let answers = singleOK[cursor..<cursor + count]
            cursor += count
            chunks[index].selectors = zip(chunks[index].selectors, answers).filter(\.1).map(\.0)
            invalid += answers.count(where: { !$0 })
        }
        chunks.removeAll { $0.selectors.isEmpty }
        return assemble(parsed, chunks: chunks, invalidSelectors: invalid)
    }

    // MARK: - Parsing and assembly

    struct Parsed {
        var blocks: [Rule] = []
        var exceptions: [Rule] = []
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:]
        var domainOrder: [String] = []
        var skipped = 0
        var styleInjection = 0
        var invalidSelectors = 0
    }

    /// One `css-display-none` rule in the making: up to `cosmeticChunkSize` selectors under one trigger.
    struct CosmeticChunk {
        var trigger: Trigger
        var selectors: [String]
        var selectorList: String { selectors.joined(separator: ", ") }
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

            if unsupportedMarkers.contains(where: line.contains) {
                parsed.skipped += 1
                continue
            }

            if let hide = line.range(of: "##") {
                let domains = String(line[..<hide.lowerBound])
                let selector = String(line[hide.upperBound...]).trimmingCharacters(in: .whitespaces)
                switch classifySelector(selector) {
                case .styleInjection: parsed.styleInjection += 1; continue
                case .unsupported: parsed.skipped += 1; continue
                case .invalid: parsed.invalidSelectors += 1; continue
                case .selector: break
                }
                if domains.isEmpty {
                    parsed.genericSelectors.append(selector)
                } else {
                    guard parseDomains(domains, separator: ",") != nil else { parsed.skipped += 1; continue }
                    if parsed.domainSelectors[domains] == nil { parsed.domainOrder.append(domains) }
                    parsed.domainSelectors[domains, default: []].append(selector)
                }
                continue
            }

            guard let rule = networkRule(line) else { parsed.skipped += 1; continue }
            if rule.action.type == "ignore-previous-rules" {
                parsed.exceptions.append(rule)
            } else {
                parsed.blocks.append(rule)
            }
        }
        return parsed
    }

    static func cosmeticChunks(_ parsed: Parsed, size: Int) -> [CosmeticChunk] {
        var chunks: [CosmeticChunk] = []
        let generic = parsed.genericSelectors
        for start in stride(from: 0, to: generic.count, by: size) {
            chunks.append(CosmeticChunk(trigger: Trigger(urlFilter: ".*"), selectors: Array(generic[start..<min(start + size, generic.count)])))
        }
        for key in parsed.domainOrder {
            guard let (ifDomains, unlessDomains) = parseDomains(key, separator: ","),
                  let selectors = parsed.domainSelectors[key] else { continue }
            var trigger = Trigger(urlFilter: ".*")
            if !ifDomains.isEmpty { trigger.ifDomain = ifDomains } else { trigger.unlessDomain = unlessDomains }
            for start in stride(from: 0, to: selectors.count, by: size) {
                chunks.append(CosmeticChunk(trigger: trigger, selectors: Array(selectors[start..<min(start + size, selectors.count)])))
            }
        }
        return chunks
    }

    static func assemble(_ parsed: Parsed, chunks: [CosmeticChunk], invalidSelectors: Int = 0) -> Result {
        let cosmetic = chunks.map { Rule(trigger: $0.trigger, action: Action(type: "css-display-none", selector: $0.selectorList)) }

        // Exceptions must come last: `ignore-previous-rules` only cancels rules listed before it.
        var rules = parsed.blocks + cosmetic
        let room = maxRulesPerList - parsed.exceptions.count
        let truncated = rules.count > room
        if truncated { rules.removeLast(rules.count - room) }
        rules += parsed.exceptions

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        return Result(
            json: String(decoding: data, as: UTF8.self),
            ruleCount: rules.count,
            skippedLines: parsed.skipped,
            styleInjection: parsed.styleInjection,
            invalidSelectors: parsed.invalidSelectors + invalidSelectors,
            truncated: truncated
        )
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

    // MARK: - Selectors

    enum SelectorKind {
        /// A plain CSS selector WebKit can be given.
        case selector
        /// `##selector {style}` or `:style(`: the list wants CSS applied, not the element hidden.
        case styleInjection
        /// Extended (procedural) syntax or non-ASCII text.
        case unsupported
        /// Nested `:has` or unbalanced brackets, parentheses or quotes: WebKit's parser would reject it.
        case invalid
    }

    static func classifySelector(_ selector: String) -> SelectorKind {
        let scan = scanSelector(selector)
        if scan.hasBrace || selector.contains(":style(") { return .styleInjection }
        if selector.isEmpty || !selector.allSatisfy(\.isASCII) || extendedSelectorMarkers.contains(where: selector.contains) {
            return .unsupported
        }
        if !scan.balanced || scan.nestedHas { return .invalid }
        return .selector
    }

    struct SelectorScan {
        var balanced = true
        var hasBrace = false
        var nestedHas = false
    }

    /// One pass over a selector, skipping quoted strings and backslash escapes: are `(` / `[` matched by `)` / `]`
    /// and quotes closed, is there a `{` or `}` (a style block), and does a `:has(` open inside another one?
    static func scanSelector(_ selector: String) -> SelectorScan {
        var scan = SelectorScan()
        var open: [Character] = []
        var hasDepths: [Int] = []
        var quote: Character?
        var escaped = false
        var nextParenIsHas = false

        for index in selector.indices {
            let ch = selector[index]
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
            case "{", "}":
                scan.hasBrace = true
            case "(", "[":
                open.append(ch)
                if ch == "(", nextParenIsHas {
                    if !hasDepths.isEmpty { scan.nestedHas = true }
                    hasDepths.append(open.count)
                }
                nextParenIsHas = false
            case ")", "]":
                guard let last = open.popLast(), last == (ch == ")" ? "(" : "[") else { scan.balanced = false; return scan }
                if hasDepths.last == open.count + 1 { hasDepths.removeLast() }
            case ":":
                nextParenIsHas = selector[selector.index(after: index)...].lowercased().hasPrefix("has(")
            default:
                break
            }
        }
        if quote != nil || escaped || !open.isEmpty { scan.balanced = false }
        return scan
    }

    static let unsupportedMarkers = ["#@#", "#?#", "#$#", "#%#", "#@$#", "#@?#", "$$", "##+js(", "##^"]
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
