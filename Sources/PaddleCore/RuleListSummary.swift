import Foundation

/// What one block list turned into: how many WebKit rules, and which lines were left out. Saved next to the
/// compiled list as `compiled-rules/<identifier>.json`, so a list loaded from cache reports the same counts as
/// a fresh compile. `statusLine` is the text the Content Blocking status and the Reload Config alert show.
public struct RuleListSummary: Codable, Sendable, Equatable {
    /// WebKit rules after conversion (cosmetic rules are chunked, so this is not a line count).
    public var ruleCount: Int
    /// Lines the converter could not express (scriptlets, unsupported options or selectors): the total of `skips`
    /// when `hasSkipBreakdown`.
    public var skipped: Int
    /// Why each skipped line was left out. A sidecar written before the breakdown existed decodes with zeros, and
    /// `hasSkipBreakdown` says so.
    public var skips: FilterListConverter.SkipBreakdown
    /// `!` comment and `[Adblock …]` header lines.
    public var commentLines: Int
    /// The list hit `FilterListConverter.maxRulesPerList` and lost rules from its end.
    public var truncated: Bool
    /// `##selector {style}` and `:style(` lines, which inject CSS rather than hide; never converted.
    public var styleInjection: Int
    /// `##` selectors dropped because WebKit would have rejected them (and silently dropped their chunk-mates).
    public var invalidSelectors: Int
    /// `/regex/` lines rewritten as url-filters, and those refused (no exact url-filter equivalent).
    public var regexTranslated: Int
    public var regexRefused: Int
    /// Why WebKit refused the converted JSON, when it did. Saved so the list is not converted again on every
    /// load just to fail the same way; the sidecar is keyed by list text and converter version, so a change to
    /// either retries.
    public var compileFailure: String?
    /// Why WebKit refused the list with its regex rules, when it compiled only once they were left out
    /// (`FilterListConverter.convert(dropRegex:)`). The list is installed without them.
    public var regexDropped: String?

    /// Nothing to install: no rules, or WebKit refused them. Such lists are remembered by sidecar alone.
    public var installable: Bool { ruleCount > 0 && compileFailure == nil }

    /// Whether `skips` accounts for every skipped line. False only for a sidecar written before the breakdown existed.
    public var hasSkipBreakdown: Bool { skips.total == skipped }

    public init(
        ruleCount: Int, skipped: Int, commentLines: Int, truncated: Bool,
        styleInjection: Int = 0, invalidSelectors: Int = 0, regexTranslated: Int = 0, regexRefused: Int = 0,
        compileFailure: String? = nil, regexDropped: String? = nil, skips: FilterListConverter.SkipBreakdown = .init()
    ) {
        self.ruleCount = ruleCount
        self.skipped = skipped
        self.commentLines = commentLines
        self.truncated = truncated
        self.styleInjection = styleInjection
        self.invalidSelectors = invalidSelectors
        self.regexTranslated = regexTranslated
        self.regexRefused = regexRefused
        self.compileFailure = compileFailure
        self.regexDropped = regexDropped
        self.skips = skips
    }

    /// The summary of `text` converted into `result`; comment lines are counted from `text`.
    public init(text: String, result: FilterListConverter.Result) {
        self.init(
            ruleCount: result.ruleCount,
            skipped: result.skippedLines,
            commentLines: Self.commentLineCount(text),
            truncated: result.truncated,
            styleInjection: result.styleInjection,
            invalidSelectors: result.invalidSelectors,
            regexTranslated: result.regexTranslated,
            regexRefused: result.regexRefused,
            skips: result.skips
        )
    }

    /// Sidecars written before the selector, regex and skip counts existed decode with zeros, so cached lists keep their line.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ruleCount = try c.decode(Int.self, forKey: .ruleCount)
        skipped = try c.decode(Int.self, forKey: .skipped)
        commentLines = try c.decode(Int.self, forKey: .commentLines)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        styleInjection = try c.decodeIfPresent(Int.self, forKey: .styleInjection) ?? 0
        invalidSelectors = try c.decodeIfPresent(Int.self, forKey: .invalidSelectors) ?? 0
        regexTranslated = try c.decodeIfPresent(Int.self, forKey: .regexTranslated) ?? 0
        regexRefused = try c.decodeIfPresent(Int.self, forKey: .regexRefused) ?? 0
        compileFailure = try c.decodeIfPresent(String.self, forKey: .compileFailure)
        regexDropped = try c.decodeIfPresent(String.self, forKey: .regexDropped)
        skips = try c.decodeIfPresent(FilterListConverter.SkipBreakdown.self, forKey: .skips) ?? .init()
    }

    /// Lines the converter ignores as comments: the same test it uses (`!` or `[` after trimming spaces).
    public static func commentLineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).count(where: { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("!") || line.hasPrefix("[")
        })
    }

    /// "easylist: 61,234 rules (1,830 lines unsupported; 40 style rules; 3 invalid selectors; regex: 8 translated,
    /// 14 refused; cached)", "easylist: 61,220 rules (regex: 8 translated, 0 refused; regex rules left out: WebKit
    /// refused them (invalid or unsupported regular expression))",
    /// "user-filters: empty", "user-filters: 0 rules (4 comment lines; 2 lines unsupported)",
    /// "user-filters: failed to compile (invalid or unsupported regular expression)".
    public func statusLine(name: String, cached: Bool, locale: Locale = .current) -> String {
        func count(_ n: Int, _ singular: String, _ plural: String) -> String {
            Self.countText(n, singular, plural, locale: locale)
        }
        if let compileFailure { return "\(name): failed to compile (\(compileFailure))" }
        if ruleCount == 0, skipped == 0, commentLines == 0, styleInjection == 0, invalidSelectors == 0, regexRefused == 0 {
            return "\(name): empty"
        }

        var notes: [String] = []
        if truncated { notes.append("truncated") }
        if ruleCount == 0, commentLines > 0 { notes.append(count(commentLines, "comment line", "comment lines")) }
        if skipped > 0 { notes.append(count(skipped, "line unsupported", "lines unsupported")) }
        if styleInjection > 0 { notes.append(count(styleInjection, "style rule", "style rules")) }
        if invalidSelectors > 0 { notes.append(count(invalidSelectors, "invalid selector", "invalid selectors")) }
        if regexTranslated > 0 || regexRefused > 0 {
            let n = { (value: Int) in value.formatted(.number.locale(locale)) }
            notes.append("regex: \(n(regexTranslated)) translated, \(n(regexRefused)) refused")
        }
        if let regexDropped { notes.append("regex rules left out: WebKit refused them (\(regexDropped))") }
        if cached, ruleCount > 0 { notes.append("cached") }
        let head = "\(name): \(count(ruleCount, "rule", "rules"))"
        return notes.isEmpty ? head : "\(head) (\(notes.joined(separator: "; ")))"
    }

    /// "Not covered: 812 options WebKit can't express (redirect 300, removeparam 120, csp 40, …), 140 extended selectors,
    /// 40 style rules, 13 regex rules (no exact WebKit form)": what this list leaves out, by reason, for the Activity
    /// popover. Scriptlet lines are listed only while `scriptletsOn` is false, since then nothing runs them. nil when
    /// nothing is left out.
    public func notCoveredText(scriptletsOn: Bool, locale: Locale = .current) -> String? {
        func count(_ n: Int, _ singular: String, _ plural: String) -> String {
            Self.countText(n, singular, plural, locale: locale)
        }
        var items: [String] = []
        let optionLines = skips.options.values.reduce(0, +)
        if optionLines > 0 {
            let ranked = skips.options.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let shown = ranked.prefix(3).map { "\($0.key) \($0.value.formatted(.number.locale(locale)))" }
            let more = ranked.count > 3 ? ", …" : ""
            items.append("\(count(optionLines, "option", "options")) WebKit can't express (\(shown.joined(separator: ", "))\(more))")
        }
        if skips.extendedSelectors > 0 { items.append(count(skips.extendedSelectors, "extended selector", "extended selectors")) }
        if invalidSelectors > 0 { items.append("\(count(invalidSelectors, "invalid selector", "invalid selectors")) (WebKit refuses them)") }
        if styleInjection > 0 { items.append(count(styleInjection, "style rule", "style rules")) }
        if regexRefused > 0 { items.append("\(count(regexRefused, "regex rule", "regex rules")) (no exact WebKit form)") }
        if skips.other > 0 {
            items.append("\(count(skips.other, "line", "lines")) of other syntax (entity domains like amazon.*, HTML filtering, injection markers)")
        }
        if skips.malformed > 0 { items.append(count(skips.malformed, "malformed line", "malformed lines")) }
        if !scriptletsOn, skips.scriptlets > 0 {
            items.append("\(count(skips.scriptlets, "scriptlet line", "scriptlet lines")) (Run the lists' scriptlets is off)")
        }
        return items.isEmpty ? nil : "Not covered: " + items.joined(separator: ", ")
    }

    /// What this list's scriptlet lines do while `scriptlets` is on: Paddle's scriptlet engine runs the names it has, so
    /// they are no gap; names it lacks are counted in the scriptlets status line. nil when there are none, or it is off.
    public func scriptletText(scriptletsOn: Bool, locale: Locale = .current) -> String? {
        guard scriptletsOn, skips.scriptlets > 0 else { return nil }
        let lines = Self.countText(skips.scriptlets, "scriptlet line", "scriptlet lines", locale: locale)
        return "\(lines): Paddle's scriptlet engine runs the names it has, so they aren't a gap. "
            + "Names it lacks are counted in the scriptlets status line."
    }

    static func countText(_ n: Int, _ singular: String, _ plural: String, locale: Locale) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? singular : plural)"
    }

    /// A readable reason from a WebKit compile error's `NSHelpAnchor` text ("Rule list compilation failed:
    /// Invalid or unsupported regular expression."), or `fallback` when there is none.
    public static func compileFailureReason(helpAnchor: String?, fallback: String) -> String {
        guard var text = helpAnchor?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return fallback }
        let prefix = "Rule list compilation failed:"
        if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if text.hasSuffix(".") { text.removeLast() }
        switch text {
        case "": return fallback
        // WebKit drops rules it can't use (bad CSS selectors) before this check, so nothing was left.
        case "Empty extension": return "WebKit accepted none of its rules"
        case "Failed to parse the JSON String": return "converted rules are not valid JSON"
        default: return text.prefix(1).lowercased() + text.dropFirst()
        }
    }
}
