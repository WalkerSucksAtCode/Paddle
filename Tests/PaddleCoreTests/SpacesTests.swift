import Foundation
import Testing

@testable import PaddleCore

struct SpacesTests {
    private func decode(_ json: String) throws -> WindowRecord {
        try JSONDecoder().decode(WindowRecord.self, from: Data(json.utf8))
    }

    @Test func oldFileIsOneSpace() throws {
        let window = try decode(#"{"tabs":[{"url":"https://a.test","title":"A","isPinned":false}],"selectedIndex":0}"#)
        #expect(window.space == nil)
        #expect(window.otherSpaces.isEmpty)
        #expect(window.tabs.count == 1)
    }

    @Test func roundTripWithTwoSpaces() throws {
        let active = SpaceRecord(id: "one", name: "Main", symbol: .home)
        let other = SpaceRecord(
            id: "two", name: "Work", symbol: SpaceSymbol("briefcase")!, tint: "blue",
            tabs: [TabRecord(url: "https://w.test", title: "W", isPinned: true)], selectedIndex: 0,
            groups: [TabGroupRecord(id: "g", name: "G", color: .red)]
        )
        let window = WindowRecord(
            tabs: [TabRecord(url: "https://a.test", title: "A")], selectedIndex: 0, space: active, otherSpaces: [other],
            spaceIndex: 1
        )
        let back = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(window))
        #expect(back == window)
        #expect(back.spaceIndex == 1)
        #expect(back.allTabRecords.map(\.url) == ["https://a.test", "https://w.test"])
    }

    @Test func badEntriesAreSkipped() throws {
        let window = try decode("""
        {"tabs":[],"selectedIndex":0,"space":{"id":"a","name":"X","symbol":"Not A Symbol!","tint":"chartreuse"},
         "otherSpaces":[{"name":"no id"},{"id":"b","name":"B","symbol":"code","tint":"Green",
           "tabs":[{"url":"https://ok.test","title":"ok","isPinned":false},{"bad":1}],"groups":[{"x":1}]},7]}
        """)
        #expect(window.space?.symbol == .home)
        #expect(window.space?.tint == nil)
        #expect(window.otherSpaces.count == 1)
        #expect(window.otherSpaces[0].symbol.sfSymbol == "chevron.left.forwardslash.chevron.right")
        #expect(window.otherSpaces[0].tint == "green")
        #expect(window.otherSpaces[0].tabs.map(\.url) == ["https://ok.test"])
        #expect(window.otherSpaces[0].groups.isEmpty)
    }

    @Test func windowWithOnlyOtherSpaceTabsIsSaved() {
        let window = WindowRecord(
            tabs: [], selectedIndex: 0, otherSpaces: [SpaceRecord(id: "b", tabs: [TabRecord(url: "https://a.test", title: "A")])]
        )
        let session = SessionRecord.saving([window], isPrivate: { _ in false }, record: { $0 })
        #expect(session.windows.count == 1)
    }

    @Test func cappingCoversOtherSpaces() {
        let now = Date()
        func tab(_ name: String, _ minutes: Double) -> TabRecord {
            TabRecord(url: "https://\(name).test", title: name, interactionState: Data([1]), lastActive: now.addingTimeInterval(-minutes * 60))
        }
        let window = WindowRecord(
            tabs: [tab("a", 10)], selectedIndex: 0, otherSpaces: [SpaceRecord(id: "b", tabs: [tab("b", 1), tab("c", 20)])]
        )
        let capped = SessionRecord(windows: [window]).cappingStates(to: 1).windows[0]
        #expect(capped.tabs[0].interactionState == nil)
        #expect(capped.otherSpaces[0].tabs.map { $0.interactionState != nil } == [true, false])
    }

    @Test func spaceSymbolsReadOldPresetsAndAnySymbolName() throws {
        func decode(_ json: String) throws -> SpaceRecord { try JSONDecoder().decode(SpaceRecord.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"id":"a","symbol":"work"}"#).symbol.sfSymbol == "briefcase")
        #expect(try decode(#"{"id":"a","symbol":"music"}"#).symbol.sfSymbol == "music.note")
        #expect(try decode(#"{"id":"a","symbol":"leaf.fill"}"#).symbol.sfSymbol == "leaf.fill")
        #expect(try decode(#"{"id":"a","symbol":"Not A Symbol"}"#).symbol == .home)
        let record = SpaceRecord(id: "a", symbol: SpaceSymbol("paintbrush.pointed.fill")!)
        let back = try JSONDecoder().decode(SpaceRecord.self, from: JSONEncoder().encode(record))
        #expect(back.symbol.sfSymbol == "paintbrush.pointed.fill")
        #expect(SpaceSymbol("music.note")?.displayName == "music note")
    }
}
