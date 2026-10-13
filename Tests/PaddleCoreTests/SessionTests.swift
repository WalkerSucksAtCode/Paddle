import Foundation
@testable import PaddleCore
import Testing

struct SessionTests {
    @Test func roundTrips() throws {
        let session = SessionRecord(windows: [
            WindowRecord(tabs: [
                TabRecord(url: "https://a.test", title: "A", isPinned: true, interactionState: Data([1, 2, 3])),
                TabRecord(url: "https://b.test", title: "B"),
            ], selectedIndex: 1, frame: "{{0, 0}, {800, 600}}"),
        ])
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(SessionRecord.self, from: data) == session)
    }
}

/// session.json with the states in sessions/<id>.state, in a fresh temporary folder per test.
final class SessionStoreTests {
    let folder: URL
    let file: URL
    let states: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appending(path: "session.json")
        states = folder.appending(path: "sessions")
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func store() -> SessionStore { SessionStore(file: file, stateDirectory: states) }
    private func stateFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: states.path)) ?? []).sorted()
    }

    private let a = UUID().uuidString
    private let b = UUID().uuidString

    private func session(stateA: Data? = Data([1]), stateB: Data? = Data([2]), titleB: String = "B") -> SessionRecord {
        SessionRecord(windows: [WindowRecord(tabs: [
            TabRecord(url: "https://a.test", title: "A", interactionState: stateA, id: a),
            TabRecord(url: "https://b.test", title: titleB, isPinned: true, interactionState: stateB, id: b),
        ], selectedIndex: 0)])
    }

    @Test func migratesInlineStatesToFiles() throws {
        // A session.json from before: states inline, no ids.
        let old = SessionRecord(windows: [WindowRecord(tabs: [
            TabRecord(url: "https://a.test", title: "A", interactionState: Data([7, 7])),
            TabRecord(url: "https://b.test", title: "B"),
        ], selectedIndex: 1)])
        try JSONEncoder().encode(old).write(to: file)

        var first = store()
        let firstLoad = first.load()
        let loaded = try #require(firstLoad)
        #expect(loaded.windows[0].tabs[0].interactionState == Data([7, 7]))
        #expect(loaded.windows[0].tabs[1].interactionState == nil)
        let result = try first.save(loaded)
        #expect(result.wroteSession)
        #expect(result.statesWritten.count == 1)
        #expect(stateFiles() == result.statesWritten)
        // No state inline any more; the record names its file.
        let raw = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))
        #expect(raw.windows[0].tabs[0].interactionState == nil)
        #expect(raw.windows[0].tabs[0].stateFile == result.statesWritten.first)
        #expect(raw.windows[0].tabs[1].stateFile == nil)

        // Next launch: every tab comes back as it was.
        var second = store()
        let secondLoad = second.load()
        let restored = try #require(secondLoad)
        #expect(restored.windows[0].tabs.map(\.url) == ["https://a.test", "https://b.test"])
        #expect(restored.windows[0].tabs.map(\.interactionState) == [Data([7, 7]), nil])
        #expect(restored.windows[0].selectedIndex == 1)
        #expect(restored.windows[0].tabs.allSatisfy { $0.stateFile == nil })
    }

    @Test func writesOnlyChangedStatesAndSkipsIdenticalBytes() throws {
        var s = store()
        let first = try s.save(session())
        #expect(first.wroteSession)
        #expect(first.statesWritten == ["\(a).state", "\(b).state"])

        // Nothing changed: nothing is written.
        let same = try s.save(session())
        #expect(same == SessionStore.SaveResult())

        // One tab's history changed: only its file, and session.json stays as it was.
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let changed = try s.save(session(stateA: Data([1, 1])))
        #expect(changed.statesWritten == ["\(a).state"])
        #expect(!changed.wroteSession)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)

        // A title change rewrites session.json but no state file.
        let titled = try s.save(session(stateA: Data([1, 1]), titleB: "B2"))
        #expect(titled.wroteSession)
        #expect(titled.statesWritten.isEmpty)

        // After a relaunch the states on disk count as written already.
        var relaunched = store()
        _ = relaunched.load()
        #expect(try relaunched.save(session(stateA: Data([1, 1]), titleB: "B2")) == SessionStore.SaveResult())
    }

    @Test func deletesOrphanStateFiles() throws {
        var s = store()
        try s.save(session())
        let stray = states.appending(path: "\(UUID().uuidString).state")
        try Data([9]).write(to: stray)
        let other = states.appending(path: "notes.txt")
        try Data([9]).write(to: other)

        // Tab A closed (or lost its history): its file and the stray one go; other files stay.
        let result = try s.save(session(stateA: nil))
        #expect(Set(result.statesDeleted) == ["\(a).state", stray.lastPathComponent])
        #expect(stateFiles() == ["\(b).state", "notes.txt"])
    }

    @Test func undecodableSessionKeepsItsStateFiles() throws {
        var s = store()
        try s.save(session())
        // A hand-edit breaks session.json; the next launch opens a default window and saves it.
        var text = try String(contentsOf: file, encoding: .utf8)
        text.removeLast()
        try text.write(to: file, atomically: true, encoding: .utf8)
        var broken = store()
        #expect(broken.load() == nil)
        #expect(FileManager.default.fileExists(atPath: broken.badFile.path))
        let result = try broken.save(SessionRecord(windows: [WindowRecord(tabs: [TabRecord(url: "https://c.test", title: "")], selectedIndex: 0)]))
        #expect(result.statesDeleted.isEmpty)
        #expect(Set(stateFiles()) == ["\(a).state", "\(b).state"])
    }

    @Test func rewritesAStateFileRemovedBehindItsBack() throws {
        var s = store()
        try s.save(session())
        try FileManager.default.removeItem(at: states.appending(path: "\(a).state"))
        #expect(try s.save(session()).statesWritten == ["\(a).state"])
        #expect(Set(stateFiles()) == ["\(a).state", "\(b).state"])
    }

    /// `save` promises that a failed write deletes nothing: state files go before session.json, and orphans are
    /// only deleted after both.
    @Test func failedStateWriteThrowsAndDeletesNothing() throws {
        var s = store()
        try s.save(session())
        let sessionBefore = try Data(contentsOf: file)
        let stray = "\(UUID().uuidString).state"
        try Data([9]).write(to: states.appending(path: stray))
        // Tab A's state file can't be replaced (its name is taken by a folder), and tab B closed.
        try FileManager.default.removeItem(at: states.appending(path: "\(a).state"))
        try FileManager.default.createDirectory(at: states.appending(path: "\(a).state/keep"), withIntermediateDirectories: true)
        let failing = SessionRecord(windows: [WindowRecord(tabs: [
            TabRecord(url: "https://a.test", title: "A", interactionState: Data([5]), id: a),
        ], selectedIndex: 0)])
        #expect(throws: (any Error).self) { try s.save(failing) }
        #expect(Set(stateFiles()) == ["\(a).state", "\(b).state", stray])
        #expect(try Data(contentsOf: file) == sessionBefore)

        // The whole state folder is a regular file: nothing can be written there, and session.json isn't either.
        let blocked = folder.appending(path: "blocked")
        try Data([1]).write(to: blocked)
        var other = SessionStore(file: file, stateDirectory: blocked)
        #expect(throws: (any Error).self) { try other.save(session(stateA: Data([3]))) }
        #expect(try Data(contentsOf: file) == sessionBefore)
        #expect(Set(stateFiles()) == ["\(a).state", "\(b).state", stray])
    }

    @Test func failedSessionWriteThrowsAndDeletesNoStateFile() throws {
        var s = store()
        try s.save(session())
        let stray = "\(UUID().uuidString).state"
        try Data([9]).write(to: states.appending(path: stray))
        // session.json's path is taken by a folder, so the atomic write can't rename over it.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appending(path: "keep"), withIntermediateDirectories: true)
        // Tab A closed: its state file would be an orphan once session.json no longer names it.
        #expect(throws: (any Error).self) { try s.save(session(stateA: nil, titleB: "B2")) }
        #expect(Set(stateFiles()) == ["\(a).state", "\(b).state", stray])
    }

    @Test func loadIgnoresBadNamesAndRepeatedIDs() throws {
        let json = """
            {"windows":[{"selectedIndex":0,"tabs":[
              {"url":"https://a.test","title":"A","isPinned":false,"id":"\(a)","stateFile":"../session.json"},
              {"url":"https://b.test","title":"B","isPinned":false,"id":"\(a)"},
              {"url":"https://c.test","title":"C","isPinned":false,"id":"not-a-uuid","stateFile":"\(b).state"}
            ]}]}
            """
        try Data(json.utf8).write(to: file)
        var s = store()
        let loaded = s.load()
        let tabs = try #require(loaded).windows[0].tabs
        #expect(tabs[0].interactionState == nil)
        #expect(tabs[0].id == a)
        #expect(tabs[1].id == nil)
        #expect(tabs[2].id == nil)
        // A missing state file: the tab loads by URL.
        #expect(tabs[2].interactionState == nil)
    }

    @Test func capKeepsMostRecentAndPinned() {
        let now = Date()
        func tab(_ name: String, minutesAgo: Double?, pinned: Bool = false, state: Bool = true) -> TabRecord {
            TabRecord(
                url: "https://\(name).test", title: name, isPinned: pinned, interactionState: state ? Data([1]) : nil,
                lastActive: minutesAgo.map { now.addingTimeInterval(-$0 * 60) }
            )
        }
        let session = SessionRecord(windows: [
            WindowRecord(tabs: [
                tab("old", minutesAgo: 100), tab("pinned", minutesAgo: 500, pinned: true), tab("newest", minutesAgo: 1),
            ], selectedIndex: 0),
            WindowRecord(tabs: [
                tab("middle", minutesAgo: 50), tab("never", minutesAgo: nil), tab("empty", minutesAgo: 0, state: false),
            ], selectedIndex: 0),
        ])
        func kept(_ limit: Int) -> [String] {
            session.cappingStates(to: limit).windows.flatMap(\.tabs).filter { $0.interactionState != nil }.map(\.title)
        }
        #expect(kept(2) == ["pinned", "newest", "middle"])
        #expect(kept(0) == ["pinned"])
        #expect(kept(-1) == ["pinned"])
        #expect(kept(30) == ["old", "pinned", "newest", "middle", "never"])
        // URLs and everything else stay.
        #expect(session.cappingStates(to: 0).windows.flatMap(\.tabs).map(\.url) == session.windows.flatMap(\.tabs).map(\.url))
    }

    @Test func saveTimingDebouncesWithAMaximum() {
        let start = Date()
        #expect(SessionSaveTiming.deadline(lastChange: start, firstUnsaved: start) == start.addingTimeInterval(10))
        let later = start.addingTimeInterval(25)
        #expect(SessionSaveTiming.deadline(lastChange: later, firstUnsaved: start) == start.addingTimeInterval(30))
    }

    @Test func configKey() throws {
        #expect(PaddleConfig().sessionHistoryTabs == 30)
        #expect(try PaddleConfig.decode(Data(#"{"sessionHistoryTabs": 5}"#.utf8)).sessionHistoryTabs == 5)
    }
}
