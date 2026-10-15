import Foundation
@testable import PaddleCore
import Testing

struct TabGroupsTests {
    /// "P" is a pinned tab, "-" an ungrouped one, any other letter a member of that group.
    func slots(_ spec: String) -> [TabSlot] {
        spec.map { $0 == "P" ? TabSlot(groupID: nil, isPinned: true) : TabSlot(groupID: $0 == "-" ? nil : String($0)) }
    }

    @Test func contiguousOrderGathersAtFirstMember() {
        #expect(TabGroups.contiguousOrder(slots("a-a-b-b")) == [0, 2, 1, 3, 4, 6, 5])
        #expect(TabGroups.contiguousOrder(slots("-ab-ab")) == [0, 1, 4, 2, 5, 3])
    }

    @Test func contiguousOrderKeepsAnOrderedStripAsIs() {
        #expect(TabGroups.contiguousOrder(slots("Paa-bb")) == [0, 1, 2, 3, 4, 5])
        #expect(TabGroups.contiguousOrder([]) == [])
    }

    @Test func insertionJoinsTheAnchorsGroup() {
        let strip = slots("P-aa-")
        #expect(TabGroups.groupForInsertion(after: 2, slots: strip) == "a")
        #expect(TabGroups.groupForInsertion(after: 3, slots: strip) == "a")
        #expect(TabGroups.groupForInsertion(after: 1, slots: strip) == nil)
        #expect(TabGroups.groupForInsertion(after: 0, slots: strip) == nil)
        #expect(TabGroups.groupForInsertion(after: 9, slots: strip) == nil)
    }

    @Test func emptyGroupsAreDropped() {
        let groups = [
            TabGroupRecord(id: "a", name: "A", color: .blue),
            TabGroupRecord(id: "b", name: "B", color: .red),
        ]
        #expect(TabGroups.liveGroups(groups, slots: slots("-a-a")) == [groups[0]])
        #expect(TabGroups.liveGroups(groups, slots: slots("---")) == [])
    }

    @Test func colorTitles() {
        #expect(TabGroupColor.allCases.count == 9)
        #expect(TabGroupColor.grey.title == "Grey")
    }

    @Test func sessionRoundTripsTitlesAndGroups() throws {
        let group = TabGroupRecord(id: "g1", name: "Work", color: .purple, collapsed: true)
        let session = SessionRecord(windows: [
            WindowRecord(tabs: [
                TabRecord(url: "https://a.test", title: "A", customTitle: "Mine", groupID: "g1"),
                TabRecord(url: "https://b.test", title: "B"),
            ], selectedIndex: 0, groups: [group]),
        ])
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        #expect(decoded.windows[0].tabs[0].customTitle == "Mine")
        #expect(decoded.windows[0].groups == [group])
    }

    @Test func oldSessionFileLoads() throws {
        let json = #"{"windows":[{"tabs":[{"url":"https://a.test","title":"A","isPinned":false}],"selectedIndex":0}]}"#
        let session = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(session.windows[0].groups.isEmpty)
        #expect(session.windows[0].tabs[0].customTitle == nil)
        #expect(session.windows[0].tabs[0].groupID == nil)
        let encoded = String(decoding: try JSONEncoder().encode(session.windows[0].tabs[0]), as: UTF8.self)
        #expect(!encoded.contains("customTitle") && !encoded.contains("groupID"))
    }

    @Test func savingKeepsOnlyGroupsWithSavedTabs() {
        let groups = [TabGroupRecord(id: "a", name: "A", color: .blue), TabGroupRecord(id: "b", name: "B", color: .red)]
        let record = WindowRecord.saving(
            [0, 1], selected: { $0 == 0 }, isSaved: { $0 == 0 },
            record: { TabRecord(url: "u\($0)", title: "", groupID: $0 == 0 ? "a" : "b") }, frame: nil, groups: groups
        )
        #expect(record.groups == [groups[0]])
    }
}
