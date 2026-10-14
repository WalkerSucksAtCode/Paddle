import Foundation

/// Test-only model of how WebKit applies a content-rule list: the JSON that `FilterListConverter.convert` writes.
///
/// Semantics (the oracle depends on each of them):
/// - Rules apply in array order. A matching `block` marks the request blocked. A matching `ignore-previous-rules`
///   clears every earlier match, so blocked becomes false; a later matching block sets it again.
/// - `css-display-none` rules are cosmetic and skipped entirely. Other action types are ignored.
/// - `Decision.decidingRule` is the first block still in effect: matched, and not cleared by a later matching ignore.
/// - `url-filter` is a regular expression searched anywhere in the full request URL (anchored only by `^` or `$` in
///   the pattern). It is case-insensitive unless `url-filter-is-case-sensitive` is true. A pattern that does not
///   compile, or a rule with no url-filter, never matches; both are counted in `stats`.
/// - `resource-type`, `load-context`, `load-type`, `if-domain` and `unless-domain` must all hold when present.
/// - `load-context`: a `sub_frame` request is `child-frame`; every other request is `top-frame`.
/// - `load-type`: third-party when the registrable domain of the request host differs from that of the source host
///   (see `registrableDomain`, which approximates the Public Suffix List).
/// - `if-domain` / `unless-domain` are matched against the host of `sourceURL`, lowercased. An entry with a leading `*`
///   matches that domain and every subdomain of it; an entry without `*` matches the host exactly.
///
/// `evaluate` uses a token index; `evaluateBruteForce` tries every rule. Both share `ruleMatches`, so when they
/// disagree the index has dropped a rule that matches.
final class WebKitRuleEvaluator {
    /// One request as the oracle describes it.
    struct Request: Sendable {
        var url: String
        /// The top-level document URL (uBO's `sourceUrl`).
        var sourceURL: String
        /// WebKit's resource-type name, as `webKitType(uboType:)` gives it.
        var resourceType: String
        var isChildFrame: Bool

        init(url: String, sourceURL: String = "https://site.test/", resourceType: String = "script", isChildFrame: Bool = false) {
            self.url = url
            self.sourceURL = sourceURL
            self.resourceType = resourceType
            self.isChildFrame = isChildFrame
        }
    }

    struct Decision: Equatable, Sendable {
        var blocked: Bool
        /// Index of the deciding block in the original rule array (nil when not blocked).
        var decidingRule: Int?
        /// The deciding block's url-filter (nil when not blocked).
        var decidingURLFilter: String?
    }

    /// What was loaded and how the index was built.
    struct Stats: Sendable {
        var totalRules = 0
        /// `css-display-none` rules, skipped.
        var cosmetic = 0
        /// Actions other than block, ignore-previous-rules and css-display-none, ignored.
        var otherActions = 0
        /// Block and ignore rules that can never match (no url-filter, or a regex that does not compile).
        var neverMatching = 0
        var invalidRegex = 0
        /// Block and ignore rules that take part in evaluation.
        var evaluated = 0
        /// Evaluated rules with a token key.
        var indexed = 0
        /// Evaluated rules with no usable token: checked against every request.
        var fallback = 0
        /// Evaluated rules whose url-filter is `.*`.
        var wildcard = 0
        var wholeKeys = 0
        var prefixKeys = 0
        var suffixKeys = 0
    }

    enum EvaluatorError: Error {
        case notARuleArray
    }

    /// The uBO resource type's WebKit name. nil for a type the oracle does not know.
    static func webKitType(uboType: String) -> String? {
        switch uboType {
        case "image": "image"
        case "script": "script"
        case "xmlhttprequest": "raw"
        case "sub_frame": "document"
        case "stylesheet": "style-sheet"
        case "font": "font"
        case "media": "media"
        case "other": "other"
        default: nil
        }
    }

    /// Public suffixes of two labels that make the registrable domain three labels long. A small built-in stand-in
    /// for the Public Suffix List: `registrableDomain` is right for these and for ordinary `.com`/`.net`-style hosts,
    /// and approximate for every other suffix.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "com.au", "co.jp", "co.nz", "com.br", "co.in", "org.uk", "ac.uk", "gov.uk", "com.cn", "com.tw",
        "co.kr", "com.mx", "com.ar", "com.tr", "co.za", "ne.jp", "or.jp",
    ]

    private(set) var stats = Stats()

    private let rules: [Rule]
    /// Token -> positions in `rules`, for a token that is a whole alphanumeric run of the URL.
    private let whole: [String: [Int]]
    /// Token -> positions, for a token that starts an alphanumeric run of the URL (followed by more alphanumerics).
    private let prefix: [String: [Int]]
    /// Token -> positions, for a token that ends an alphanumeric run of the URL (preceded by more alphanumerics).
    private let suffix: [String: [Int]]
    private let prefixLengths: Set<Int>
    private let suffixLengths: Set<Int>
    /// Positions of rules with no token: candidates for every request.
    private let fallback: [Int]
    /// Per-rule generation stamp, so a request collects each candidate once.
    private var stamp: [Int]
    private var generation = 0

    convenience init(json: String) throws {
        guard let objects = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw EvaluatorError.notARuleArray
        }
        self.init(rules: objects)
    }

    /// Builds the rule list and the token index. Rules that can never match are dropped (and counted).
    init(rules objects: [[String: Any]]) {
        var stats = Stats()
        stats.totalRules = objects.count
        var evaluated: [Rule] = []
        for (index, object) in objects.enumerated() {
            let type = (object["action"] as? [String: Any])?["type"] as? String ?? ""
            let kind: Rule.Kind
            switch type {
            case "block": kind = .block
            case "ignore-previous-rules": kind = .ignorePrevious
            case "css-display-none": stats.cosmetic += 1; continue
            default: stats.otherActions += 1; continue
            }
            let trigger = object["trigger"] as? [String: Any] ?? [:]
            guard let urlFilter = trigger["url-filter"] as? String else {
                stats.neverMatching += 1
                continue
            }
            let caseSensitive = trigger["url-filter-is-case-sensitive"] as? Bool ?? false
            let matchesEveryURL = urlFilter == ".*"
            var regex: NSRegularExpression?
            if !matchesEveryURL {
                regex = try? NSRegularExpression(pattern: urlFilter, options: caseSensitive ? [] : [.caseInsensitive])
                guard regex != nil else {
                    stats.neverMatching += 1
                    stats.invalidRegex += 1
                    continue
                }
            }
            if matchesEveryURL { stats.wildcard += 1 }
            evaluated.append(Rule(
                index: index,
                kind: kind,
                urlFilter: urlFilter,
                matchesEveryURL: matchesEveryURL,
                regex: regex,
                resourceTypes: (trigger["resource-type"] as? [String]).map { Set($0) },
                loadContexts: (trigger["load-context"] as? [String]).map { Set($0) },
                loadTypes: (trigger["load-type"] as? [String]).map { Set($0) },
                ifDomains: (trigger["if-domain"] as? [String])?.map(DomainEntry.init),
                unlessDomains: (trigger["unless-domain"] as? [String])?.map(DomainEntry.init)
            ))
        }

        var whole: [String: [Int]] = [:]
        var prefix: [String: [Int]] = [:]
        var suffix: [String: [Int]] = [:]
        var prefixLengths: Set<Int> = []
        var suffixLengths: Set<Int> = []
        var fallback: [Int] = []
        for (position, rule) in evaluated.enumerated() {
            switch Self.indexKey(for: rule.urlFilter) {
            case .whole(let token)?: whole[token, default: []].append(position)
            case .prefix(let token)?:
                prefix[token, default: []].append(position)
                prefixLengths.insert(token.utf8.count)
            case .suffix(let token)?:
                suffix[token, default: []].append(position)
                suffixLengths.insert(token.utf8.count)
            case nil: fallback.append(position)
            }
        }
        stats.evaluated = evaluated.count
        stats.fallback = fallback.count
        stats.indexed = evaluated.count - fallback.count
        stats.wholeKeys = whole.count
        stats.prefixKeys = prefix.count
        stats.suffixKeys = suffix.count

        self.stats = stats
        self.rules = evaluated
        self.whole = whole
        self.prefix = prefix
        self.suffix = suffix
        self.prefixLengths = prefixLengths
        self.suffixLengths = suffixLengths
        self.fallback = fallback
        self.stamp = Array(repeating: 0, count: evaluated.count)
    }

    /// The decision for `request`, using the token index to skip rules that cannot match its URL.
    func evaluate(_ request: Request) -> Decision {
        let prepared = Self.prepare(request)
        let folded = Self.fold(request.url)
        generation += 1
        var candidates: [Int] = []
        func take(_ positions: [Int]?) {
            for position in positions ?? [] where stamp[position] != generation {
                stamp[position] = generation
                candidates.append(position)
            }
        }
        take(fallback)
        // Every match contains each indexed token as a piece of the URL, and the token is a whole run, a prefix of a
        // run or a suffix of a run (see `indexKey`). Probing all runs and their prefixes/suffixes finds them all.
        var start = 0
        while start < folded.count {
            guard Self.isAlnum(folded[start]) else {
                start += 1
                continue
            }
            var end = start
            while end < folded.count, Self.isAlnum(folded[end]) { end += 1 }
            let length = end - start
            if length >= 3 {
                take(whole[Self.key(folded, start, end)])
                for n in 3...length {
                    if prefixLengths.contains(n) { take(prefix[Self.key(folded, start, start + n)]) }
                    if suffixLengths.contains(n) { take(suffix[Self.key(folded, end - n, end)]) }
                }
            }
            start = end
        }
        candidates.sort()
        return decide(candidates, prepared)
    }

    /// The decision for `request` after trying every rule in order. The reference for `evaluate`.
    func evaluateBruteForce(_ request: Request) -> Decision {
        decide(rules.indices, Self.prepare(request))
    }

    /// True when the indexed and brute-force decisions agree for `request`.
    func indexedMatchesBruteForce(_ request: Request) -> Bool {
        evaluate(request) == evaluateBruteForce(request)
    }

    /// The registrable domain (eTLD+1) of `host`: the last two labels, or three when the last two are in
    /// `multiLabelSuffixes`. IP addresses and single-label hosts are their own domain. Approximates the PSL.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let isIPAddress = host.contains(":") || labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard labels.count > 2, !isIPAddress else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return multiLabelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// The lowercased host of `url`: the text after `scheme://` up to the first `/`, `?` or `#`, without userinfo,
    /// port or a trailing dot. Empty when the URL has no `://`.
    static func host(of url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return "" }
        var authority = url[schemeEnd.upperBound...].prefix { !"/?#".contains($0) }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        let host: Substring
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = authority[...close]
        } else {
            host = authority.prefix { $0 != ":" }
        }
        var result = host.lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    // MARK: - Rules

    private struct Rule {
        enum Kind { case block, ignorePrevious }

        let index: Int
        let kind: Kind
        let urlFilter: String
        /// `url-filter` is `.*`: every URL matches, so no regex runs.
        let matchesEveryURL: Bool
        let regex: NSRegularExpression?
        let resourceTypes: Set<String>?
        let loadContexts: Set<String>?
        let loadTypes: Set<String>?
        let ifDomains: [DomainEntry]?
        let unlessDomains: [DomainEntry]?
    }

    /// One `if-domain` / `unless-domain` entry, lowercased. `*example.com` matches the domain and its subdomains.
    struct DomainEntry: Sendable {
        let domain: String
        let includesSubdomains: Bool

        init(_ entry: String) {
            let lowered = entry.lowercased()
            includesSubdomains = lowered.hasPrefix("*")
            var base = includesSubdomains ? String(lowered.dropFirst()) : lowered
            if base.hasPrefix(".") { base.removeFirst() }
            domain = base
        }

        func matches(_ host: String) -> Bool {
            if includesSubdomains {
                return host == domain || host.hasSuffix("." + domain)
            }
            return host == domain
        }
    }

    /// The request fields the rules read, computed once per evaluation.
    private struct Prepared {
        let url: String
        let utf16Count: Int
        let resourceType: String
        let isChildFrame: Bool
        let isThirdParty: Bool
        let sourceHost: String
    }

    private enum IndexKey: Equatable {
        case whole(String)
        case prefix(String)
        case suffix(String)
    }

    private static func prepare(_ request: Request) -> Prepared {
        let requestHost = host(of: request.url)
        let sourceHost = host(of: request.sourceURL)
        return Prepared(
            url: request.url,
            utf16Count: request.url.utf16.count,
            resourceType: request.resourceType,
            isChildFrame: request.isChildFrame,
            isThirdParty: registrableDomain(requestHost) != registrableDomain(sourceHost),
            sourceHost: sourceHost
        )
    }

    /// Applies the rules at `positions` (ascending) to `request`. The first block still in effect is the decider.
    private func decide<S: Sequence>(_ positions: S, _ request: Prepared) -> Decision where S.Element == Int {
        var deciding: Int?
        for position in positions {
            let rule = rules[position]
            guard Self.ruleMatches(rule, request) else { continue }
            switch rule.kind {
            case .block:
                if deciding == nil { deciding = position }
            case .ignorePrevious:
                deciding = nil
            }
        }
        guard let deciding else {
            return Decision(blocked: false, decidingRule: nil, decidingURLFilter: nil)
        }
        return Decision(blocked: true, decidingRule: rules[deciding].index, decidingURLFilter: rules[deciding].urlFilter)
    }

    /// True when every condition of `rule` holds for `request`. Cheap trigger conditions run before the regex.
    private static func ruleMatches(_ rule: Rule, _ request: Prepared) -> Bool {
        if let types = rule.resourceTypes, !types.contains(request.resourceType) { return false }
        if let contexts = rule.loadContexts, !contexts.contains(request.isChildFrame ? "child-frame" : "top-frame") {
            return false
        }
        if let types = rule.loadTypes, !types.contains(request.isThirdParty ? "third-party" : "first-party") {
            return false
        }
        if let domains = rule.ifDomains, !domains.contains(where: { $0.matches(request.sourceHost) }) { return false }
        if let domains = rule.unlessDomains, domains.contains(where: { $0.matches(request.sourceHost) }) { return false }
        if rule.matchesEveryURL { return true }
        guard let regex = rule.regex else { return false }
        return regex.firstMatch(in: request.url, options: [], range: NSRange(location: 0, length: request.utf16Count)) != nil
    }

    // MARK: - Token index

    /// The index key for a url-filter, or nil when no token is usable. A token is a run of at least three
    /// alphanumerics taken from a run of literal characters, where the literal characters are required in every match.
    /// The token is:
    /// - `whole` when a literal non-alphanumeric character bounds it on both sides: in any match the URL has the token
    ///   as a complete alphanumeric run.
    /// - `prefix` when only the left side is bounded: the URL has the token at the start of a run.
    /// - `suffix` when only the right side is bounded: the URL has the token at the end of a run.
    /// A token bounded on neither side is not used. Tokens are lowercased; for a case-sensitive rule that only adds
    /// candidates, and the regex still decides. The longest usable token wins; a whole token wins a tie.
    private static func indexKey(for pattern: String) -> IndexKey? {
        guard let runs = literalRuns(pattern) else { return nil }
        var best: (score: Int, key: IndexKey)?
        for run in runs {
            var start = 0
            while start < run.count {
                guard isAlnum(run[start]) else {
                    start += 1
                    continue
                }
                var end = start
                while end < run.count, isAlnum(run[end]) { end += 1 }
                let length = end - start
                let leftBounded = start > 0
                let rightBounded = end < run.count
                if length >= 3, leftBounded || rightBounded {
                    let token = String(decoding: run[start..<end].map(lowerASCII), as: UTF8.self)
                    let key: IndexKey = leftBounded && rightBounded ? .whole(token) : leftBounded ? .prefix(token) : .suffix(token)
                    var isWhole = false
                    if case .whole = key { isWhole = true }
                    let score = length * 2 + (isWhole ? 1 : 0)
                    if best.map({ score > $0.score }) ?? true {
                        best = (score, key)
                    }
                }
                start = end
            }
        }
        return best?.key
    }

    /// The runs of plain literal bytes that every match of `pattern` contains, in order. A run is broken by anything
    /// that is not a plain literal: a class, a group, `{...}`, an anchor, `.`, an escape of a letter or digit, or a
    /// literal followed by `*`, `+`, `?` or `{` (it need not occur). nil when the pattern has a top-level `|`.
    /// Constructs outside this list (for example `\Q...\E` quoting) are not recognised; the converter never emits them.
    static func literalRuns(_ pattern: String) -> [[UInt8]]? {
        let bytes = Array(pattern.utf8)
        var runs: [[UInt8]] = []
        var run: [UInt8] = []
        var depth = 0
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            var width = 1
            var literal: UInt8?
            switch c {
            case UInt8(ascii: "\\"):
                if i + 1 < bytes.count {
                    width = 2
                    let escaped = bytes[i + 1]
                    if depth == 0, isPlainLiteral(escaped), !isAlnum(escaped) { literal = escaped }
                }
            case UInt8(ascii: "["):
                width = classWidth(bytes, from: i)
            case UInt8(ascii: "{"):
                width = braceWidth(bytes, from: i)
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth = max(0, depth - 1)
            case UInt8(ascii: "|"):
                if depth == 0 { return nil }
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"), UInt8(ascii: "."), UInt8(ascii: "^"),
                 UInt8(ascii: "$"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                break
            default:
                if depth == 0, isPlainLiteral(c) { literal = c }
            }
            if literal != nil, i + width < bytes.count, isQuantifier(bytes[i + width]) {
                literal = nil
            }
            if let value = literal {
                run.append(value)
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
            i += width
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    /// Lowercased ASCII of `url`, one byte per character. Each non-ASCII scalar becomes the ASCII letter it
    /// case-folds to (`K` sign to `k`, long s to `s`), or a space, which is not alphanumeric.
    static func fold(_ url: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(url.utf8.count)
        for scalar in url.unicodeScalars {
            if scalar.isASCII {
                out.append(lowerASCII(UInt8(scalar.value)))
            } else {
                out.append(asciiFold(scalar) ?? 0x20)
            }
        }
        return out
    }

    private static func asciiFold(_ scalar: Unicode.Scalar) -> UInt8? {
        for mapping in [scalar.properties.lowercaseMapping, scalar.properties.uppercaseMapping] {
            if let first = mapping.unicodeScalars.first, first.isASCII {
                return lowerASCII(UInt8(first.value))
            }
        }
        return nil
    }

    private static func key(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func lowerASCII(_ c: UInt8) -> UInt8 {
        (65...90).contains(c) ? c + 32 : c
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c)
    }

    /// Printable ASCII: a literal the regex matches as itself.
    private static func isPlainLiteral(_ c: UInt8) -> Bool {
        (0x20...0x7E).contains(c)
    }

    private static func isQuantifier(_ c: UInt8) -> Bool {
        c == UInt8(ascii: "*") || c == UInt8(ascii: "+") || c == UInt8(ascii: "?") || c == UInt8(ascii: "{")
    }

    /// Length of the character class starting at `start` (`[`), through its closing `]`.
    private static func classWidth(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start + 1
        if j < bytes.count, bytes[j] == UInt8(ascii: "^") { j += 1 }
        if j < bytes.count, bytes[j] == UInt8(ascii: "]") { j += 1 }
        while j < bytes.count, bytes[j] != UInt8(ascii: "]") {
            j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
        }
        return min(j + 1, bytes.count) - start
    }

    /// Length of the `{...}` quantifier starting at `start`, through its `}`.
    private static func braceWidth(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start + 1
        while j < bytes.count, bytes[j] != UInt8(ascii: "}") { j += 1 }
        return min(j + 1, bytes.count) - start
    }
}
