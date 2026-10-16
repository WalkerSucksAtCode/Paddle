import Foundation

/// One scriptlet filter line: `domains##+js(name, args…)`, or an exception `domains#@#+js(name, args…)`
/// (`#@#+js()` with nothing inside turns off every scriptlet on its domains).
public struct ScriptletLine: Equatable, Sendable {
    /// nil only for the empty exception `#@#+js()`.
    public var name: ScriptletName?
    public var arguments: [String]
    /// Hosts the line names (`PaddleConfig.normalizedHost` form), each covering its subdomains.
    public var includeDomains: [String] = []
    /// `~host` entries.
    public var excludeDomains: [String] = []
    /// `example.*` entries, as `example`: the name with any public suffix.
    public var includeEntities: [String] = []
    /// `~example.*` entries.
    public var excludeEntities: [String] = []
    public var isException = false

    /// No domain at all: the line applies everywhere.
    public var isGeneric: Bool { includeDomains.isEmpty && includeEntities.isEmpty }
}

/// What a list's scriptlet lines came to, for its status line (like `RuleListSummary` for its block rules).
public struct ScriptletSummary: Codable, Equatable, Sendable {
    public var accepted = 0
    public var exceptions = 0
    /// Names Paddle has no script for.
    public var refusedUnknown = 0
    /// `trusted-*` names in a list not marked trusted, or trusted ones Paddle doesn't implement.
    public var refusedTrusted = 0
    public var malformed = 0
    /// Refused names by how often they appear, most first (at most 10), so the status can say what's missing.
    public var topRefused: [String] = []

    public init() {}

    public static func + (a: ScriptletSummary, b: ScriptletSummary) -> ScriptletSummary {
        var sum = ScriptletSummary()
        sum.accepted = a.accepted + b.accepted
        sum.exceptions = a.exceptions + b.exceptions
        sum.refusedUnknown = a.refusedUnknown + b.refusedUnknown
        sum.refusedTrusted = a.refusedTrusted + b.refusedTrusted
        sum.malformed = a.malformed + b.malformed
        sum.topRefused = Array((a.topRefused + b.topRefused.filter { !a.topRefused.contains($0) }).prefix(10))
        return sum
    }
}

/// Reads uBlock Origin's scriptlet syntax. Lines are data: a line can only pick one of Paddle's own scripts
/// (`ScriptletName`, through its aliases) and hand it strings; anything else is refused with a reason.
public enum ScriptletParser {
    public enum Outcome: Equatable, Sendable {
        case line(ScriptletLine)
        case refusedUnknown(String)
        case refusedTrusted(String)
        case malformed(String)
    }

    /// `trusted-*` scriptlets Paddle implements; they run only from a list the user marks trusted. None yet.
    public static let trustedNames: Set<String> = []

    /// uBlock Origin's short and older names for each scriptlet.
    public static let aliases: [String: ScriptletName] = {
        var map: [String: ScriptletName] = [:]
        for name in ScriptletName.allCases { map[name.rawValue] = name }
        let extra: [ScriptletName: [String]] = [
            .setConstant: ["set"],
            .abortOnPropertyRead: ["aopr"],
            .abortOnPropertyWrite: ["aopw"],
            .abortCurrentScript: ["acs", "acis", "abort-current-inline-script"],
            .abortOnStackTrace: ["aost"],
            .noSetTimeoutIf: ["nostif", "prevent-setTimeout", "setTimeout-defuser"],
            .noSetIntervalIf: ["nosiif", "prevent-setInterval", "setInterval-defuser"],
            .addEventListenerDefuser: ["aeld", "prevent-addEventListener"],
            .noFetchIf: ["prevent-fetch"],
            .noXHRIf: ["prevent-xhr"],
            // `noeval` blocks every eval: noeval-if with no needle.
            .noEvalIf: ["prevent-eval-if", "noeval"],
            .noWindowOpenIf: ["nowoif", "prevent-window-open", "window.open-defuser"],
            .removeAttr: ["ra"],
            .removeClass: ["rc"],
            .removeNodeText: ["rmnt"],
            .nanoSetIntervalBooster: ["nano-sib"],
            .nanoSetTimeoutBooster: ["nano-stb"],
        ]
        for (name, list) in extra { for alias in list { map[alias] = name } }
        return map
    }()

    /// Parses one line; nil when it isn't a scriptlet line. `trusted`: the list may use `trusted-*` scriptlets.
    public static func parse(_ rawLine: String, trusted: Bool = false) -> Outcome? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let isException: Bool
        let marker: Range<String.Index>
        if let range = line.range(of: "#@#+js(") {
            isException = true
            marker = range
        } else if let range = line.range(of: "##+js(") {
            isException = false
            marker = range
        } else {
            return nil
        }
        guard line.hasSuffix(")") else { return .malformed("no closing parenthesis") }
        let inner = String(line[marker.upperBound..<line.index(before: line.endIndex)])
        guard let parts = splitArguments(inner) else { return .malformed("unbalanced quotes") }

        var result = ScriptletLine(name: nil, arguments: [], isException: isException)
        let domainList = String(line[..<marker.lowerBound])
        if !domainList.isEmpty {
            guard parseDomains(domainList, into: &result) else { return .malformed("bad domain list") }
        }
        // An exception that only names `~` sites would read as "everywhere"; Paddle doesn't guess what it means.
        if isException, result.isGeneric, !result.excludeDomains.isEmpty || !result.excludeEntities.isEmpty {
            return .malformed("exception with only negated domains")
        }

        guard let first = parts.first, !first.isEmpty else {
            // `#@#+js()`: every scriptlet off on these domains. `##+js()` means nothing.
            guard isException, parts.count <= 1 else { return .malformed("no scriptlet name") }
            return .line(result)
        }
        var name = first
        if name.hasSuffix(".js") { name.removeLast(3) }
        if name.hasPrefix("trusted-") {
            guard trusted, trustedNames.contains(name) else { return .refusedTrusted(name) }
        }
        guard let canonical = aliases[name] else { return .refusedUnknown(name) }
        result.name = canonical
        result.arguments = Array(parts.dropFirst())
        return .line(result)
    }

    /// Splits `name, a, 'b, c', d\, e` at top-level commas: whitespace around each part is trimmed, `\,` is a
    /// literal comma, and an argument quoted with ', " or ` keeps its commas and loses its quotes (`\` escapes the
    /// quote inside). nil for an unterminated quote.
    static func splitArguments(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var wasQuoted = false
        var chars = Array(text)
        var i = 0
        func finish() {
            parts.append(wasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
            current = ""
            wasQuoted = false
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\", i + 1 < chars.count, chars[i + 1] == q {
                    current.append(q)
                    i += 2
                    continue
                }
                if c == q {
                    quote = nil
                    // Only whitespace may follow a closing quote before the next comma.
                    var j = i + 1
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    guard j == chars.count || chars[j] == "," else { return nil }
                    i = j
                    continue
                }
                current.append(c)
                i += 1
                continue
            }
            switch c {
            case "\\" where i + 1 < chars.count && chars[i + 1] == ",":
                current.append(",")
                i += 2
            case ",":
                finish()
                i += 1
                // Skip spaces after the comma, so a quote can open the next part.
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            case "'", "\"", "`":
                // A quote opens an argument only at its start; elsewhere it is an ordinary character.
                if current.trimmingCharacters(in: .whitespaces).isEmpty {
                    quote = c
                    wasQuoted = true
                    current = ""
                } else {
                    current.append(c)
                }
                i += 1
            default:
                current.append(c)
                i += 1
            }
        }
        guard quote == nil else { return nil }
        chars.removeAll()
        if !current.isEmpty || wasQuoted || !parts.isEmpty { finish() }
        return parts
    }

    /// `a.com,~b.a.com,shop.*,~test.*` into the line's domain lists. False when an entry isn't a host or entity
    /// (uBO's `/regex/` domains included).
    private static func parseDomains(_ list: String, into line: inout ScriptletLine) -> Bool {
        for raw in list.split(separator: ",", omittingEmptySubsequences: false) {
            var entry = raw.trimmingCharacters(in: .whitespaces)
            let negated = entry.hasPrefix("~")
            if negated { entry.removeFirst() }
            guard !entry.isEmpty else { return false }
            if entry.hasSuffix(".*") {
                let name = PaddleConfig.normalizedHost(String(entry.dropLast(2)))
                guard isHost(name) else { return false }
                if negated { line.excludeEntities.append(name) } else { line.includeEntities.append(name) }
            } else {
                let host = PaddleConfig.normalizedHost(entry)
                guard isHost(host) else { return false }
                if negated { line.excludeDomains.append(host) } else { line.includeDomains.append(host) }
            }
        }
        return true
    }

    private static func isHost(_ text: String) -> Bool { PaddleConfig.isPlainHost(text) }
}

/// A scriptlet to run: what `ScriptletLibrary` builds one user script from. Empty `includeDomains` and
/// `includeEntities` mean every site, minus the excludes.
public struct ScriptletRule: Equatable, Hashable, Sendable {
    public var name: ScriptletName
    public var arguments: [String]
    public var includeDomains: [String]
    public var excludeDomains: [String]
    public var includeEntities: [String]
    public var excludeEntities: [String]

    public var isGeneric: Bool { includeDomains.isEmpty && includeEntities.isEmpty }

    public init(
        name: ScriptletName, arguments: [String], includeDomains: [String] = [], excludeDomains: [String] = [],
        includeEntities: [String] = [], excludeEntities: [String] = []
    ) {
        self.name = name
        self.arguments = arguments
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.includeEntities = includeEntities
        self.excludeEntities = excludeEntities
    }
}

public enum ScriptletSet {
    /// Scriptlets the lists ask for, after exceptions (as uBO applies them, across lists):
    /// - `#@#+js(name, args)` on domains stops that exact scriptlet there; no domains: everywhere.
    /// - `#@#+js()` on domains stops every scriptlet there.
    /// Same name, arguments and excludes merge into one rule. `lists`: each list's text and whether it is trusted.
    public static func rules(from lists: [(text: String, trusted: Bool)]) -> (rules: [ScriptletRule], summaries: [ScriptletSummary]) {
        var lines: [ScriptletLine] = []
        var exceptions: [ScriptletLine] = []
        var summaries: [ScriptletSummary] = []
        for list in lists {
            var summary = ScriptletSummary()
            var refused: [String: Int] = [:]
            for raw in list.text.split(whereSeparator: \.isNewline) {
                let text = String(raw)
                if text.hasPrefix("!") { continue }
                guard let outcome = ScriptletParser.parse(text, trusted: list.trusted) else { continue }
                switch outcome {
                case .line(let line) where line.isException:
                    summary.exceptions += 1
                    exceptions.append(line)
                case .line(let line):
                    summary.accepted += 1
                    lines.append(line)
                case .refusedUnknown(let name):
                    summary.refusedUnknown += 1
                    refused[name, default: 0] += 1
                case .refusedTrusted(let name):
                    summary.refusedTrusted += 1
                    refused[name, default: 0] += 1
                case .malformed:
                    summary.malformed += 1
                }
            }
            summary.topRefused = refused.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(10).map(\.key)
            summaries.append(summary)
        }
        return (merge(lines.compactMap { apply(exceptions, to: $0) }), summaries)
    }

    /// The line after every exception that touches it, as a rule; nil when nothing is left of it.
    static func apply(_ exceptions: [ScriptletLine], to line: ScriptletLine) -> ScriptletRule? {
        guard let name = line.name else { return nil }
        var rule = ScriptletRule(
            name: name, arguments: line.arguments, includeDomains: line.includeDomains, excludeDomains: line.excludeDomains,
            includeEntities: line.includeEntities, excludeEntities: line.excludeEntities
        )
        for exception in exceptions where exception.name == nil || (exception.name == name && exception.arguments == line.arguments) {
            if exception.isGeneric { return nil }
            let wasGeneric = rule.isGeneric
            for domain in exception.includeDomains {
                // An included host the exception covers goes; one that covers the exception's host (or an entity,
                // which may) keeps running but not there.
                let covered = rule.includeDomains.filter { hostKey(domain, covers: $0) }
                rule.includeDomains.removeAll { covered.contains($0) }
                if wasGeneric || !rule.includeEntities.isEmpty || rule.includeDomains.contains(where: { hostKey($0, covers: domain) }) {
                    if !rule.excludeDomains.contains(domain) { rule.excludeDomains.append(domain) }
                }
            }
            for entity in exception.includeEntities {
                rule.includeEntities.removeAll { $0 == entity }
                // `shop.*` also stops the rule on `shop.com`, `www.shop.co.uk` and the like.
                rule.includeDomains.removeAll { entityCovers(host: $0, entity: entity) }
                if wasGeneric, !rule.excludeEntities.contains(entity) { rule.excludeEntities.append(entity) }
            }
            if !wasGeneric, rule.isGeneric { return nil }
        }
        return rule
    }

    /// Same scriptlet, arguments and excludes: one rule with the union of the sites. Generic rules stay as they are.
    static func merge(_ rules: [ScriptletRule]) -> [ScriptletRule] {
        var order: [ScriptletRule] = []
        var index: [MergeKey: Int] = [:]
        for rule in rules {
            if rule.isGeneric {
                if !order.contains(rule) { order.append(rule) }
                continue
            }
            let key = MergeKey(name: rule.name, arguments: rule.arguments, excludeDomains: rule.excludeDomains, excludeEntities: rule.excludeEntities)
            if let at = index[key] {
                for domain in rule.includeDomains where !order[at].includeDomains.contains(domain) { order[at].includeDomains.append(domain) }
                for entity in rule.includeEntities where !order[at].includeEntities.contains(entity) { order[at].includeEntities.append(entity) }
            } else {
                index[key] = order.count
                order.append(rule)
            }
        }
        return order
    }

    private struct MergeKey: Hashable {
        let name: ScriptletName
        let arguments: [String]
        let excludeDomains: [String]
        let excludeEntities: [String]
    }

    /// `key` is `host` or a parent domain of it.
    static func hostKey(_ key: String, covers host: String) -> Bool {
        host == key || host.hasSuffix("." + key)
    }

    /// `host` is `entity.<suffix>` or a subdomain of one, with the same approximate suffix rule as the dispatcher's
    /// `entityCovers`: one label, or two when the first is short (`co.uk`, `com.au`) or `gouv`.
    static func entityCovers(host: String, entity: String) -> Bool {
        let labels = host.split(separator: ".").map(String.init)
        let entityLabels = entity.split(separator: ".").map(String.init)
        for start in labels.indices {
            let rest = Array(labels[start...])
            guard rest.starts(with: entityLabels) else { continue }
            let suffix = rest.dropFirst(entityLabels.count)
            if suffix.count == 1 { return true }
            if suffix.count == 2, let first = suffix.first, first.count <= 3 || first == "gouv" { return true }
        }
        return false
    }
}
