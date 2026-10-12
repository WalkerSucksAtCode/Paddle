import Foundation

/// What one block list turned into: how many WebKit rules, and which lines were left out. Saved next to the
/// compiled list as `compiled-rules/<identifier>.json`, so a list loaded from cache reports the same counts as
/// a fresh compile. `statusLine` is the text the Content Blocking status and the Reload Config alert show.
public struct RuleListSummary: Codable, Sendable, Equatable {
    /// WebKit rules after conversion (cosmetic rules are chunked, so this is not a line count).
    public var ruleCount: Int
    /// Lines the converter could not express (regex rules, scriptlets, unsupported options or selectors).
    public var skipped: Int
    /// `!` comment and `[Adblock …]` header lines.
    public var commentLines: Int
    /// The list hit `FilterListConverter.maxRulesPerList` and lost rules from its end.
    public var truncated: Bool

    public init(ruleCount: Int, skipped: Int, commentLines: Int, truncated: Bool) {
        self.ruleCount = ruleCount
        self.skipped = skipped
        self.commentLines = commentLines
        self.truncated = truncated
    }

    /// The summary of `text` converted into `result`; comment lines are counted from `text`.
    public init(text: String, result: FilterListConverter.Result) {
        self.init(
            ruleCount: result.ruleCount,
            skipped: result.skippedLines,
            commentLines: Self.commentLineCount(text),
            truncated: result.truncated
        )
    }

    /// Lines the converter ignores as comments: the same test it uses (`!` or `[` after trimming spaces).
    public static func commentLineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).count(where: { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("!") || line.hasPrefix("[")
        })
    }

    /// "easylist: 61,234 rules (1,830 lines unsupported; cached)", "user-filters: empty",
    /// "user-filters: 0 rules (4 comment lines; 2 lines unsupported)".
    public func statusLine(name: String, cached: Bool, locale: Locale = .current) -> String {
        func count(_ n: Int, _ singular: String, _ plural: String) -> String {
            "\(n.formatted(.number.locale(locale))) \(n == 1 ? singular : plural)"
        }
        if ruleCount == 0, skipped == 0, commentLines == 0 { return "\(name): empty" }

        var notes: [String] = []
        if truncated { notes.append("truncated") }
        if ruleCount == 0, commentLines > 0 { notes.append(count(commentLines, "comment line", "comment lines")) }
        if skipped > 0 { notes.append(count(skipped, "line unsupported", "lines unsupported")) }
        if cached, ruleCount > 0 { notes.append("cached") }
        let head = "\(name): \(count(ruleCount, "rule", "rules"))"
        return notes.isEmpty ? head : "\(head) (\(notes.joined(separator: "; ")))"
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
