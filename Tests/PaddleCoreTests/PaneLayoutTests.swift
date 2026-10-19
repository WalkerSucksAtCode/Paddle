import CoreGraphics
import Foundation
@testable import PaddleCore
import Testing

/// Runs a mutating call and returns its result, since `#expect` can't take one directly.
private func mutate(_ layout: inout PaneLayout, _ body: (inout PaneLayout) -> Bool) -> Bool { body(&layout) }

struct PaneLayoutTests {
    private let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func layout(_ a: String = "a", _ b: String = "b") throws -> PaneLayout {
        try #require(PaneLayout(a, b))
    }

    @Test func splitRecordBecomesTwoPanesSideBySide() {
        let layout = PaneLayout(split: SplitRecord(left: "l", right: "r", ratio: 0.6))
        #expect(layout.tabs == ["l", "r"])
        #expect(layout.root == .split(.horizontal, ratio: 0.6, .tab("l"), .tab("r")))
    }

    @Test func droppingOnAnEdgeSplitsThatPane() throws {
        var l = try layout()
        #expect(mutate(&l) { $0.insert("c", at: "b", edge: .bottom) })
        #expect(l.root == .split(.horizontal, ratio: 0.5, .tab("a"), .split(.vertical, ratio: 0.5, .tab("b"), .tab("c"))))
        #expect(mutate(&l) { $0.insert("d", at: "a", edge: .left) })
        #expect(l.tabs == ["d", "a", "b", "c"])
        #expect(!mutate(&l) { $0.insert("a", at: "b", edge: .top) })
        #expect(!mutate(&l) { $0.insert("e", at: "zz", edge: .top) })
        #expect(l.count == 4)
    }

    @Test func fullLayoutRefusesMore() throws {
        var l = try layout()
        for (i, id) in ["c", "d", "e", "f"].enumerated() { #expect(mutate(&l) { $0.insert(id, at: i.isMultiple(of: 2) ? "a" : "b", edge: .right) }) }
        #expect(l.count == PaneLayout.maxPanes && l.isFull)
        #expect(!mutate(&l) { $0.insert("g", at: "a", edge: .left) })
    }

    @Test func closingAPaneGivesItsSpaceToTheSibling() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        let rest = try #require(l.removing("c"))
        #expect(rest.root == .split(.horizontal, ratio: 0.5, .tab("a"), .tab("b")))
        #expect(rest.removing("a") == nil)  // one left: the multi view ends
        #expect(rest.removing("zz") == rest)  // not shown: unchanged
    }

    @Test func swapMoveAndReplace() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        #expect(mutate(&l) { $0.swap("a", "c") })
        #expect(l.tabs == ["c", "b", "a"])
        #expect(mutate(&l) { $0.move("c", to: "a", edge: .top) })
        #expect(l.root == .split(.vertical, ratio: 0.5, .tab("b"), .split(.vertical, ratio: 0.5, .tab("c"), .tab("a"))))
        #expect(mutate(&l) { $0.replace("b", with: "x") })
        #expect(!mutate(&l) { $0.replace("x", with: "a") })
        var two = try layout()
        #expect(!mutate(&two) { $0.move("a", to: "b", edge: .left) })  // two panes: a swap, not a move
    }

    @Test func ratiosClampAndEqualize() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        #expect(mutate(&l) { $0.setRatio(0.99, at: []) })
        #expect(mutate(&l) { $0.setRatio(0.01, at: [1]) })
        #expect(!mutate(&l) { $0.setRatio(0.5, at: [0]) })  // a tab, not a split
        guard case .split(_, let outer, _, .split(_, let inner, _, _)) = l.root else { Issue.record("shape"); return }
        #expect(outer == PaneLayout.ratioRange.upperBound && inner == PaneLayout.ratioRange.lowerBound)
        l.equalize()
        #expect(l.root == .split(.horizontal, ratio: 0.5, .tab("a"), .split(.vertical, ratio: 0.5, .tab("b"), .tab("c"))))
    }

    @Test func framesAndDividersTileTheRect() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        let frames = l.frames(in: rect, gap: 2)
        #expect(frames["a"] == CGRect(x: 0, y: 0, width: 499, height: 600))
        #expect(frames["b"] == CGRect(x: 501, y: 0, width: 499, height: 299))
        #expect(frames["c"] == CGRect(x: 501, y: 301, width: 499, height: 299))
        let dividers = l.dividers(in: rect, gap: 2)
        #expect(dividers.map(\.path) == [[], [1]])
        #expect(dividers[0].frame == CGRect(x: 499, y: 0, width: 2, height: 600))
        #expect(PaneLayout.ratio(dragging: dividers[0], to: CGPoint(x: 700, y: 10)) == 0.7)
        #expect(PaneLayout.ratio(dragging: dividers[1], to: CGPoint(x: 0, y: 590)) == PaneLayout.ratioRange.upperBound)
    }

    @Test func arrowKeysFindTheNeighbour() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        #expect(l.neighbor(of: "a", toward: .right, in: rect) == "b")  // top one first on a tie: overlap equal, name order
        #expect(l.neighbor(of: "c", toward: .left, in: rect) == "a")
        #expect(l.neighbor(of: "b", toward: .bottom, in: rect) == "c")
        #expect(l.neighbor(of: "c", toward: .top, in: rect) == "b")
        #expect(l.neighbor(of: "a", toward: .left, in: rect) == nil)
    }

    @Test func dropZones() {
        let pane = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 110, y: 200), in: pane) == .left)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 490, y: 200), in: pane) == .right)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 300, y: 105), in: pane) == .top)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 300, y: 295), in: pane) == .bottom)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 300, y: 200), in: pane) == nil)
        #expect(PaneLayout.dropEdge(at: CGPoint(x: 0, y: 0), in: pane) == nil)
    }

    @Test func sessionFormRoundTripsAndDropsMissingTabs() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == l)
        let lenient = #"{"axis":"diagonal","ratio":"wide","first":{"tab":"a"},"second":{"tab":"b"}}"#
        #expect(try JSONDecoder().decode(PaneLayout.self, from: Data(lenient.utf8)).root == .split(.horizontal, ratio: 0.5, .tab("a"), .tab("b")))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PaneLayout.self, from: Data(#"{"tab":"a"}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneLayout.self, from: Data(#"{"first":{"tab":"a"},"second":{"tab":"a"}}"#.utf8))
        }
        #expect(l.keeping(["a", "c"])?.tabs == ["a", "c"])
        #expect(l.keeping(["a"]) == nil)
    }

    @Test func mappedRenamesAndDropsTabs() throws {
        var l = try layout()
        l.insert("c", at: "b", edge: .bottom)
        #expect(l.mapped { ["a": "A", "b": "B", "c": "C"][$0] }?.tabs == ["A", "B", "C"])
        #expect(l.mapped { $0 == "c" ? nil : $0.uppercased() }?.root == .split(.horizontal, ratio: 0.5, .tab("A"), .tab("B")))
        #expect(l.mapped { $0 == "a" ? $0 : nil } == nil)
        #expect(l.mapped { _ in "same" } == nil)
    }

    @Test func nameIsSavedAndKeptThroughEdits() throws {
        var l = try layout()
        l.name = "Research"
        l.insert("c", at: "b", edge: .bottom)
        let back = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(l))
        #expect(back.name == "Research" && back == l)
        #expect(l.removing("c")?.name == "Research")
        #expect(l.mapped { $0.uppercased() }?.name == "Research")
        let blank = try JSONDecoder().decode(PaneLayout.self, from: Data(#"{"name":"  ","first":{"tab":"a"},"second":{"tab":"b"}}"#.utf8))
        #expect(blank.name == nil)
        let unnamed = try layout()
        #expect(!String(decoding: try JSONEncoder().encode(unnamed), as: UTF8.self).contains("name"))
    }

    private func five() throws -> PaneLayout {
        var l = try layout()
        for (new, at) in [("c", "b"), ("d", "c"), ("e", "d")] { l.insert(new, at: at, edge: .right) }
        l.name = "Work"
        return l
    }

    @Test func arrangementsKeepPaneOrderAndShareEvenly() throws {
        let l = try five()
        let columns = l.arranged(.columns)
        #expect(columns.tabs == ["a", "b", "c", "d", "e"] && columns.name == "Work")
        let widths = columns.frames(in: rect, gap: 0).values.map(\.width)
        #expect(widths.allSatisfy { abs($0 - 200) <= 1 })
        #expect(l.arranged(.rows).frames(in: rect, gap: 0).values.allSatisfy { abs($0.height - 120) <= 1 && $0.width == 1000 })
        // Five in a grid: three over two.
        let grid = l.arranged(.grid).frames(in: rect, gap: 0)
        #expect(grid["a"]!.minY == 0 && grid["c"]!.minY == 0 && grid["d"]!.minY == 300 && grid["e"]!.minY == 300)
        #expect(abs(grid["a"]!.width - 333) <= 1 && grid["d"]!.width == 500)
        let main = l.arranged(.mainAndStack).frames(in: rect, gap: 0)
        #expect(main["a"]!.width == 600 && main["a"]!.height == 600)
        #expect(["b", "c", "d", "e"].allSatisfy { main[$0]!.minX == 600 && main[$0]!.height == 150 })
        #expect(l.arranged(.grid).isArranged(.grid) && !l.arranged(.grid).isArranged(.columns))
    }

    @Test func gridOfTwoToSixIsAsSquareAsItCanBe() throws {
        var l = try layout()
        for (count, new) in zip(3...6, ["c", "d", "e", "f"]) {
            l.insert(new, at: l.tabs.last!, edge: .right)
            let rows = Set(l.arranged(.grid).frames(in: rect, gap: 0).values.map(\.minY)).count
            #expect(rows == (count <= 2 ? 1 : 2), "\(count) panes")
        }
    }

    @Test func evenOutSharesARunOfColumnsEqually() throws {
        var l = try five()
        l.equalize()
        #expect(l.frames(in: rect, gap: 0).values.allSatisfy { abs($0.width - 200) <= 1 })
    }

    @Test func rotatingMovesEachTabOnePaneAlong() throws {
        let l = try five().arranged(.mainAndStack)
        let r = l.rotated()
        #expect(r.tabs == ["e", "a", "b", "c", "d"])
        #expect(r.frames(in: rect)["e"] == l.frames(in: rect)["a"])
        #expect(r.rotated(forward: false) == l)
    }

    @Test func dividerSnapsNearHalvesAndThirds() {
        #expect(PaneLayout.snapped(0.51) == 0.5)
        #expect(PaneLayout.snapped(0.32) == 1.0 / 3)
        #expect(PaneLayout.snapped(0.69) == 2.0 / 3)
        #expect(PaneLayout.snapped(0.42) == 0.42)
    }
}
