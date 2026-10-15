import Foundation
import Testing

@testable import PaddleCore

struct SplitsTests {
    private func tabs(_ ids: String..., pinned: Set<String> = [], groups: [String: String] = [:]) -> [SplitTab] {
        ids.map { SplitTab(id: $0, groupID: groups[$0], isPinned: pinned.contains($0)) }
    }

    @Test func keepsAValidSplit() {
        let split = SplitRecord(left: "a", right: "b", ratio: 0.4)
        #expect(SplitRules.normalized(splits: [split], tabs: tabs("x", "a", "b", "y")) == [split])
    }

    @Test func dropsMissingTab() {
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "zz")], tabs: tabs("a", "b")).isEmpty)
    }

    @Test func dropsPinnedTab() {
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "b")], tabs: tabs("a", "b", pinned: ["b"])).isEmpty)
    }

    @Test func dropsNonAdjacentOrReversed() {
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "c")], tabs: tabs("a", "b", "c")).isEmpty)
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "b", right: "a")], tabs: tabs("a", "b")).isEmpty)
    }

    @Test func dropsDifferentGroups() {
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "b")], tabs: tabs("a", "b", groups: ["a": "g"])).isEmpty)
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "b")], tabs: tabs("a", "b", groups: ["a": "g", "b": "h"])).isEmpty)
        let same = SplitRecord(left: "a", right: "b")
        #expect(SplitRules.normalized(splits: [same], tabs: tabs("a", "b", groups: ["a": "g", "b": "g"])) == [same])
    }

    @Test func dropsReusedTabKeepingOrder() {
        let first = SplitRecord(left: "a", right: "b")
        let second = SplitRecord(left: "b", right: "c")
        let third = SplitRecord(left: "c", right: "d")
        #expect(SplitRules.normalized(splits: [first, second, third], tabs: tabs("a", "b", "c", "d")) == [first, third])
        #expect(SplitRules.normalized(splits: [SplitRecord(left: "a", right: "a")], tabs: tabs("a")).isEmpty)
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
        let old = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0}"#.utf8))
        #expect(old.splits.isEmpty)
        let bad = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0,"splits":[{"left":"a","right":"b"},{"x":1},5]}"#.utf8))
        #expect(bad.splits.count == 1)
    }
}
