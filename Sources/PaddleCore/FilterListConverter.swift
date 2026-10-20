import Foundation

/// Converts Adblock Plus-syntax filter lists (EasyList, EasyPrivacy, uBlock-style basics) into WebKit
/// content rule list JSON. WebKit compiles the JSON once and enforces it natively: no extension process,
/// no per-request JavaScript.
///
/// Supported: `||host^` / `|anchor` / `*` / `^` network rules with common options (`third-party`, `domain=`,
/// resource types, `match-case`, `important`), `/regex/` rules `RegexTranslator` can rewrite exactly, `@@`
/// exceptions (including `$document` site allowlisting), `##` hiding (generic and per-domain) and `#@#`
/// exceptions. Skipped: scriptlets, extended selectors, and options WebKit cannot express (`redirect`, `csp`,
/// `removeparam`, `replace=/…/`, ...). Skipped lines and refused regex are counted, never guessed.
///
/// `subdocument` / `frame` become WebKit's `document` type limited to `load-context: child-frame`; a bare
/// `document` would also block navigating to the site. Same for the `document` part of a rule with only
/// negated types (`$~script`).
///
/// `##` and `#@#` selector lists split on top-level commas, so `site#@#.b` excepts the `.b` of `##.a, .b`.
///
/// A `#@#` exception moves its generic selector into its own `unless-domain` rule. A per-domain `##` that
/// a `#@#` touches (same domain, parent, or subdomain) is dropped for that domain list: WebKit cannot
/// express "this domain but not that subdomain" in one trigger, and hiding too little beats hiding on a
/// site that opted out.
///
/// WebKit applies `ignore-previous-rules` only inside one compiled list, so exceptions that must reach
/// every list (the user's `@@` and `#@#`, sites with blocking off) arrive as `SharedExceptions` and are
/// appended to each.
///
/// Cosmetic selectors are joined 32 to a rule. WebKit silently drops a whole `css-display-none` rule when
/// one selector is invalid, so rejects are dropped first: `{style}` and `:style(` (CSS injection, never
/// `display: none`), nested `:has`, unbalanced brackets or quotes, and, with `validSelectors`, anything
/// WebKit's parser refuses.
public enum FilterListConverter {
    public static let maxRulesPerList = 150_000
    /// Part of the compiled-list cache key. Bump it whenever the JSON for the same list text changes, so lists
    /// compiled by the previous converter are recompiled instead of loaded from WebKit's cache.
    public static let converterVersion = 8

    public struct Result: Sendable {
        public var json: String
        public var ruleCount: Int
        /// Lines the converter cannot express, by reason. Not counting the two kinds below.
        public var skips: SkipBreakdown
        /// Every skipped line (`skips.total`).
        public var skippedLines: Int { skips.total }
        /// `##selector {style}` and `:style(` lines: CSS injection, which a block list cannot do.
        public var styleInjection: Int
        /// `##` selectors dropped because WebKit would reject them (and their chunk-mates with them).
        public var invalidSelectors: Int
        /// `/regex/` lines turned into rules (one or more each), and those `RegexTranslator` refused.
        public var regexTranslated: Int
        public var regexRefused: Int
        public var truncated: Bool
        /// Some rule in `json` came from a `/regex/` line (the list's or a shared exception).
        public var containsRegexRules: Bool
    }

    /// The lines `convert` left out, by the reason it could not express them. Every skipped line counts under exactly
    /// one reason, so `total` is the number of skipped lines.
    public struct SkipBreakdown: Codable, Equatable, Sendable {
        /// `##+js(` and `#@#+js(` lines. Paddle's scriptlet engine runs the names it has while `scriptlets` is on.
        public var scriptlets: Int
        /// Procedural (extended) selectors: `#?#`, `#@?#`, `:has-text(`, `:-abp-`, `:xpath(` and the like.
        public var extendedSelectors: Int
        /// Options WebKit can't express (`redirect`, `csp`, `removeparam`, `replace`, `header`, `generichide`, ...), tallied
        /// by name. `document` on a block rule is tallied as `document`; `$document` on an exception whose pattern is not a
        /// site (a path, a bare word) as `document (not a site)`.
        public var options: [String: Int]
        /// HTML filtering (`$$`, `##^`), CSS and script injection markers (`#$#`, `#%#`), text WebKit can't take (non-ASCII),
        /// and domain lists WebKit can't take (entity wildcards such as `amazon.*`).
        public var other: Int
        /// Lines with no usable form: an empty selector, an exception with only negated domains, a bare `*`, a negated
        /// `domain=` option, or an option list that leaves no resource type.
        public var malformed: Int

        public init(
            scriptlets: Int = 0, extendedSelectors: Int = 0, options: [String: Int] = [:], other: Int = 0, malformed: Int = 0
        ) {
            self.scriptlets = scriptlets
            self.extendedSelectors = extendedSelectors
            self.options = options
            self.other = other
            self.malformed = malformed
        }

        /// A missing key reads as zero, so a sidecar written before a reason existed still decodes.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scriptlets = try c.decodeIfPresent(Int.self, forKey: .scriptlets) ?? 0
            extendedSelectors = try c.decodeIfPresent(Int.self, forKey: .extendedSelectors) ?? 0
            options = try c.decodeIfPresent([String: Int].self, forKey: .options) ?? [:]
            other = try c.decodeIfPresent(Int.self, forKey: .other) ?? 0
            malformed = try c.decodeIfPresent(Int.self, forKey: .malformed) ?? 0
        }

        /// Every skipped line: the sum of the reasons.
        public var total: Int { scriptlets + extendedSelectors + options.values.reduce(0, +) + other + malformed }
    }

    /// Why one line is skipped: one bucket of `SkipBreakdown`.
    enum SkipReason: Equatable, Sendable {
        case scriptlet
        case extended
        case option(String)
        case other
        case malformed
    }

    /// `dropRegex` leaves out every rule made from a `/regex/` line, the list's and the shared exceptions': the
    /// fallback when WebKit refuses a list over one of them.
    public static func convert(
        _ text: String, cosmeticChunkSize: Int = 32, shared: SharedExceptions = .none, dropRegex: Bool = false
    ) -> Result {
        let parsed = parse(text, shared: shared)
        return assemble(parsed, chunks: cosmeticChunks(parsed, size: cosmeticChunkSize), shared: shared, dropRegex: dropRegex)
    }

    /// `convert` plus a last check by the real parser. `validSelectors` answers one Bool per selector
    /// (the app uses a web view's `document.querySelector`). Called twice: every chunk's joined list,
    /// then the single selectors of failing chunks (two round trips). Only failing selectors are
    /// dropped; a wrong-length answer accepts everything (the unvalidated result).
    public static func convert(
        _ text: String, cosmeticChunkSize: Int = 32, shared: SharedExceptions = .none, dropRegex: Bool = false,
        validSelectors: @Sendable ([String]) async -> [Bool]
    ) async -> Result {
        let parsed = parse(text, shared: shared)
        var chunks = cosmeticChunks(parsed, size: cosmeticChunkSize)
        let chunkOK = await validSelectors(chunks.map(\.selectorList))
        guard chunkOK.count == chunks.count else { return assemble(parsed, chunks: chunks, shared: shared, dropRegex: dropRegex) }

        let suspect = chunks.indices.filter { !chunkOK[$0] }
        let singles = suspect.flatMap { chunks[$0].selectors }
        let singleOK = await validSelectors(singles)
        guard singleOK.count == singles.count else { return assemble(parsed, chunks: chunks, shared: shared, dropRegex: dropRegex) }

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
        return assemble(parsed, chunks: chunks, shared: shared, invalidSelectors: invalid, dropRegex: dropRegex)
    }

    /// The skipped lines of `text` by reason: the parse `convert` does, without building WebKit rules or JSON. Gives
    /// a summary saved before the breakdown existed its breakdown; the counts are the same as `convert`'s.
    public static func skipBreakdown(_ text: String) -> SkipBreakdown {
        parse(text).skips
    }

    // MARK: - Parsing and assembly

    struct Parsed {
        var blocks: [Rule] = []
        /// `$important` blocks: placed after the list's own exceptions, so those cannot cancel them.
        var importantBlocks: [Rule] = []
        var exceptions: [Rule] = []
        var genericSelectors: [String] = []
        var domainSelectors: [String: [String]] = [:]
        var domainOrder: [String] = []
        /// `#@#` exceptions: selector to the domains (`*domain`) it must not hide on, and selectors excepted everywhere.
        var cosmeticExceptions: [String: [String]] = [:]
        var globalExceptions: Set<String> = []
        var skips = SkipBreakdown()
        var styleInjection = 0
        var invalidSelectors = 0
        var regexTranslated = 0
        var regexRefused = 0

        mutating func addCosmeticException(_ selector: String, domains: [String]) {
            guard !domains.isEmpty else { return }
            var list = cosmeticExceptions[selector, default: []]
            for domain in domains where !list.contains(domain) { list.append(domain) }
            cosmeticExceptions[selector] = list
        }

        mutating func skip(_ reason: SkipReason) {
            switch reason {
            case .scriptlet: skips.scriptlets += 1
            case .extended: skips.extendedSelectors += 1
            case .option(let name): skips.options[name, default: 0] += 1
            case .other: skips.other += 1
            case .malformed: skips.malformed += 1
            }
        }
    }

    /// One `css-display-none` rule in the making: up to `cosmeticChunkSize` selectors under one trigger.
    struct CosmeticChunk {
        var trigger: Trigger
        var selectors: [String]
        var selectorList: String { selectors.joined(separator: ", ") }
    }

    static func parse(_ text: String, shared: SharedExceptions = .none) -> Parsed {
        var parsed = Parsed()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

            if let marker = unsupportedMarkers.first(where: { line.contains($0.marker) }) {
                parsed.skip(marker.reason)
                continue
            }

            // Before `##`: `example.com#@##ad` contains both.
            if let except = line.range(of: "#@#") {
                let domains = String(line[..<except.lowerBound])
                let selector = String(line[except.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !selector.isEmpty else { parsed.skip(.malformed); continue }
                // Split like the `##` side, so `#@#.b` meets the `.b` of `##.a, .b`; anything else is kept whole.
                let selectors = classifySelector(selector) == .selector ? selectorList(selector) : [selector]
                if domains.isEmpty {
                    parsed.globalExceptions.formUnion(selectors)
                } else {
                    // Only positive domains say where not to hide; a `~` entry in an exception means nothing here.
                    // `~a.com#@#x` has no positive domain: an empty `unless-domain` would make WebKit reject the list.
                    // Entity wildcards (`amazon.*`) and other domains WebKit can't take are `other`; only an exception
                    // with nothing but negated domains is malformed.
                    guard let (ifDomains, _) = parseDomains(domains, separator: ",") else { parsed.skip(.other); continue }
                    guard !ifDomains.isEmpty else { parsed.skip(.malformed); continue }
                    for selector in selectors { parsed.addCosmeticException(selector, domains: ifDomains) }
                }
                continue
            }

            if let hide = line.range(of: "##") {
                let domains = String(line[..<hide.lowerBound])
                let selector = String(line[hide.upperBound...]).trimmingCharacters(in: .whitespaces)
                switch classifySelector(selector) {
                case .styleInjection: parsed.styleInjection += 1; continue
                case .skipped(let reason): parsed.skip(reason); continue
                case .invalid: parsed.invalidSelectors += 1; continue
                case .selector: break
                }
                let selectors = selectorList(selector)
                if domains.isEmpty {
                    parsed.genericSelectors += selectors
                } else {
                    guard parseDomains(domains, separator: ",") != nil else { parsed.skip(.other); continue }
                    if parsed.domainSelectors[domains] == nil { parsed.domainOrder.append(domains) }
                    parsed.domainSelectors[domains, default: []] += selectors
                }
                continue
            }

            let rules: [Rule]
            switch networkRules(line) {
            case .unsupported(let reason): parsed.skip(reason); continue
            case .refusedRegex: parsed.regexRefused += 1; continue
            case .rules(let made): rules = made
            case .regex(let made): rules = made; parsed.regexTranslated += 1
            }
            for rule in rules {
                if rule.action.type == "ignore-previous-rules" {
                    parsed.exceptions.append(rule)
                } else if rule.isImportant {
                    parsed.importantBlocks.append(rule)
                } else {
                    parsed.blocks.append(rule)
                }
            }
        }

        parsed.globalExceptions.formUnion(shared.globalCosmetic)
        for (selector, domains) in shared.cosmetic { parsed.addCosmeticException(selector, domains: domains) }
        return parsed
    }

    static func cosmeticChunks(_ parsed: Parsed, size: Int) -> [CosmeticChunk] {
        var chunks: [CosmeticChunk] = []
        // Selectors with `#@#` exceptions, each in a rule of its own that skips the excepted domains.
        var excepted: [CosmeticChunk] = []
        var exceptedKeys: Set<[String]> = []
        func except(_ selector: String, unless domains: [String]) {
            guard exceptedKeys.insert([selector] + domains).inserted else { return }
            var trigger = Trigger(urlFilter: ".*")
            trigger.unlessDomain = domains
            excepted.append(CosmeticChunk(trigger: trigger, selectors: [selector]))
        }

        var generic: [String] = []
        for selector in parsed.genericSelectors where !parsed.globalExceptions.contains(selector) {
            if let domains = parsed.cosmeticExceptions[selector] { except(selector, unless: domains) } else { generic.append(selector) }
        }
        for start in stride(from: 0, to: generic.count, by: size) {
            chunks.append(CosmeticChunk(trigger: Trigger(urlFilter: ".*"), selectors: Array(generic[start..<min(start + size, generic.count)])))
        }
        for key in parsed.domainOrder {
            guard let (ifDomains, unlessDomains) = parseDomains(key, separator: ","),
                  let all = parsed.domainSelectors[key] else { continue }
            var trigger = Trigger(urlFilter: ".*")
            if !ifDomains.isEmpty { trigger.ifDomain = ifDomains } else { trigger.unlessDomain = unlessDomains }
            var selectors: [String] = []
            for selector in all where !parsed.globalExceptions.contains(selector) {
                guard let domains = parsed.cosmeticExceptions[selector] else { selectors.append(selector); continue }
                if ifDomains.isEmpty {
                    // `~a.com##x` with `b.com#@#x`: hide everywhere except both.
                    except(selector, unless: unlessDomains + domains.filter { !unlessDomains.contains($0) })
                } else if !domains.contains(where: { exception in ifDomains.contains { domainsOverlap($0, exception) } }) {
                    selectors.append(selector)  // the exception is for other sites
                }
            }
            for start in stride(from: 0, to: selectors.count, by: size) {
                chunks.append(CosmeticChunk(trigger: trigger, selectors: Array(selectors[start..<min(start + size, selectors.count)])))
            }
        }
        return chunks + excepted
    }

    /// True when two `*domain` entries are the same domain or one is a subdomain of the other.
    static func domainsOverlap(_ a: String, _ b: String) -> Bool {
        let a = a.hasPrefix("*") ? String(a.dropFirst()) : a
        let b = b.hasPrefix("*") ? String(b.dropFirst()) : b
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// `maxRules` is `maxRulesPerList` except in tests, which drive truncation with a small cap.
    static func assemble(
        _ parsed: Parsed, chunks: [CosmeticChunk], shared: SharedExceptions = .none, invalidSelectors: Int = 0,
        dropRegex: Bool = false, maxRules: Int = maxRulesPerList
    ) -> Result {
        let cosmetic = chunks.map { Rule(trigger: $0.trigger, action: Action(type: "css-display-none", selector: $0.selectorList)) }
        func kept(_ rules: [Rule]) -> [Rule] { dropRegex ? rules.filter { !$0.isRegex } : rules }

        // `ignore-previous-rules` only cancels rules listed before it, so the order is: ordinary blocks and hiding,
        // the list's own exceptions and the other lists', `$important` blocks (which those exceptions must not
        // cancel), then the shared exceptions (the user's, and sites with blocking off), which beat everything.
        var ordinary = kept(parsed.blocks) + cosmetic
        var important = kept(parsed.importantBlocks)
        // Other lists' exceptions only cancel blocks; a list without any (an empty user-filters.txt) skips them.
        let blocksAnything = !ordinary.isEmpty || !important.isEmpty
        var exceptions = kept(parsed.exceptions) + (blocksAnything ? kept(shared.listRules) : [])
        var sharedRules = kept(shared.userRules) + shared.siteRules
        // Over the cap, rules go from the end of the ordinary ones first; the rest only if those were not enough.
        var excess = ordinary.count + important.count + exceptions.count + sharedRules.count - maxRules
        let truncated = excess > 0
        func trim(_ rules: inout [Rule]) {
            let n = min(max(excess, 0), rules.count)
            rules.removeLast(n)
            excess -= n
        }
        trim(&ordinary)
        trim(&important)
        trim(&exceptions)
        trim(&sharedRules)
        let rules = ordinary + exceptions + important + sharedRules

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        return Result(
            json: String(decoding: data, as: UTF8.self),
            ruleCount: rules.count,
            skips: parsed.skips,
            styleInjection: parsed.styleInjection,
            invalidSelectors: parsed.invalidSelectors + invalidSelectors,
            regexTranslated: parsed.regexTranslated,
            regexRefused: parsed.regexRefused,
            truncated: truncated,
            containsRegexRules: rules.contains(where: \.isRegex)
        )
    }

    // MARK: - Network rules

    /// What one network line becomes.
    enum NetworkRules {
        case rules([Rule])
        /// A `/regex/` line, one rule per url-filter `RegexTranslator` gave.
        case regex([Rule])
        case refusedRegex(RegexTranslator.Refusal)
        case unsupported(SkipReason)
    }

    static func networkRules(_ line: String) -> NetworkRules {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        var pattern = body
        var options: [Substring] = []
        if let dollar = body.lastIndex(of: "$"), case let tail = body[body.index(after: dollar)...], !tail.isEmpty, !tail.contains("/") {
            // Options rarely contain "/", URL paths almost always do. Unknown options reject the rule below.
            pattern = body[..<dollar]
            options = tail.split(separator: ",")
        } else if let option = optionWithSlash(body) {
            // `$replace=/a/b/`, `$header=…/…`, `$csp=… https://…`: options WebKit can't express, not a URL path.
            return .unsupported(.option(option))
        }

        let isRegex = pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/")
        guard pattern.allSatisfy(\.isASCII) else { return isRegex ? .refusedRegex(.nonASCII) : .unsupported(.other) }

        var trigger = Trigger(urlFilter: "")
        var caseSensitive = false
        var resourceTypes: Set<String> = []
        var excludedTypes: Set<String> = []
        var isDocumentAllowlist = false
        var isImportant = false
        var framesOnly = false
        /// A positive type option was given; if they all map to no WebKit type (`$object`), the rule has no form.
        var typeListed = false

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
                guard !negated, let value else { return .unsupported(.malformed) }
                guard let (ifs, unlesses) = parseDomains(value, separator: "|") else { return .unsupported(.other) }
                if !ifs.isEmpty { trigger.ifDomain = ifs } else { trigger.unlessDomain = unlesses }
            case "match-case":
                caseSensitive = true
            case "important":
                isImportant = !isException
            case "document", "doc":
                guard isException, !negated else { return .unsupported(.option("document")) }
                isDocumentAllowlist = true
            default:
                guard let types = resourceTypeMap[name] else { return .unsupported(.option(optionKey(name))) }  // option WebKit can't express
                if negated { excludedTypes.formUnion(types) } else { resourceTypes.formUnion(types); typeListed = true }
                if !negated, name == "subdocument" || name == "frame" { framesOnly = true }
            }
        }

        if isDocumentAllowlist {
            // `@@||example.com^$document`: turn blocking off for the whole site. Any other constraint (domain,
            // party, type) cannot be kept, and allowing the whole site would over-apply the exception.
            if trigger.loadType != nil || trigger.ifDomain != nil || trigger.unlessDomain != nil
                || !resourceTypes.isEmpty || !excludedTypes.isEmpty {
                return .unsupported(.option("document (with other options)"))
            }
            guard let host = plainHost(pattern) else { return .unsupported(.option("document (not a site)")) }
            return .rules([siteAllowRule(host)])
        }

        // Only plugin types (`$object`): WebKit has no plugin type, and without one the rule would block every type.
        if typeListed, resourceTypes.isEmpty { return .unsupported(.option("object")) }

        if !excludedTypes.isEmpty {
            // `$~script` means every other type a page loads, frames included but not the page itself.
            if resourceTypes.isEmpty { framesOnly = true }
            resourceTypes = (resourceTypes.isEmpty ? allResourceTypes : resourceTypes).subtracting(excludedTypes)
            if resourceTypes.isEmpty { return .unsupported(.malformed) }
        }
        if !resourceTypes.isEmpty { trigger.resourceType = resourceTypes.sorted() }
        if caseSensitive { trigger.urlFilterIsCaseSensitive = true }
        // A bare `*` or empty pattern is only acceptable when something else narrows the rule.
        let narrowed = trigger.ifDomain != nil || trigger.unlessDomain != nil || trigger.resourceType != nil
        let action = Action(type: isException ? "ignore-previous-rules" : "block")

        // WebKit's `document` type is the page itself as well as its frames; `subdocument` means only frames.
        // `load-context` narrows the whole trigger, so the rule's other types get a trigger of their own.
        var triggers = [trigger]
        if framesOnly, let types = trigger.resourceType, types.contains("document") {
            var frames = trigger
            frames.resourceType = ["document"]
            frames.loadContext = ["child-frame"]
            let otherTypes = types.filter { $0 != "document" }
            var others = trigger
            others.resourceType = otherTypes
            triggers = otherTypes.isEmpty ? [frames] : [others, frames]
        }

        if isRegex {
            // Not lowercased: `\W` is not `\w`. WebKit matches case-insensitively unless `match-case` says otherwise.
            switch RegexTranslator.translate(String(pattern.dropFirst().dropLast())) {
            case .failure(let refusal): return .refusedRegex(refusal)
            case .success(let filters):
                if filters.contains(".*"), !narrowed { return .refusedRegex(.matchesEverything) }
                return .regex(filters.flatMap { filter in
                    triggers.map { trigger in
                        var regexTrigger = trigger
                        regexTrigger.urlFilter = filter
                        return Rule(trigger: regexTrigger, action: action, isRegex: true, isImportant: isImportant)
                    }
                })
            }
        }

        let source = caseSensitive ? String(pattern) : pattern.lowercased()
        guard let filter = urlFilter(source, caseSensitive: caseSensitive) else { return .unsupported(.other) }
        // A pattern of only `|`, `*` and `^` (`||`, `^`, `**`) has nothing to match on: it would block every load.
        if !narrowed, filter == ".*" || !source.contains(where: { !"|*^".contains($0) }) { return .unsupported(.malformed) }
        return .rules(triggers.map { trigger in
            var trigger = trigger
            trigger.urlFilter = filter
            return Rule(trigger: trigger, action: action, isImportant: isImportant)
        })
    }

    /// Blocking off on `host` and its subdomains: every earlier rule of the list is ignored on their pages.
    static func siteAllowRule(_ host: String) -> Rule {
        var allow = Trigger(urlFilter: ".*")
        allow.ifDomain = ["*" + host]
        return Rule(trigger: allow, action: Action(type: "ignore-previous-rules"))
    }

    /// The first known option name in `body` whose option text (after a `$`) contains "/", nil if none.
    static func optionWithSlash(_ body: Substring) -> String? {
        var index = body.startIndex
        while let dollar = body[index...].firstIndex(of: "$") {
            let tail = body[body.index(after: dollar)...]
            if tail.contains("/") {
                let first = tail.prefix { $0 != "," && $0 != "=" }
                let name = String(first.hasPrefix("~") ? first.dropFirst() : first)
                if optionNames.contains(name) { return name }
            }
            index = body.index(after: dollar)
        }
        return nil
    }

    /// The name an unsupported option is tallied under: bounded in length, and "(empty)" for a bare `=` or `~`.
    static func optionKey(_ name: String) -> String {
        name.isEmpty ? "(empty)" : String(name.prefix(40))
    }

    /// ABP pattern to a WebKit url-filter (a restricted regex: no `|`, no `{n}`). `caseSensitive` (`match-case`)
    /// keeps uppercase letters out of what `^` matches, as the case-insensitive class does implicitly.
    static func urlFilter(_ pattern: String, caseSensitive: Bool = false) -> String? {
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

        let separator = caseSensitive ? "[^a-zA-Z0-9_.%-]" : "[^a-z0-9_.%-]"
        // A closing `^` also matches the end of the URL (`||example.com/collect^` blocks `.../collect` itself). WebKit
        // has no `|`, so it becomes "a separator and anything after it, or nothing", then the end.
        let separatorEnds = !anchoredEnd && p.hasSuffix("^")
        if separatorEnds { p = p.dropLast() }
        // `||host^` (about 99,000 of EasyList + EasyPrivacy's 112,000 network rules) needs no end case: WebKit
        // normalizes every http(s) URL to have a path, so a `/` or `:` always follows the host. The optional
        // `(separator.*)?$` tail on that many rules made the compiled lists 74 MB instead of 43 MB and cost ~250 ms of
        // first paint on a news page (2026-10-16, measured in a bare WKWebView with only the network rules).
        if separatorEnds, out.hasPrefix("^[a-z]"), plainHost(p) != nil {
            for ch in p { out += ch == "." ? "\\." : String(ch) }
            return out + separator
        }

        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += separator
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(ch)
            default: out.append(ch)
            }
        }
        if separatorEnds { out += "(\(separator).*)?$" }
        if anchoredEnd { out += "$" }
        if out.isEmpty || out == "^" { return ".*" }
        return out
    }

    /// `example.com` from `||example.com^`, `example.com^` or `example.com` (a `$document` allowlist), or nil if
    /// the pattern is not just a host. Without `||` it needs a dot, so a bare word is never taken for a site.
    static func plainHost(_ pattern: Substring) -> String? {
        var p = pattern
        let anchored = p.hasPrefix("||")
        if anchored { p = p.dropFirst(2) }
        if p.hasSuffix("^") { p = p.dropLast() }
        let host = p.lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        if !anchored, !host.contains(".") || host.hasPrefix(".") || host.hasSuffix(".") { return nil }
        return host
    }

    /// Splits `a.com,~b.a.com` into WebKit `if-domain` / `unless-domain` lists (`*` prefix = include subdomains).
    /// WebKit cannot combine both in one trigger, so when positives exist the negatives are dropped, which is
    /// only right when each negative lies outside every positive. A negative that equals or sits under a positive
    /// (`a.com|~b.a.com`), or an invalid negative (`~amazon.*`), has no form: nil, so the rule is skipped.
    static func parseDomains(_ list: String, separator: Character) -> ([String], [String])? {
        var ifs: [String] = []
        var unlesses: [String] = []
        for raw in list.split(separator: separator) {
            let negated = raw.hasPrefix("~")
            let domain = (negated ? raw.dropFirst() : raw).lowercased()
            guard !domain.isEmpty, domain.allSatisfy({ ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "." || $0 == "-" }),
                  !domain.hasSuffix(".") else {
                if negated { return nil }
                continue
            }
            if negated { unlesses.append("*" + domain) } else { ifs.append("*" + domain) }
        }
        if ifs.isEmpty && unlesses.isEmpty { return nil }
        if unlesses.contains(where: { negative in ifs.contains { negative == $0 || negative.hasSuffix("." + $0.dropFirst()) } }) {
            return nil
        }
        return (ifs, unlesses)
    }

    // MARK: - Selectors

    enum SelectorKind: Equatable {
        /// A plain CSS selector WebKit can be given.
        case selector
        /// `##selector {style}` or `:style(`: the list wants CSS applied, not the element hidden.
        case styleInjection
        /// Left out, for the reason given: extended (procedural) syntax, non-ASCII text, or an empty selector.
        case skipped(SkipReason)
        /// Nested `:has`, unbalanced brackets, parentheses or quotes, or an empty member of a selector list:
        /// WebKit's parser would reject it.
        case invalid
    }

    static func classifySelector(_ selector: String) -> SelectorKind {
        let scan = scanSelector(selector)
        if scan.hasBrace || scan.hasStyle { return .styleInjection }
        if selector.isEmpty { return .skipped(.malformed) }
        if extendedSelectorMarkers.contains(where: scan.unquoted.contains) { return .skipped(.extended) }
        if !selector.allSatisfy(\.isASCII) { return .skipped(.other) }
        // A CSS comment opener would swallow the selectors joined after it.
        if scan.unquoted.contains("/*") || scan.unquoted.contains("*/") { return .invalid }
        if !scan.balanced || scan.nestedHas { return .invalid }
        if split(selector, at: scan.topLevelCommas).contains(where: \.isEmpty) { return .invalid }
        return .selector
    }

    /// The members of a selector list (`.a, .b`), split on commas outside quotes, parentheses and brackets.
    static func selectorList(_ selector: String) -> [String] {
        split(selector, at: scanSelector(selector).topLevelCommas)
    }

    static func split(_ selector: String, at commas: [String.Index]) -> [String] {
        var pieces: [String] = []
        var start = selector.startIndex
        for comma in commas {
            pieces.append(selector[start..<comma].trimmingCharacters(in: .whitespaces))
            start = selector.index(after: comma)
        }
        pieces.append(selector[start...].trimmingCharacters(in: .whitespaces))
        return pieces
    }

    struct SelectorScan {
        var balanced = true
        var hasBrace = false
        /// A `:style(` outside quoted strings.
        var hasStyle = false
        var nestedHas = false
        var topLevelCommas: [String.Index] = []
        /// The selector without its quoted strings and escapes, where extended-syntax markers are looked for.
        var unquoted = ""
    }

    /// One pass over a selector, skipping quoted strings and backslash escapes: are `(` / `[` matched by `)` / `]`
    /// and quotes closed, is there a `{` or `}` or a `:style(` (a style rule), does a `:has(` open inside another
    /// one, where are the commas that separate a selector list, and what is the text outside quoted strings?
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
            scan.unquoted.append(ch)
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
            case ",":
                if open.isEmpty { scan.topLevelCommas.append(index) }
            case ":":
                let rest = selector[selector.index(after: index)...]
                nextParenIsHas = rest.prefix(4).lowercased() == "has("
                if rest.prefix(6).lowercased() == "style(" { scan.hasStyle = true }
            default:
                break
            }
        }
        if quote != nil || escaped || !open.isEmpty { scan.balanced = false }
        return scan
    }

    /// Lines left out because of a marker the converter doesn't read, and why. The first marker found decides.
    static let unsupportedMarkers: [(marker: String, reason: SkipReason)] = [
        ("##+js(", .scriptlet), ("#@#+js(", .scriptlet),
        ("#?#", .extended), ("#@?#", .extended),
        ("#$#", .other), ("#@$#", .other), ("#%#", .other), ("$$", .other), ("##^", .other),
    ]
    static let extendedSelectorMarkers = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":matches-css", ":upward(", ":remove(",
        ":min-text-length(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(",
        ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":remove-attr(", ":remove-class(",
    ]

    /// Every option name the converter knows, supported or not: a `$` followed by one starts the options.
    static let optionNames: Set<String> = Set(resourceTypeMap.keys).union([
        "third-party", "3p", "first-party", "1p", "domain", "from", "match-case", "important", "document", "doc",
        "redirect", "redirect-rule", "csp", "removeparam", "queryprune", "replace", "header", "removeheader", "permissions",
        "urltransform", "uritransform", "urlskip", "method", "to", "denyallow", "rewrite", "cookie", "jsonprune",
        "xmlprune", "hls", "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide", "genericblock",
        "badfilter", "all", "inline-script", "inline-font", "empty", "mp4", "webrtc", "strict1p", "strict3p",
    ])

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
        // Plugins (`object`) have no WebKit type and are gone from browsers; `other` would also catch unrelated loads.
        "object": [], "object-subrequest": [], "other": ["other"],
    ]

    // MARK: - JSON model

    struct Rule: Encodable, Sendable {
        var trigger: Trigger
        var action: Action
        /// Made from a `/regex/` line, so `dropRegex` leaves it out. Not part of the JSON, like `isImportant`.
        var isRegex = false
        /// A `$important` block, placed after the list's own exceptions.
        var isImportant = false

        enum CodingKeys: String, CodingKey {
            case trigger, action
        }
    }

    struct Trigger: Encodable, Sendable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var loadContext: [String]?

        init(urlFilter: String) { self.urlFilter = urlFilter }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case loadContext = "load-context"
        }
    }

    struct Action: Encodable, Sendable {
        var type: String
        var selector: String?
    }
}

/// Exceptions that must reach every compiled block list, not only the one they are written in. WebKit applies
/// `ignore-previous-rules` within a single list, so an `@@` line in `user-filters.txt` could not cancel EasyList's
/// blocks on its own; appended to the end of every list, it does. Carries the user's `@@` rules and `#@#` lines, and
/// one site-wide exception per host with blocking off.
public struct SharedExceptions: Sendable {
    /// `ignore-previous-rules` rules from the user's `@@` lines.
    var userRules: [FilterListConverter.Rule] = []
    /// One per host in `blockingOffHosts`.
    var siteRules: [FilterListConverter.Rule] = []
    /// The other filter lists' `@@` network exceptions (EasyList's, for EasyPrivacy). uBlock Origin applies every list's
    /// exceptions to every list's blocks; WebKit doesn't, so each list carries the others'. They go with the list's own
    /// exceptions, before its `$important` blocks, which no exception cancels.
    var listRules: [FilterListConverter.Rule] = []
    /// The user's `#@#` lines, as `Parsed` keeps them.
    var cosmetic: [String: [String]] = [:]
    var globalCosmetic: Set<String> = []

    public static let none = SharedExceptions()

    init() {}

    /// The exceptions in `userFilters` (the text of `user-filters.txt`), plus blocking off on each of
    /// `blockingOffHosts` and its subdomains (per-site "content blocking off"; keys as in `sites`).
    public init(userFilters: String, blockingOffHosts: [String] = []) {
        let parsed = FilterListConverter.parse(userFilters)
        userRules = parsed.exceptions
        cosmetic = parsed.cosmeticExceptions
        globalCosmetic = parsed.globalExceptions
        let hosts = Set(blockingOffHosts.map(PaddleConfig.normalizedHost)).filter(PaddleConfig.isPlainHost)
        siteRules = hosts.sorted().map(FilterListConverter.siteAllowRule)
    }

    /// What `user-filters.txt` itself needs: the site exceptions and the lists' exceptions, since its own `@@` and
    /// `#@#` lines are in it.
    public var forUserFilters: SharedExceptions {
        var own = SharedExceptions()
        own.siteRules = siteRules
        own.listRules = listRules
        return own
    }

    /// One filter list's `@@` network exceptions, for `adding(_:)`.
    public struct ListExceptions: Sendable {
        var rules: [FilterListConverter.Rule]
    }

    /// The `@@` network exceptions in `text` (a filter list): `$document` site allowlists included, cosmetic `#@#` lines not.
    public static func listExceptions(in text: String) -> ListExceptions {
        ListExceptions(rules: FilterListConverter.parse(text).exceptions)
    }

    /// The `@@` lines of a filter list, in order, joined by newlines: everything `listExceptions(in:)` reads, without
    /// parsing. Cheap enough for a cache key, so a list's update recompiles the other lists only when these change.
    public static func exceptionLines(in text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("@@") }
            .joined(separator: "\n")
    }

    /// These exceptions plus other filter lists' (see `listRules`).
    public func adding(_ lists: [ListExceptions]) -> SharedExceptions {
        var shared = self
        shared.listRules += lists.flatMap(\.rules)
        return shared
    }

    var rules: [FilterListConverter.Rule] { userRules + siteRules }

    public var isEmpty: Bool {
        userRules.isEmpty && siteRules.isEmpty && listRules.isEmpty && cosmetic.isEmpty && globalCosmetic.isEmpty
    }

    /// Stable text that changes whenever what these exceptions add to a list changes; part of the compiled-list
    /// cache key, so editing an `@@` line recompiles every list. Empty when there are none.
    public var fingerprint: String {
        guard !isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rulesJSON = (try? encoder.encode(rules + listRules)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let cosmeticLines = cosmetic.keys.sorted().map { "\($0)\t\(cosmetic[$0, default: []].joined(separator: ","))" }
        return ([rulesJSON] + cosmeticLines + globalCosmetic.sorted().map { "*\t\($0)" }).joined(separator: "\n")
    }
}
