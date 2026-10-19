import Foundation
import Testing

@testable import PaddleCore

struct SplitsTests {
    private func tabs(_ ids: String..., pinned: Set<String> = [], groups: [String: String] = [:]) -> [SplitTab] {
        ids.map { SplitTab(id: $0, groupID: groups[$0], isPinned: pinned.contains($0)) }
    }

    private func pair(_ a: String, _ b: String) -> PaneLayout { PaneLayout(a, b)! }

    @Test func keepsAValidLayoutInAnyStripOrder() {
        var three = pair("a", "b")
        three.insert("c", at: "a", edge: .bottom)
        #expect(MultiViewRules.normalized(layouts: [three], tabs: tabs("x", "c", "b", "a", "y")) == [three])
    }

    @Test func dropsMissingAndPinnedTabsShrinkingTheLayout() {
        var three = pair("a", "b")
        three.insert("c", at: "b", edge: .right)
        #expect(MultiViewRules.normalized(layouts: [three], tabs: tabs("a", "b")).first?.tabs == ["a", "b"])
        #expect(MultiViewRules.normalized(layouts: [three], tabs: tabs("a", "b", "c", pinned: ["c"])).first?.tabs == ["a", "b"])
        #expect(MultiViewRules.normalized(layouts: [pair("a", "zz")], tabs: tabs("a", "b")).isEmpty)
    }

    @Test func keepsTheLongestRunOfNeighbours() {
        var four = pair("a", "b")
        four.insert("c", at: "b", edge: .right)
        four.insert("d", at: "c", edge: .right)
        #expect(MultiViewRules.normalized(layouts: [four], tabs: tabs("a", "b", "c", "x", "d")).first?.tabs == ["a", "b", "c"])
        #expect(MultiViewRules.normalized(layouts: [pair("a", "c")], tabs: tabs("a", "b", "c")).isEmpty)
    }

    @Test func keepsTheFirstTabsGroup() {
        let layout = pair("a", "b")
        #expect(MultiViewRules.normalized(layouts: [layout], tabs: tabs("a", "b", groups: ["a": "g"])).isEmpty)
        #expect(MultiViewRules.normalized(layouts: [layout], tabs: tabs("a", "b", groups: ["a": "g", "b": "g"])) == [layout])
    }

    @Test func aTabBelongsToTheFirstLayoutOnly() {
        let first = pair("a", "b"), second = pair("b", "c"), third = pair("c", "d")
        #expect(MultiViewRules.normalized(layouts: [first, second, third], tabs: tabs("a", "b", "c", "d")) == [first, third])
    }

    @Test func ratioIsClampedOnDecode() throws {
        let low = try JSONDecoder().decode(SplitRecord.self, from: Data(#"{"left":"a","right":"b","ratio":0.01}"#.utf8))
        let high = try JSONDecoder().decode(SplitRecord.self, from: Data(#"{"left":"a","right":"b","ratio":3}"#.utf8))
        let none = try JSONDecoder().decode(SplitRecord.self, from: Data(#"{"left":"a","right":"b"}"#.utf8))
        #expect(low.ratio == 0.25)
        #expect(high.ratio == 0.75)
        #expect(none.ratio == 0.5)
    }

    @Test func sessionRoundTripAndOldFiles() throws {
        let split = SplitRecord(left: "a", right: "b", ratio: 0.6)
        let other = SpaceRecord(id: "two", splits: [SplitRecord(left: "c", right: "d")])
        let window = WindowRecord(
            tabs: [TabRecord(url: "https://a.test", title: "A", id: "a"), TabRecord(url: "https://b.test", title: "B", id: "b")],
            selectedIndex: 0, otherSpaces: [other], splits: [split]
        )
        let back = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(window))
        #expect(back == window)
        #expect(back.splits == [split])
        #expect(back.otherSpaces[0].splits.count == 1)
        #expect(back.allLayouts == [PaneLayout(split: split)])
        let withLayout = WindowRecord(tabs: [], selectedIndex: 0, layouts: [pair("x", "y")])
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(withLayout))
        #expect(decoded.layouts == [pair("x", "y")] && decoded.splits.isEmpty)
        #expect(other.allLayouts.first?.tabs == ["c", "d"])
        let old = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0}"#.utf8))
        #expect(old.splits.isEmpty)
        let bad = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0,"splits":[{"left":"a","right":"b"},{"x":1},5]}"#.utf8))
        #expect(bad.splits.count == 1)
    }
}
