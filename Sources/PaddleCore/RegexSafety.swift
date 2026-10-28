import Foundation
import Synchronization

/// Limits on the patterns `@include`, `@exclude` and `@match` turn into (`UserScript`). A pattern that
/// `refusalReason` refuses never matches, and no URL longer than `maxURLLength` is matched. The page's copy of each
/// pattern (`UserScript.wrappedSource`) gets the same limits.
public enum RegexSafety {
    public static let maxPatternLength = 200
    public static let maxURLLength = 2048

    private struct Compiled {
        let regex: NSRegularExpression?
    }

    /// Compiled patterns by source, so each pattern compiles once. Scripts are few; the cache empties itself past 512.
    private static let cache = Mutex<[String: Compiled]>([:])

    /// Why `pattern` must not run, or nil when it may. Refused: nested repeats (`(a+)+`), a repeated group whose
    /// alternatives can start with the same character (or with a class, or be empty), backreferences, lookarounds,
    /// group syntax other than `(...)`, `(?:...)` and `(?<name>...)`, unbalanced parentheses, and patterns over
    /// `maxPatternLength` characters.
    public static func refusalReason(_ pattern: String) -> String? {
        guard pattern.count <= maxPatternLength else { return "longer than \(maxPatternLength) characters" }
        let chars = Array(pattern)
        var groups = [Group(start: 0)]
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count else { return "ends in a backslash" }
                let next = chars[i + 1]
                if ("1"..."9").contains(next) || next == "k" { return "backreference" }
                i += 2
                continue
            }
            if c == "[" {
                guard let end = classEnd(chars, from: i) else { return "unterminated character class" }
                i = end + 1
                continue
            }
            if c == "(" {
                var start = i + 1
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    guard i + 2 < chars.count else { return "unsupported group syntax" }
                    switch chars[i + 2] {
                    case ":":
                        start = i + 3
                    case "=", "!":
                        return "lookaround"
                    case "<":
                        guard i + 3 < chars.count else { return "unsupported group syntax" }
                        if chars[i + 3] == "=" || chars[i + 3] == "!" { return "lookbehind" }
                        guard let close = chars[(i + 3)...].firstIndex(of: ">") else { return "unsupported group syntax" }
                        start = close + 1
                    default:
                        return "unsupported group syntax"
                    }
                }
                groups.append(Group(start: start))
                i = start
                continue
            }
            if c == ")" {
                guard groups.count > 1 else { return "unbalanced parentheses" }
                let group = groups.removeLast()
                let repeats = quantifier(chars, at: i + 1)
                let unbounded = repeats == "*" || repeats == "+" || repeats == "{"
                if unbounded, group.hasQuantifier { return "nested repeats" }
                if unbounded, group.hasAlternation, group.alternativesOverlap(chars, end: i) {
                    return "repeated alternatives that can match the same text"
                }
                if group.hasQuantifier || repeats != nil { groups[groups.count - 1].hasQuantifier = true }
                i += 1
                continue
            }
            if c == "|" {
                groups[groups.count - 1].separators.append(i)
                groups[groups.count - 1].starts.append(i + 1)
            } else if quantifier(chars, at: i) != nil {
                groups[groups.count - 1].hasQuantifier = true
            }
            i += 1
        }
        return groups.count == 1 ? nil : "unbalanced parentheses"
    }

    /// Whether `pattern` may run: not refused, and a valid expression.
    public static func isUsable(_ pattern: String) -> Bool {
        compiled(pattern) != nil
    }

    /// The compiled pattern, or nil when it is refused or invalid. Each pattern is compiled once.
    public static func compiled(_ pattern: String) -> NSRegularExpression? {
        if let known = cache.withLock({ $0[pattern] }) { return known.regex }
        let regex: NSRegularExpression? = refusalReason(pattern) == nil ? (try? NSRegularExpression(pattern: pattern)) : nil
        cache.withLock { entries in
            if entries.count >= 512 { entries.removeAll() }
            entries[pattern] = Compiled(regex: regex)
        }
        return regex
    }

    /// Whether `url` matches `pattern`. A refused pattern, or a URL over `maxURLLength` UTF-16 units, never matches.
    public static func matches(_ pattern: String, url: String) -> Bool {
        let length = url.utf16.count
        guard length <= maxURLLength, let regex = compiled(pattern) else { return false }
        return regex.firstMatch(in: url, range: NSRange(location: 0, length: length)) != nil
    }

    /// The quantifier at `index`: `*`, `+`, `?`, or a `{` before a count. Nil for anything else.
    private static func quantifier(_ chars: [Character], at index: Int) -> Character? {
        guard index < chars.count else { return nil }
        switch chars[index] {
        case "*", "+", "?":
            return chars[index]
        case "{":
            guard index + 1 < chars.count, chars[index + 1].isASCII, chars[index + 1].isNumber else { return nil }
            return "{"
        default:
            return nil
        }
    }

    /// The index of the `]` closing the class that opens at `start`, or nil when it never closes.
    private static func classEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start + 1
        if j < chars.count, chars[j] == "^" { j += 1 }
        if j < chars.count, chars[j] == "]" { j += 1 }
        while j < chars.count {
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "]" { return j }
            j += 1
        }
        return nil
    }

    /// One open parenthesis: where each alternative starts, where the `|` separators are, and whether anything inside
    /// (at any depth) is repeated.
    private struct Group {
        var starts: [Int]
        var separators: [Int] = []
        var hasQuantifier = false

        init(start: Int) {
            starts = [start]
        }

        var hasAlternation: Bool { !separators.isEmpty }

        /// Whether two alternatives can match the same text, judged by their first characters. A literal first character
        /// only overlaps itself; a class, `.`, a group, an escape such as `\d`, or an empty alternative may overlap anything.
        func alternativesOverlap(_ chars: [Character], end: Int) -> Bool {
            var firsts: [Character?] = []
            for (k, start) in starts.enumerated() {
                let stop = k < separators.count ? separators[k] : end
                guard start < stop else { return true }
                let first = chars[start]
                if first == "\\" {
                    let escaped: Character = start + 1 < stop ? chars[start + 1] : "\\"
                    firsts.append(escaped.isLetter || escaped.isNumber ? nil : escaped)
                } else if ".[(^$*+?{".contains(first) {
                    firsts.append(nil)
                } else {
                    firsts.append(first)
                }
            }
            for a in firsts.indices {
                for b in firsts.indices where b > a {
                    guard let x = firsts[a], let y = firsts[b] else { return true }
                    if x == y { return true }
                }
            }
            return false
        }
    }
}
