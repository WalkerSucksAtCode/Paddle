import Foundation

/// Two tabs shown side by side. Tabs are named by their session id (`TabRecord.id`).
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

/// Split view rules on the strip's order.
public enum SplitRules {
    /// `splits` without the ones that can't hold: a tab missing, pinned, the left not right before the right, the two
    /// in different groups (or one in a group), or a tab already used by an earlier split. Order is kept.
    public static func normalized(splits: [SplitRecord], tabs: [SplitTab]) -> [SplitRecord] {
        var used = Set<String>()
        var result: [SplitRecord] = []
        for split in splits {
            guard split.left != split.right,
                  let l = tabs.firstIndex(where: { $0.id == split.left }),
                  let r = tabs.firstIndex(where: { $0.id == split.right }),
                  r == l + 1, !tabs[l].isPinned, !tabs[r].isPinned,
                  tabs[l].groupID == tabs[r].groupID,
                  !used.contains(split.left), !used.contains(split.right) else { continue }
            used.insert(split.left)
            used.insert(split.right)
            result.append(split)
        }
        return result
    }
}
