import Foundation
@testable import PaddleCore
import Testing

struct ProfilesTests {
    private func decode(_ json: String) throws -> ProfilesFile {
        try ProfilesFile.decode(Data(json.utf8))
    }

    @Test func emptyFileHasOnlyTheDefaultProfile() throws {
        let file = try decode("{}")
        #expect(file.profiles == [Profile(id: "default", name: "Personal", symbol: .person)])
    }

    @Test func defaultComesFirstAndMayBeRenamed() throws {
        let work = UUID().uuidString
        let file = try decode("""
        {"profiles":[{"id":"\(work)","name":"Work","symbol":"work"},{"id":"default","name":"Me","symbol":"leaf"}]}
        """)
        #expect(file.profiles.map(\.id) == ["default", work])
        #expect(file.profiles[0].name == "Me")
        #expect(file.profiles[0].symbol == .leaf)
    }

    @Test func badEntriesAndDuplicatesAreSkipped() throws {
        let id = UUID().uuidString
        let file = try decode("""
        {"profiles":[5,{"name":"no id"},{"id":"not-a-uuid","name":"X"},{"id":"\(UUID().uuidString)","name":""},
        {"id":"\(id)","name":"One"},{"id":"\(id)","name":"Two"}]}
        """)
        #expect(file.profiles.map(\.id) == ["default", id])
        #expect(file.profile(id: id)?.name == "One")
    }

    @Test func lenientFieldsFallBack() throws {
        let id = UUID().uuidString
        let file = try decode(#"{"profiles":[{"id":"\#(id)","name":"One","symbol":"nonsense","extensions":{"a":true,"b":"x"}}]}"#)
        let one = try #require(file.profile(id: id))
        #expect(one.symbol == .person)
        #expect(one.extensions == ["a": true])
    }

    @Test func addRenameSymbolRemove() throws {
        var file = ProfilesFile()
        let work = file.add(name: "  Work ", symbol: .work)
        #expect(work.name == "Work")
        #expect(UUID(uuidString: work.id) != nil)
        let ok28680 = file.rename(id: work.id, to: "Job")
        #expect(ok28680)
        let ok38459 = file.rename(id: work.id, to: "  ")
        #expect(!ok38459)
        let ok74797 = file.setSymbol(.tools, for: work.id)
        #expect(ok74797)
        #expect(file.profile(id: work.id)?.name == "Job")
        #expect(file.profile(id: work.id)?.symbol == .tools)
        let ok42126 = file.remove(id: "default")
        #expect(!ok42126)
        let ok32089 = file.remove(id: work.id)
        #expect(ok32089)
        #expect(file.profiles.count == 1)
    }

    @Test func extensionsAreForNonDefaultProfiles() {
        var file = ProfilesFile()
        let work = file.add(name: "Work", symbol: .work)
        let ok38783 = file.setExtension(folder: "pass", on: true, for: work.id)
        #expect(ok38783)
        #expect(file.profile(id: work.id)?.extensions == ["pass": true])
        let ok23493 = file.setExtension(folder: "pass", on: true, for: "default")
        #expect(!ok23493)
        let ok63357 = file.setExtension(folder: "pass", on: true, for: "missing")
        #expect(!ok63357)
    }

    @Test func roundTripsSorted() throws {
        var file = ProfilesFile()
        file.add(name: "Work", symbol: .work)
        let data = try file.encoded()
        #expect(try ProfilesFile.decode(data) == file)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"))
    }

    @Test func symbolsHaveNamesAndSFSymbols() {
        #expect(ProfileSymbol.allCases.count == 10)
        for symbol in ProfileSymbol.allCases {
            #expect(!symbol.displayName.isEmpty)
            #expect(!symbol.sfSymbol.isEmpty)
        }
    }

    @Test func windowRecordProfileRoundTripsAndOldFilesDecode() throws {
        let record = WindowRecord(tabs: [], selectedIndex: 0, profile: "abc")
        let back = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        #expect(back.profile == "abc")
        let old = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0}"#.utf8))
        #expect(old.profile == nil)
        let bad = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"tabs":[],"selectedIndex":0,"profile":5}"#.utf8))
        #expect(bad.profile == nil)
    }

    @Test func namesStayUnique() {
        var file = ProfilesFile()
        let first = file.add(name: "Work", symbol: .work)
        let second = file.add(name: " work ", symbol: .work)
        #expect(first.name == "Work")
        #expect(second.name == "work 2")
        let upper = file.rename(id: second.id, to: "WORK")
        let blank = file.rename(id: second.id, to: "  ")
        let ownName = file.rename(id: first.id, to: "work")
        #expect(!upper)
        #expect(!blank)
        #expect(ownName)
        #expect(file.profile(id: second.id)?.name == "work 2")
    }
}
