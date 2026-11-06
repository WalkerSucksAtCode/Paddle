import Foundation
import JavaScriptCore

/// Rewrites a classic script so every character is Latin-1, by writing the others as `\uXXXX` escapes. WebKit keeps
/// a script's source as 8-bit text only when every character fits in a byte; one character outside Latin-1 makes the
/// whole source 16-bit. Extension content scripts are sent to every WebContent process (measured: 15-31 MB per
/// process, most of it Return YouTube Dislike's 4.3 MB script with 1,097 such characters), so this halves them.
///
/// A small tokenizer finds where each character sits: strings, comments, untagged templates and identifiers take the
/// escape and mean the same; a character escaped after a backslash (`"\é"`) loses the backslash. The file is left
/// alone when the rewrite could change it: a character in a tagged template (the tag can read the raw text) or in a
/// regular expression (`.source` reads the pattern's text), any Unicode line or space separator (in a comment an escaped U+2028 would stop ending the line), or an
/// identifier character outside the Basic Multilingual Plane (no surrogate escape there). The result must also pass
/// JavaScriptCore's syntax check.
public enum ScriptLatin1 {
    public enum Outcome: Equatable {
        /// Already Latin-1, or not worth touching.
        case unchanged
        case rewritten(String)
        /// Left as it is; the reason is for the log.
        case skipped(String)
    }

    public static func rewrite(_ source: String) -> Outcome {
        var scalars = Array(source.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        guard scalars.contains(where: { $0.value > 0xFF }) else { return .unchanged }
        if let separator = scalars.first(where: { separators.contains($0.value) }) {
            return .skipped("has U+\(String(separator.value, radix: 16, uppercase: true))")
        }
        var tokenizer = Tokenizer(scalars)
        let output: String
        do { output = try tokenizer.run() } catch { return .skipped(error.reason) }
        guard parses(output) else { return .skipped("rewrite did not parse") }
        return .rewritten(output)
    }

    /// Unicode line terminators and the space separators beyond Latin-1 (and U+FEFF), which mean something outside strings.
    static let separators: Set<UInt32> = Set([0x2028, 0x2029, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF]).union(0x2000...0x200A)

    /// JavaScriptCore's syntax check of `source` as a classic script.
    static func parses(_ source: String) -> Bool {
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context, script, nil, 1, nil)
    }

    struct Skip: Error {
        let reason: String
    }

    private struct Tokenizer {
        let input: [Unicode.Scalar]
        var at = 0
        var out = String.UnicodeScalarView()
        /// Whether the last token ends an expression: then `/` divides and a template is tagged.
        var afterExpression = false
        /// Open `${` substitutions: the depth of `{` opened inside each, and whether its template is tagged.
        var substitutions: [(depth: Int, tagged: Bool)] = []

        init(_ input: [Unicode.Scalar]) {
            self.input = input
            out.reserveCapacity(input.count + input.count / 16)
        }

        /// Words after which an expression starts, so `/` begins a regular expression and a template is untagged.
        static let operatorWords: Set<String> = [
            "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
            "yield", "await",
        ]

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            at + offset < input.count ? input[at + offset] : nil
        }

        mutating func emit(_ scalar: Unicode.Scalar) {
            if scalar.value <= 0xFF {
                out.append(scalar)
                return
            }
            // Single-scalar appends: `append(contentsOf:)` on a scalar view is O(current length) per call, which
            // made escape-dense scripts quadratic (measured: 320k escapes ≈ 11.75 s; this form is linear).
            for unit in String(scalar).utf16 {
                out.append("\\")
                out.append("u")
                let hex = String(unit, radix: 16)
                for _ in 0..<(4 - hex.count) { out.append("0") }
                for digit in hex.unicodeScalars { out.append(digit) }
            }
        }

        mutating func run() throws -> String {
            while let c = peek() {
                switch c {
                case " ", "\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{A0}":
                    out.append(c)
                    at += 1
                case "/" where peek(1) == "/":
                    while let d = peek(), d != "\n", d != "\r" { emit(d); at += 1 }
                case "/" where peek(1) == "*":
                    out.append(contentsOf: "/*".unicodeScalars)
                    at += 2
                    while let d = peek(), !(d == "*" && peek(1) == "/") { emit(d); at += 1 }
                    if peek() != nil { out.append(contentsOf: "*/".unicodeScalars); at += 2 }
                case "'", "\"":
                    try quoted(until: c)
                    afterExpression = true
                case "`":
                    try template(tagged: afterExpression)
                case "/" where !afterExpression:
                    try regularExpression()
                    afterExpression = true
                case "{":
                    if !substitutions.isEmpty { substitutions[substitutions.count - 1].depth += 1 }
                    out.append(c)
                    at += 1
                    afterExpression = false
                case "}":
                    at += 1
                    if let open = substitutions.last, open.depth == 0 {
                        substitutions.removeLast()
                        out.append(c)
                        try templateBody(tagged: open.tagged)
                    } else {
                        if !substitutions.isEmpty { substitutions[substitutions.count - 1].depth -= 1 }
                        out.append(c)
                        afterExpression = true
                    }
                case ")", "]":
                    out.append(c)
                    at += 1
                    afterExpression = true
                default:
                    if Self.isWordScalar(c) {
                        try word()
                    } else {
                        emit(c)
                        at += 1
                        afterExpression = false
                    }
                }
            }
            return String(out)
        }

        static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
            c.value > 0x7F || c == "$" || c == "_" || c == "\\"
                || ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
        }

        /// An identifier, keyword or number. A BMP character takes `\uXXXX`, which identifiers accept.
        mutating func word() throws {
            var text = ""
            while let c = peek(), Self.isWordScalar(c) {
                if c == "\\" {
                    // An existing `\uXXXX` or `\u{...}` escape, kept as written.
                    out.append(c)
                    text.unicodeScalars.append(c)
                    at += 1
                    continue
                }
                if c.value > 0xFFFF { throw Skip(reason: "identifier outside the BMP") }
                emit(c)
                text.unicodeScalars.append(c)
                at += 1
            }
            afterExpression = !Self.operatorWords.contains(text)
        }

        mutating func quoted(until quote: Unicode.Scalar) throws {
            out.append(quote)
            at += 1
            while let c = peek() {
                at += 1
                if c == quote { out.append(c); return }
                if c == "\\" {
                    guard let next = peek() else { out.append(c); return }
                    at += 1
                    // `\é` means é: the escape replaces both.
                    if next.value > 0xFF { emit(next) } else { out.append(c); out.append(next) }
                    continue
                }
                emit(c)
            }
        }

        mutating func template(tagged: Bool) throws {
            out.append("`")
            at += 1
            try templateBody(tagged: tagged)
        }

        /// Template text up to its closing backtick or a `${`, which hands back to `run`.
        mutating func templateBody(tagged: Bool) throws {
            while let c = peek() {
                at += 1
                switch c {
                case "`":
                    out.append(c)
                    afterExpression = true
                    return
                case "\\":
                    guard let next = peek() else { out.append(c); return }
                    at += 1
                    if next.value > 0xFF {
                        if tagged { throw Skip(reason: "character in a tagged template") }
                        emit(next)
                    } else {
                        out.append(c)
                        out.append(next)
                    }
                case "$" where peek() == "{":
                    out.append(contentsOf: "${".unicodeScalars)
                    at += 1
                    substitutions.append((0, tagged))
                    afterExpression = false
                    return
                default:
                    if c.value > 0xFF, tagged { throw Skip(reason: "character in a tagged template") }
                    emit(c)
                }
            }
        }

        mutating func regularExpression() throws {
            out.append("/")
            at += 1
            var inClass = false
            while let c = peek() {
                at += 1
                // `.source` and `toString()` read a pattern's text, so an escape there would change what they return.
                if c.value > 0xFF { throw Skip(reason: "character in a regular expression") }
                if c == "\\" {
                    guard let next = peek() else { out.append(c); return }
                    at += 1
                    if next.value > 0xFF { throw Skip(reason: "character in a regular expression") }
                    out.append(c)
                    out.append(next)
                    continue
                }
                if c == "\n" || c == "\r" { out.append(c); return }
                if c == "[" { inClass = true } else if c == "]" { inClass = false } else if c == "/", !inClass {
                    out.append(c)
                    while let f = peek(), ("a"..."z").contains(f) { out.append(f); at += 1 }
                    return
                }
                emit(c)
            }
        }
    }
}

private extension Error {
    var reason: String { (self as? ScriptLatin1.Skip)?.reason ?? "\(self)" }
}
