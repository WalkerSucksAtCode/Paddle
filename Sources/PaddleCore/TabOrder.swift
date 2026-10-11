import Foundation

/// Tab-strip ordering rules. Pinned tabs always come first.
public enum TabOrder {
    /// Slot for a tab opened from the tab at `anchor`: right after it, like Safari, and after any tabs already
    /// opened from it (`openedFromAnchor`), so several Cmd-clicked links keep their order. A pinned tab stays in
    /// the pinned group and an unpinned one outside it.
    public static func insertionIndex(after anchor: Int, isPinned: Bool, pinnedFlags: [Bool], openedFromAnchor: [Bool] = []) -> Int {
        let boundary = pinBoundary(pinnedFlags)
        if isPinned { return min(anchor + 1, boundary) }
        var index = max(anchor + 1, boundary)
        while index < openedFromAnchor.count, openedFromAnchor[index] { index += 1 }
        return index
    }

    /// Drops the item at `source` onto the item at `target`: it takes the target's slot, so dragging right lands
    /// after the target and dragging left lands before it. Every slot, including the last, is reachable.
    public static func move<Element>(_ items: inout [Element], from source: Int, onto target: Int) {
        guard source != target, items.indices.contains(source), items.indices.contains(target) else { return }
        items.insert(items.remove(at: source), at: target)
    }

    /// Index of the first unpinned tab: where a newly pinned tab ends up and where an unpinned one starts.
    public static func pinBoundary(_ pinnedFlags: [Bool]) -> Int {
        pinnedFlags.firstIndex(of: false) ?? pinnedFlags.count
    }
}
