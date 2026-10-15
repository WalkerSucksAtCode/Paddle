import Foundation

/// Chrome's tab group colours.
public enum TabGroupColor: String, Codable, CaseIterable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    public var title: String { rawValue.capitalized }
}

/// A named, coloured run of tabs that can be collapsed to its label. Tabs name their group by `id`.
public struct TabGroupRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var color: TabGroupColor
    public var collapsed: Bool

    public init(id: String, name: String, color: TabGroupColor, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }
}

/// What the grouping rules need to know about one tab.
public struct TabSlot: Equatable, Sendable {
    public var groupID: String?
    public var isPinned: Bool

    public init(groupID: String?, isPinned: Bool = false) {
        self.groupID = groupID
        self.isPinned = isPinned
    }
}

/// Tab group rules on the strip's order. Pinned tabs never belong to a group (callers clear it).
public enum TabGroups {
    /// The new order, as indices into `slots`, with each group's members adjacent at the place of its first member.
    /// Every other tab keeps its relative order.
    public static func contiguousOrder(_ slots: [TabSlot]) -> [Int] {
        var order: [Int] = []
        var placed = Set<String>()
        for (index, slot) in slots.enumerated() {
            guard let id = slot.groupID, !slot.isPinned else {
                order.append(index)
                continue
            }
            if placed.insert(id).inserted {
                order.append(contentsOf: slots.indices.filter { slots[$0].groupID == id && !slots[$0].isPinned })
            }
        }
        return order
    }

    /// The group a tab inserted right after `anchor` joins: the anchor's own. Nil when the anchor is ungrouped,
    /// pinned or not in `slots`.
    public static func groupForInsertion(after anchor: Int, slots: [TabSlot]) -> String? {
        guard slots.indices.contains(anchor), !slots[anchor].isPinned else { return nil }
        return slots[anchor].groupID
    }

    /// `groups` without the ones no tab belongs to.
    public static func liveGroups(_ groups: [TabGroupRecord], slots: [TabSlot]) -> [TabGroupRecord] {
        let used = Set(slots.filter { !$0.isPinned }.compactMap(\.groupID))
        return groups.filter { used.contains($0.id) }
    }
}
