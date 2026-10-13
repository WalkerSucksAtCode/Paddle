import Foundation

/// Version comparison in the two stores' formats. Each compares part by part, a missing part counting as 0, and each
/// returns nil for a string outside its format, so a caller refuses an update rather than guessing an order.
public enum ExtensionVersion {
    /// Chrome versions: 1 to 4 dot-separated non-negative integers. `1.10` is above `1.9`; `1.0` equals `1`.
    public static func compareChrome(_ a: String, _ b: String) -> ComparisonResult? {
        guard let left = chromeParts(a), let right = chromeParts(b) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Firefox (toolkit) versions: dot-separated parts, each a number optionally followed by lowercase letters and a
    /// number (`1.2.3b4`, `2.0a1`). The number after the letters may be left out and counts as 0, so `1.0a` is `1.0a0`.
    /// A part without letters is a release and sorts above one with letters, so `2.0a1` is below `2.0`. The letters rank
    /// `pre`, `a`, `b`, `rc`, then any other letters alphabetically. The number after the letters compares as a number,
    /// so `3.0b2` is below `3.0b10`.
    public static func compareToolkit(_ a: String, _ b: String) -> ComparisonResult? {
        guard let left = toolkitParts(a), let right = toolkitParts(b) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : ToolkitPart(number: 0, suffix: nil)
            let y = index < right.count ? right[index] : ToolkitPart(number: 0, suffix: nil)
            if x < y { return .orderedAscending }
            if y < x { return .orderedDescending }
        }
        return .orderedSame
    }

    /// One part of a toolkit version: its number, then the letters and number after it when there are any.
    private struct ToolkitPart {
        let number: Int
        let suffix: (letters: String, number: Int)?

        static func < (lhs: ToolkitPart, rhs: ToolkitPart) -> Bool {
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            switch (lhs.suffix, rhs.suffix) {
            case (nil, _): return false
            case (_?, nil): return true
            case let (left?, right?):
                if left.letters != right.letters { return letterOrder(left.letters, right.letters) }
                return left.number < right.number
            }
        }
    }

    /// `pre` < `a` < `b` < `rc`, then any other letters alphabetically.
    private static func letterOrder(_ x: String, _ y: String) -> Bool {
        let known = ["pre", "a", "b", "rc"]
        let i = known.firstIndex(of: x) ?? known.count
        let j = known.firstIndex(of: y) ?? known.count
        return i == j ? x < y : i < j
    }

    /// The numbers of a Chrome version: 1 to 4 parts.
    private static func chromeParts(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let value = number(piece) else { return nil }
            parts.append(value)
        }
        return parts
    }

    /// The parts of a toolkit version, or nil when any part is not a number, optionally followed by letters and an
    /// optional number.
    private static func toolkitParts(_ version: String) -> [ToolkitPart]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        var parts: [ToolkitPart] = []
        for piece in pieces {
            let digits = piece.prefix { $0.isASCII && $0.isNumber }
            guard let value = number(digits) else { return nil }
            let rest = piece.dropFirst(digits.count)
            if rest.isEmpty {
                parts.append(ToolkitPart(number: value, suffix: nil))
                continue
            }
            let letters = rest.prefix { $0.isASCII && $0.isLowercase }
            let tail = rest.dropFirst(letters.count)
            guard !letters.isEmpty, let suffix = tail.isEmpty ? 0 : number(tail) else { return nil }
            parts.append(ToolkitPart(number: value, suffix: (String(letters), suffix)))
        }
        return parts
    }

    /// The value of a run of ASCII digits; nil for anything else, an empty run, or a value too large for `Int`.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
