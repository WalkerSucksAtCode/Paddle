import Foundation

/// Translates an Adblock Plus regex rule (`/banner\d+\.js/`) into WebKit url-filters.
/// WebKit's url-filter is a restricted regex: literal ASCII, `.`, character classes, groups and `* + ?`,
/// with `^` and `$` only at the ends. Rewrites only exact equivalents; never widens or narrows a match:
/// - `\d` `\D` `\w` `\W` become character classes; other escapes of punctuation become the literal character.
/// - Inside a class, a `-` next to `\d` or `\w` (or first or last) is a literal hyphen, as JavaScript reads it.
/// - `{n}`, `{n,m}` and `{n,}` are written out (`a{2,3}` → `aaa?`), at most `maxRepetitions` copies per atom.
/// - `(a|b)` becomes one url-filter per alternative, at most `maxAlternatives` per rule.
/// - Lazy quantifiers become greedy ones (whether a URL matches does not depend on laziness).
/// Refused: lookarounds, `\b`, backreferences, `\s`, control and Unicode escapes, non-ASCII text, anchors anywhere
/// but the ends, a repeated alternation that is not a set of single characters, and any url-filter longer than
/// `maxFilterLength` (long patterns make WebKit's compile slow).
public enum RegexTranslator {
    public static let maxRepetitions = 32
    public static let maxAlternatives = 32
    public static let maxFilterLength = 200

    public enum Refusal: Error, Equatable, Sendable {
        case lookaround
        case wordBoundary
        case backreference
        case unsupportedEscape(Character)
        case nonASCII
        case misplacedAnchor
        case tooManyRepetitions
        case tooManyAlternatives
        case tooLong
        case repeatedAlternation
        case matchesEverything
        case malformed
    }

    /// The url-filters that together match exactly what `source` (the text between the slashes) matches.
    public static func translate(_ source: String) -> Result<[String], Refusal> {
        do {
            guard source.allSatisfy(\.isASCII) else { throw Refusal.nonASCII }
            var parser = Parser(chars: Array(source))
            let sequence = try parser.parseAlternatives()
            guard parser.index == parser.chars.count else { throw Refusal.malformed }
            var seen: Set<String> = []
            var filters: [String] = []
            for variant in try expand(sequence) {
                let filter = try finish(variant)
                if seen.insert(filter).inserted { filters.append(filter) }
            }
            return .success(filters)
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.malformed)
        }
    }

    // MARK: - Syntax tree

    /// One atom of the pattern with its quantifier.
    struct Term {
        var atom: Atom
        var min = 1
        var max: Int? = 1  // nil: unbounded
    }

    enum Atom {
        /// One character's worth of url-filter: `a`, `\.`, `.`, `[0-9]`.
        case single(String)
        /// A group of alternatives, each a sequence of terms.
        case group([[Term]])
        case start
        case end
    }

    // Anchors stay markers until the variants are complete, so their position can be checked in the final string.
    static let startMarker: Character = "\u{1}"
    static let endMarker: Character = "\u{2}"

    struct Parser {
        let chars: [Character]
        var index = 0

        var atEnd: Bool { index >= chars.count }
        func peek(_ offset: Int = 0) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }

        /// `a|b|c` up to the end or a closing parenthesis.
        mutating func parseAlternatives() throws -> [[Term]] {
            var alternatives: [[Term]] = [try parseSequence()]
            while peek() == "|" {
                index += 1
                alternatives.append(try parseSequence())
            }
            return alternatives
        }

        mutating func parseSequence() throws -> [Term] {
            var terms: [Term] = []
            while let ch = peek(), ch != "|", ch != ")" {
                var term = Term(atom: try parseAtom())
                try parseQuantifier(into: &term)
                terms.append(term)
            }
            return terms
        }

        mutating func parseAtom() throws -> Atom {
            let ch = chars[index]
            index += 1
            switch ch {
            case "^": return .start
            case "$": return .end
            case ".": return .single(".")
            case "[": return .single(try parseClass())
            case "(":
                if peek() == "?" {
                    guard peek(1) == ":" else { throw Refusal.lookaround }  // (?= (?! (?<= (?<! and named groups
                    index += 2
                }
                let alternatives = try parseAlternatives()
                guard peek() == ")" else { throw Refusal.malformed }
                index += 1
                return .group(alternatives)
            case "\\":
                switch try parseEscape(inClass: false) {
                case .character(let ch): return .single(RegexTranslator.literal(ch))
                case .set(let set, let negated): return .single("[" + (negated ? "^" : "") + set + "]")
                }
            case "*", "+", "?", "{", ")": throw Refusal.malformed
            default: return .single(RegexTranslator.literal(ch))
            }
        }

        /// The escape after a backslash: one literal character, or a set (`\d` → `0-9`) as a class body.
        enum Escape {
            case character(Character)
            case set(String, negated: Bool)
        }

        mutating func parseEscape(inClass: Bool) throws -> Escape {
            guard let ch = peek() else { throw Refusal.malformed }
            index += 1
            switch ch {
            case "d": return .set("0-9", negated: false)
            case "w": return .set("A-Za-z0-9_", negated: false)
            case "D", "W":
                guard !inClass else { throw Refusal.unsupportedEscape(ch) }  // a negated set inside a set
                return .set(ch == "D" ? "0-9" : "A-Za-z0-9_", negated: true)
            case "b", "B": throw inClass ? Refusal.unsupportedEscape(ch) : Refusal.wordBoundary
            case "1"..."9": throw Refusal.backreference
            case "k": throw Refusal.backreference
            default:
                guard !ch.isLetter, !ch.isNumber else { throw Refusal.unsupportedEscape(ch) }  // \s \n \t \x \u \c \0
                return .character(ch)
            }
        }

        /// One member of a class as written: a character (plain or escaped), a set, or an unescaped `-`.
        enum ClassItem {
            case character(Character)
            case set(String)
            case hyphen
        }

        /// `[...]` with the opening bracket consumed, rewritten with plain escapes. A `-` between two characters is
        /// a range, refused when it runs high to low (JavaScript refuses it too); a `-` next to a set, or first or
        /// last, is a literal hyphen (JavaScript's Annex B reading of `[a-\d]`).
        mutating func parseClass() throws -> String {
            var body = ""
            if peek() == "^" { body = "^"; index += 1 }
            if peek() == "]" { throw Refusal.malformed }  // `[]` and `[^]` mean other things in JavaScript
            var items: [ClassItem] = []
            var closed = false
            while let ch = peek() {
                index += 1
                if ch == "]" { closed = true; break }
                switch ch {
                case "\\":
                    switch try parseEscape(inClass: true) {
                    case .character(let literal): items.append(.character(literal))
                    case .set(let set, _): items.append(.set(set))
                    }
                case "-": items.append(.hyphen)
                default: items.append(.character(ch))
                }
            }
            guard closed else { throw Refusal.malformed }

            func text(_ item: ClassItem) -> String {
                switch item {
                case .character(let ch): RegexTranslator.classLiteral(ch)
                case .set(let set): set
                case .hyphen: "\\-"
                }
            }
            func character(_ item: ClassItem) -> Character? {
                switch item {
                case .character(let ch): ch
                case .hyphen: "-"
                case .set: nil
                }
            }
            var i = 0
            while i < items.count {
                guard i + 2 < items.count, case .hyphen = items[i + 1] else {
                    body += text(items[i])
                    i += 1
                    continue
                }
                if let low = character(items[i]), let high = character(items[i + 2]) {
                    guard let a = low.asciiValue, let b = high.asciiValue, a <= b else { throw Refusal.malformed }
                    body += RegexTranslator.classLiteral(low) + "-" + RegexTranslator.classLiteral(high)
                } else {
                    body += text(items[i]) + "\\-" + text(items[i + 2])
                }
                i += 3
            }
            return "[" + body + "]"
        }

        mutating func parseQuantifier(into term: inout Term) throws {
            guard let ch = peek() else { return }
            switch ch {
            case "*": term.min = 0; term.max = nil; index += 1
            case "+": term.min = 1; term.max = nil; index += 1
            case "?": term.min = 0; term.max = 1; index += 1
            case "{":
                guard let (min, max) = parseBraces() else { throw Refusal.malformed }
                term.min = min
                term.max = max
            default: return
            }
            if case .start = term.atom { throw Refusal.misplacedAnchor }
            if case .end = term.atom { throw Refusal.misplacedAnchor }
            if peek() == "?" { index += 1 }  // lazy: same matches
            if let next = peek(), "*+?{".contains(next) { throw Refusal.malformed }
        }

        /// `{n}`, `{n,}` or `{n,m}`; nil (and nothing consumed) for anything else.
        mutating func parseBraces() -> (Int, Int?)? {
            guard let close = chars[index...].firstIndex(of: "}") else { return nil }
            let inner = String(chars[(index + 1)..<close])
            let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let min = Int(parts[0]), parts[0].allSatisfy(\.isNumber) else { return nil }
            var max: Int? = min
            if parts.count == 2 {
                if parts[1].isEmpty {
                    max = nil
                } else {
                    guard parts[1].allSatisfy(\.isNumber), let m = Int(parts[1]), m >= min else { return nil }
                    max = m
                }
            }
            index = close + 1
            return (min, max)
        }
    }

    static func literal(_ ch: Character) -> String {
        ".?+*()[]{}\\$^|".contains(ch) ? "\\" + String(ch) : String(ch)
    }

    static func classLiteral(_ ch: Character) -> String {
        "]\\-^[".contains(ch) ? "\\" + String(ch) : String(ch)
    }

    // MARK: - Expansion

    /// Every alternation-free string `sequence` stands for, at most `maxAlternatives`.
    static func expand(_ alternatives: [[Term]]) throws -> [String] {
        var out: [String] = []
        for sequence in alternatives {
            out += try expand(sequence)
            if out.count > maxAlternatives { throw Refusal.tooManyAlternatives }
        }
        return out
    }

    static func expand(_ sequence: [Term]) throws -> [String] {
        var variants = [""]
        for term in sequence {
            let pieces = try expand(term)
            variants = variants.flatMap { prefix in pieces.map { prefix + $0 } }
            if variants.count > maxAlternatives { throw Refusal.tooManyAlternatives }
            if variants.contains(where: { $0.count > maxFilterLength }) { throw Refusal.tooLong }
        }
        return variants
    }

    /// The strings one term stands for.
    static func expand(_ term: Term) throws -> [String] {
        let options: [String]
        switch term.atom {
        case .start: return [String(startMarker)]
        case .end: return [String(endMarker)]
        case .single(let text): options = [text]
        case .group(let alternatives):
            let inner = try expand(alternatives)
            if inner == [""] { return [""] }
            if inner.count > 1, term.max != 1, let set = characterSet(inner) {
                options = [set]  // (a|b|c)+ → [abc]+
            } else if inner.count > 1, term.max == nil {
                throw Refusal.repeatedAlternation
            } else {
                options = inner
            }
        }

        if term.min > maxRepetitions || (term.max ?? 0) > maxRepetitions { throw Refusal.tooManyRepetitions }
        if options.contains(where: { $0.contains(startMarker) || $0.contains(endMarker) }), term.min != 1 || term.max != 1 {
            throw Refusal.misplacedAnchor
        }

        // A single option can use WebKit's own quantifiers; written out, the optional copies come last.
        if options.count == 1 {
            let atom = options[0]
            let quantified = atom.count == 1 || isAtomic(atom) ? atom : "(" + atom + ")"
            switch (term.min, term.max) {
            case (1, 1): return [atom]
            case (0, nil): return [quantified + "*"]
            case (let min, nil): return [String(repeating: atom, count: min - 1) + quantified + "+"]
            case (let min, let max?):
                return [String(repeating: atom, count: min) + String(repeating: quantified + "?", count: max - min)]
            }
        }

        // Several options (a group of alternatives) with a bounded count: every combination.
        guard let max = term.max else { throw Refusal.repeatedAlternation }
        var results: [String] = []
        for count in term.min...max {
            var combos = [""]
            for _ in 0..<count {
                combos = combos.flatMap { prefix in options.map { prefix + $0 } }
                if combos.count > maxAlternatives { throw Refusal.tooManyAlternatives }
            }
            results += combos
            if results.count > maxAlternatives { throw Refusal.tooManyAlternatives }
        }
        return results
    }

    /// True for `.`, an escaped character or a single class: text a quantifier applies to whole.
    static func isAtomic(_ text: String) -> Bool {
        if text.count == 2, text.hasPrefix("\\") { return true }
        guard text.hasPrefix("["), text.hasSuffix("]") else { return false }
        // One class only: no unescaped `]` before the last character.
        var escaped = false
        for ch in text.dropFirst().dropLast() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "]" { return false }
        }
        return true
    }

    /// `[abc]` when every alternative is one plain character (`a`, `\.`); nil otherwise.
    static func characterSet(_ alternatives: [String]) -> String? {
        var body = ""
        for alternative in alternatives {
            if alternative.count == 1, let ch = alternative.first, ch != startMarker, ch != endMarker, ch != "." {
                body += classLiteral(ch)
            } else if alternative.count == 2, alternative.hasPrefix("\\"), let ch = alternative.last {
                body += classLiteral(ch)
            } else {
                return nil
            }
        }
        return "[" + body + "]"
    }

    /// A finished variant: anchors only at the ends, not empty, not over the length cap.
    static func finish(_ variant: String) throws -> String {
        var text = variant
        var prefix = ""
        var suffix = ""
        if text.first == startMarker { text.removeFirst(); prefix = "^" }
        if text.last == endMarker { text.removeLast(); suffix = "$" }
        guard !text.contains(startMarker), !text.contains(endMarker) else { throw Refusal.misplacedAnchor }
        guard !text.isEmpty else { throw Refusal.matchesEverything }
        let filter = prefix + text + suffix
        guard filter.count <= maxFilterLength else { throw Refusal.tooLong }
        return filter
    }
}
