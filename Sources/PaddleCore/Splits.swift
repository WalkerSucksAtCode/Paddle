import Foundation

/// Two tabs shown side by side: the session form of split view before multi view (`PaneLayout`), still read from older
/// files and turned into a layout (`PaneLayout(split:)`). Tabs are named by their session id (`TabRecord.id`).
public struct SplitRecord: Codable, Sendable, Equatable {
    /// The range a divider can take: the left side's share of the width.
    public static let ratioRange: ClosedRange<Double> = 0.25...0.75

    public var left: String
    public var right: String
    /// The left side's share of the width, within `ratioRange`.
    public var ratio: Double

    public init(left: String, right: String, ratio: Double = 0.5) {
        self.left = left
        self.right = right
        self.ratio = Self.clamped(ratio)
    }

    /// `ratio` limited to `ratioRange`; 0.5 for a value that isn't a number.
    public static func clamped(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound) : 0.5
    }

    private enum CodingKeys: String, CodingKey { case left, right, ratio }

    /// Lenient: a missing or odd ratio is 0.5, and an out-of-range one is clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(String.self, forKey: .left)
        right = try c.decode(String.self, forKey: .right)
        ratio = Self.clamped((try? c.decodeIfPresent(Double.self, forKey: .ratio)) ?? 0.5)
    }
}

/// What the split rules need to know about one tab.
public struct SplitTab: Equatable, Sendable {
    public var id: String
    public var groupID: String?
    public var isPinned: Bool

    public init(id: String, groupID: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.groupID = groupID
        self.isPinned = isPinned
    }
}

/// Multi view rules on the strip's order. A layout's tabs sit next to each other in the strip (in any order), none
/// pinned, all in one group (or none). A tab that breaks that leaves its layout, and a layout left with fewer than two
/// tabs ends.
public enum MultiViewRules {
    /// `layouts` without what can't hold. In each layout, tabs that are missing, pinned or already in an earlier
    /// layout are taken out; of the rest, the tabs of the first one's group (in strip order) stay, and of those the
    /// longest run of strip neighbours (the first on a tie). Order of layouts is kept.
    public static func normalized(layouts: [PaneLayout], tabs: [SplitTab]) -> [PaneLayout] {
        let index = Dictionary(tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var result: [PaneLayout] = []
        for layout in layouts {
            var candidates = layout.tabs.filter { id in
                guard let i = index[id] else { return false }
                return !tabs[i].isPinned && !used.contains(id)
            }
            candidates.sort { index[$0]! < index[$1]! }
            if let first = candidates.first {
                let group = tabs[index[first]!].groupID
                candidates = candidates.filter { tabs[index[$0]!].groupID == group }
            }
            // Runs of strip neighbours.
            var runs: [[String]] = []
            for id in candidates {
                if let last = runs.last?.last, index[id]! == index[last]! + 1 { runs[runs.count - 1].append(id) } else { runs.append([id]) }
            }
            let keep = Set(runs.max { $0.count < $1.count } ?? [])
            var kept: PaneLayout? = layout
            for id in layout.tabs where !keep.contains(id) { kept = kept?.removing(id) }
            guard let kept, kept.count >= 2 else { continue }
            used.formUnion(kept.tabs)
            result.append(kept)
        }
        return result
    }
}
