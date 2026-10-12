import Foundation

/// A JSON value with the distinctions that matter for `config.json`: `true` is not `1`, and objects compare by
/// content. `JSONSerialization` output converts to this (its booleans are `CFBoolean`, its numbers `NSNumber`),
/// and `render` writes it back in the file's own indent.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts `JSONSerialization` output. Anything that isn't JSON (a `Date`, say) becomes `.null`.
    public init(_ any: Any) {
        switch any {
        case let value as JSONValue: self = value
        case is NSNull: self = .null
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init))
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        default: self = .null
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Renders JSON text. Objects and arrays spread over lines indented with `unit` (`""` keeps everything on
    /// one line) and ended with `newline`; `depth` is how many units the value's own line is already indented.
    /// Objects list `order`'s keys first in that order (a key repeated there is written once), then the rest
    /// sorted, so an edited object keeps the layout the user wrote.
    public func render(unit: String = "  ", depth: Int = 0, order: [String] = [], newline: String = "\n") -> String {
        switch self {
        case .null: return "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        case .string(let string): return JSONValue.quote(string)
        case .array(let array):
            guard !array.isEmpty else { return "[]" }
            let items = array.map { $0.render(unit: unit, depth: depth + 1, newline: newline) }
            return JSONValue.wrap(items, open: "[", close: "]", unit: unit, depth: depth, newline: newline)
        case .object(let object):
            guard !object.isEmpty else { return "{}" }
            var seen: Set<String> = []
            let ordered = order.filter { object[$0] != nil && seen.insert($0).inserted }
            let keys = ordered + object.keys.filter { !seen.contains($0) }.sorted()
            let items = keys.map { JSONValue.quote($0) + ": " + object[$0]!.render(unit: unit, depth: depth + 1, newline: newline) }
            return JSONValue.wrap(items, open: "{", close: "}", unit: unit, depth: depth, newline: newline)
        }
    }

    private static func wrap(_ items: [String], open: String, close: String, unit: String, depth: Int, newline: String) -> String {
        if unit.isEmpty { return open + items.joined(separator: ", ") + close }
        let inner = String(repeating: unit, count: depth + 1)
        let outer = String(repeating: unit, count: depth)
        return open + newline + items.map { inner + $0 }.joined(separator: "," + newline) + newline + outer + close
    }

    /// JSON string literal. Slashes and non-ASCII stay as written, like `PaddleConfig.encoded()`.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case ..<" ": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Where each top-level member of a JSON object sits in the file, so one member can be replaced, removed or
/// appended while every other byte stays as the user wrote it: their indent, key order, spacing and any keys
/// Paddle doesn't know. Meaning comes from `JSONSerialization`, which must accept the file before this scans it;
/// the scanner only finds the brackets. An empty (or whitespace-only) file counts as `{}`.
public struct JSONSpans: Sendable {
    public struct Member: Sendable, Equatable {
        public var key: String
        /// The quoted key.
        public var keyRange: Range<Int>
        public var valueRange: Range<Int>
        /// Key through value; the separating comma and surrounding whitespace are not included.
        public var memberRange: Range<Int>
    }

    public enum ScanError: Error, Equatable, Sendable {
        /// `JSONSerialization` rejected the file; the text is `PaddleConfig.describe`-style, with line and column
        /// when Foundation reports them.
        case invalidJSON(String)
        /// The file parses but its top level is not an object.
        case notAnObject
        /// A UTF-16 or UTF-32 file: `JSONSerialization` reads it, but the byte edits here need UTF-8.
        case notUTF8
    }

    public let data: Data
    /// In file order, duplicates included; with a duplicate key, the first member is the one `JSONSerialization`
    /// kept, and an edit of that key drops the later copies.
    public let members: [Member]
    /// The whole file as values.
    public let object: [String: JSONValue]
    /// Bytes between the braces (`nil` for an empty file, which has none yet).
    let body: Range<Int>?
    /// One level of indent as the file uses it (`""` when the members share a line).
    let unit: String
    /// `"\r\n"` when the body uses it, else `"\n"`.
    let newline: String
    /// Text between a key and its value, e.g. `": "` or `" : "`.
    let colon: String

    public static func scan(_ data: Data) throws -> JSONSpans {
        let bytes = [UInt8](data)
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let start = bytes.starts(with: bom) ? bom.count : 0
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        // Data(bytes) so every range below indexes from 0, whatever slice the caller handed in.
        let data = Data(bytes)
        if bytes[start...].allSatisfy(whitespace.contains) {
            // Only a BOM survives: the braces `appending` builds replace the whitespace.
            return JSONSpans(data: data.prefix(start), members: [], object: [:], body: nil, unit: "  ", newline: "\n", colon: ": ")
        }
        // A UTF-16/32 BOM, or a NUL among the first bytes of what must start with `{` or whitespace.
        if bytes.prefix(4).contains(0) { throw ScanError.notUTF8 }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ScanError.invalidJSON(PaddleConfig.describe(error))
        }
        guard let dictionary = parsed as? [String: Any] else { throw ScanError.notAnObject }

        var scanner = Scanner(bytes: bytes, index: start)
        let (members, body) = try scanner.object()
        // The indent is what follows the first line break before a member; a file with members but no line
        // break is inline.
        var unit = members.isEmpty ? "  " : ""
        for (index, member) in members.enumerated() {
            let from = index == 0 ? body.lowerBound : members[index - 1].memberRange.upperBound
            let before = bytes[from..<member.keyRange.lowerBound]
            if let newline = before.lastIndex(of: 0x0A) {
                unit = String(decoding: before[(newline + 1)...], as: UTF8.self)
                break
            }
        }
        var colon = ": "
        if let first = members.first {
            colon = String(decoding: bytes[first.keyRange.upperBound..<first.valueRange.lowerBound], as: UTF8.self)
        }
        let crlf = bytes[body].firstIndex(of: 0x0A).map { $0 > body.lowerBound && bytes[$0 - 1] == 0x0D } ?? false
        return JSONSpans(
            data: data, members: members, object: dictionary.mapValues(JSONValue.init), body: body, unit: unit,
            newline: crlf ? "\r\n" : "\n", colon: colon)
    }

    /// The member `JSONSerialization` read for `key`: the first, when the key is repeated.
    public func member(_ key: String) -> Member? { members.first { $0.key == key } }

    /// Keys of the object stored under `key`, in file order, each once; `nil` if the value isn't an object.
    public func nestedKeys(of key: String) -> [String]? {
        let bytes = [UInt8](data)
        guard let member = member(key), bytes[member.valueRange.lowerBound] == UInt8(ascii: "{") else { return nil }
        var scanner = Scanner(bytes: bytes, index: member.valueRange.lowerBound)
        guard let nested = try? scanner.object().members else { return nil }
        var seen: Set<String> = []
        return nested.map(\.key).filter { seen.insert($0).inserted }
    }

    /// Renders `value` as the text for member `key`: nested objects keep the key order the file has for that key.
    public func text(for value: JSONValue, key: String) -> String {
        value.render(unit: unit, depth: 1, order: nestedKeys(of: key) ?? [], newline: newline)
    }

    /// The file with the value of `key` replaced by `text`, and any later copies of the key dropped so the file
    /// holds the key once. The key must exist.
    public func replacing(_ key: String, with text: String) -> Data {
        let spans = removingDuplicates(of: key)
        guard let member = spans.member(key) else { return spans.data }
        return spans.splice(member.valueRange, with: text)
    }

    /// The file without `key` (every copy of it): the comma goes with it, the next member (or the closing brace)
    /// moves up.
    public func removing(_ key: String) -> Data {
        removingMembers(while: { $0.lastIndex { $0.key == key } }).data
    }

    /// All but the first member for `key`.
    private func removingDuplicates(of key: String) -> JSONSpans {
        removingMembers(while: { members in
            let last = members.lastIndex { $0.key == key }
            return last == members.firstIndex { $0.key == key } ? nil : last
        })
    }

    /// Removes one member at a time, rescanning between, so each removal sees the spans it edits.
    private func removingMembers(while next: ([Member]) -> Int?) -> JSONSpans {
        var spans = self
        while let index = next(spans.members), let edited = spans.removingMember(at: index),
            let rescanned = try? JSONSpans.scan(edited) {
            spans = rescanned
        }
        return spans
    }

    private func removingMember(at index: Int) -> Data? {
        guard let body else { return nil }
        let member = members[index]
        if members.count == 1 { return splice(body, with: "") }
        if index + 1 < members.count { return splice(member.memberRange.lowerBound..<members[index + 1].keyRange.lowerBound, with: "") }
        return splice(members[index - 1].memberRange.upperBound..<member.memberRange.upperBound, with: "")
    }

    /// The file with `"key": text` added after the last member, in the file's indent and line ending. Builds
    /// `{ … }` for an empty file.
    public func appending(_ key: String, text: String) -> Data {
        let entry = JSONValue.quote(key) + colon + text
        guard let body else {
            return data + Data(("{\n" + unit + entry + "\n}\n").utf8)
        }
        if let last = members.last {
            let separator = unit.isEmpty ? ", " : "," + newline + unit
            return splice(last.memberRange.upperBound..<last.memberRange.upperBound, with: separator + entry)
        }
        return splice(body, with: newline + unit + entry + newline)
    }

    private func splice(_ range: Range<Int>, with text: String) -> Data {
        var copy = data
        copy.replaceSubrange(range, with: Data(text.utf8))
        return copy
    }

    /// Finds brackets in bytes `JSONSerialization` has already accepted, so it only needs to get strings right.
    private struct Scanner {
        let bytes: [UInt8]
        var index: Int

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        /// At `{`. Returns the members and the range between the braces.
        mutating func object() throws -> (members: [Member], body: Range<Int>) {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw ScanError.notAnObject }
            index += 1
            let bodyStart = index
            var members: [Member] = []
            while true {
                skipWhitespace()
                guard index < bytes.count else { throw ScanError.notAnObject }
                if bytes[index] == UInt8(ascii: "}") {
                    let body = bodyStart..<index
                    index += 1
                    return (members, body)
                }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                let keyStart = index
                try string()
                let keyRange = keyStart..<index
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ScanError.notAnObject }
                index += 1
                skipWhitespace()
                let valueStart = index
                try value()
                let keyText = Data(bytes[keyRange])
                guard let key = (try? JSONSerialization.jsonObject(with: keyText, options: [.fragmentsAllowed])) as? String
                else { throw ScanError.notAnObject }
                members.append(Member(key: key, keyRange: keyRange, valueRange: valueStart..<index, memberRange: keyStart..<index))
            }
        }

        /// At `"`; leaves `index` after the closing quote.
        mutating func string() throws {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ScanError.notAnObject }
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): index += 1; return
                default: index += 1
                }
            }
            throw ScanError.notAnObject
        }

        mutating func value() throws {
            guard index < bytes.count else { throw ScanError.notAnObject }
            switch bytes[index] {
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""): try string(); continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                    default: break
                    }
                    index += 1
                    if depth == 0 { return }
                }
                throw ScanError.notAnObject
            default:
                // A number or literal runs to the next delimiter.
                while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index]) {
                    index += 1
                }
            }
        }
    }
}
