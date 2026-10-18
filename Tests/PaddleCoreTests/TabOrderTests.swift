import Foundation
@testable import PaddleCore
import Testing

struct TabOrderTests {
    @Test func dragRightLandsAfterTarget() {
        var tabs = ["A", "B", "C", "D"]
        TabOrder.move(&tabs, from: 0, onto: 1)
        #expect(tabs == ["B", "A", "C", "D"])
        TabOrder.move(&tabs, from: 1, onto: 3)
        #expect(tabs == ["B", "C", "D", "A"])
    }

    @Test func dragLeftLandsBeforeTarget() {
        var tabs = ["A", "B", "C", "D"]
        TabOrder.move(&tabs, from: 3, onto: 0)
        #expect(tabs == ["D", "A", "B", "C"])
        TabOrder.move(&tabs, from: 2, onto: 1)
        #expect(tabs == ["D", "B", "A", "C"])
    }

    @Test func moveIgnoresSelfAndBadIndices() {
        var tabs = ["A", "B"]
        TabOrder.move(&tabs, from: 1, onto: 1)
        TabOrder.move(&tabs, from: 5, onto: 0)
        TabOrder.move(&tabs, from: 0, onto: -1)
        #expect(tabs == ["A", "B"])
    }

    @Test func newTabsOpenAfterAnchorButOutsidePinnedGroup() {
        let pinned = [true, true, false, false]
        #expect(TabOrder.insertionIndex(after: 2, isPinned: false, pinnedFlags: pinned) == 3)
        #expect(TabOrder.insertionIndex(after: 0, isPinned: false, pinnedFlags: pinned) == 2)
        #expect(TabOrder.insertionIndex(after: 0, isPinned: true, pinnedFlags: pinned) == 1)
        #expect(TabOrder.insertionIndex(after: 3, isPinned: false, pinnedFlags: pinned) == 4)
    }

    @Test func reopenedPinnedTabStaysInPinnedGroup() {
        let pinned = [true, false, false]
        #expect(TabOrder.insertionIndex(after: 2, isPinned: true, pinnedFlags: pinned) == 1)
        #expect(TabOrder.insertionIndex(after: 0, isPinned: true, pinnedFlags: pinned) == 1)
    }

    @Test func linksOpenedFromOnePageKeepTheirOrder() {
        // P at 0, then A and B already opened from P, then an unrelated tab.
        let fromP = [false, true, true, false]
        #expect(TabOrder.insertionIndex(after: 0, isPinned: false, pinnedFlags: [false, false, false, false], openedFromAnchor: fromP) == 3)
        #expect(TabOrder.insertionIndex(after: 0, isPinned: false, pinnedFlags: [false, false], openedFromAnchor: [false, false]) == 1)
    }

    @Test func pinBoundaryIsFirstUnpinned() {
        #expect(TabOrder.pinBoundary([true, true, false]) == 2)
        #expect(TabOrder.pinBoundary([false, false]) == 0)
        #expect(TabOrder.pinBoundary([true, true]) == 2)
        #expect(TabOrder.pinBoundary([]) == 0)
    }

    @Test func selectionAfterClosingFollowsTheRule() {
        let dates = (0..<3).map { Date(timeIntervalSince1970: Double($0)) }
        // Closed the middle of four: three remain.
        #expect(TabOrder.selectionAfterClosing(1, rule: .right, lastActive: dates) == 1)
        #expect(TabOrder.selectionAfterClosing(1, rule: .left, lastActive: dates) == 0)
        // Closed the last or the first.
        #expect(TabOrder.selectionAfterClosing(3, rule: .right, lastActive: dates) == 2)
        #expect(TabOrder.selectionAfterClosing(0, rule: .left, lastActive: dates) == 0)
        let used = [dates[2], dates[0], dates[1]]
        #expect(TabOrder.selectionAfterClosing(1, rule: .lastUsed, lastActive: used) == 0)
        #expect(TabOrder.selectionAfterClosing(0, rule: .right, lastActive: []) == nil)
    }
}
