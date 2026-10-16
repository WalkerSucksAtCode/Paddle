import CryptoKit
import Foundation

/// session.json plus each tab's back/forward state in `sessions/<tab id>.state`. session.json is small
/// records that name those files: a save rewrites it in a few KB and writes a state file only when its
/// bytes changed (a sleeping tab's state never does). Unnamed state files are deleted. An older
/// session.json with inline states still loads, then is rewritten in this form.
public struct SessionStore {
    public let file: URL
    public let stateDirectory: URL
    /// Digest of each state file as Paddle last read or wrote it, by file name.
    private var stateDigests: [String: SHA256.Digest] = [:]
    /// session.json's bytes as last read or written, so an unchanged session isn't written again.
    private var sessionBytes: Data?

    /// What one `save` did, for tests and logs.
    public struct SaveResult: Equatable, Sendable {
        public var wroteSession = false
        public var statesWritten: [String] = []
        public var statesDeleted: [String] = []
    }

    public init(file: URL, stateDirectory: URL) {
        self.file = file
        self.stateDirectory = stateDirectory
    }

    /// Where a session.json that didn't decode is moved.
    public var badFile: URL { file.appendingPathExtension("bad") }

    /// The saved session with every tab's state read back in, or nil when there is none or it doesn't decode.
    /// Tab ids that aren't UUIDs or repeat an earlier tab's are dropped (they name files), and so are state file
    /// names that aren't `<UUID>.state`; a missing state file leaves that tab to load its URL.
    public mutating func load() -> SessionRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard var session = try? JSONDecoder().decode(SessionRecord.self, from: data) else {
            // Kept as session.json.bad, and the state files it names are kept with it (`save`), so a hand-edit
            // gone wrong can be fixed and renamed back without losing every tab's history.
            try? FileManager.default.removeItem(at: badFile)
            try? FileManager.default.moveItem(at: file, to: badFile)
            return nil
        }
        sessionBytes = data
        var seen = Set<String>()
        for w in session.windows.indices {
            session.windows[w].updateTabs { tab in
                tab.id = tab.id.flatMap(UUID.init(uuidString:))?.uuidString
                if let id = tab.id, !seen.insert(id).inserted { tab.id = nil }
                if let name = tab.stateFile, Self.isStateFileName(name),
                   let state = try? Data(contentsOf: stateDirectory.appending(path: name)) {
                    tab.interactionState = state
                    stateDigests[name] = SHA256.hash(data: state)
                }
                tab.stateFile = nil
            }
        }
        return session
    }

    /// Writes the state files that changed, then session.json unless its bytes are the same as last time, then
    /// deletes state files no tab names. Throws when a write fails; nothing is deleted then.
    @discardableResult
    public mutating func save(_ session: SessionRecord) throws -> SaveResult {
        var result = SaveResult()
        var onDisk = session
        var referenced = Set<String>()
        for w in onDisk.windows.indices {
            try onDisk.windows[w].updateTabs { tab in
                tab.stateFile = nil
                if let state = tab.interactionState {
                    var id = tab.id.flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
                    if referenced.contains(id + ".state") { id = UUID().uuidString }
                    let name = id + ".state"
                    referenced.insert(name)
                    let digest = SHA256.hash(data: state)
                    // The digest says what Paddle last wrote; the existence check repairs a file removed since.
                    let path = stateDirectory.appending(path: name).path
                    if stateDigests[name] != digest || !FileManager.default.fileExists(atPath: path) {
                        if result.statesWritten.isEmpty {
                            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
                        }
                        try state.write(to: stateDirectory.appending(path: name), options: .atomic)
                        stateDigests[name] = digest
                        result.statesWritten.append(name)
                    }
                    tab.id = id
                    tab.stateFile = name
                    tab.interactionState = nil
                }
            }
        }

        let encoder = JSONEncoder()
        // Sorted keys, so the same session always encodes to the same bytes.
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(onDisk)
        if bytes != sessionBytes {
            try bytes.write(to: file, options: .atomic)
            sessionBytes = bytes
            result.wroteSession = true
        }

        referenced.formUnion(statesNamedByBadFile())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".state") && !referenced.contains(name) {
            try? FileManager.default.removeItem(at: stateDirectory.appending(path: name))
            stateDigests[name] = nil
            result.statesDeleted.append(name)
        }
        return result
    }

    /// State file names that appear anywhere in session.json.bad, read as text since it didn't decode.
    private func statesNamedByBadFile() -> Set<String> {
        guard let text = try? String(contentsOf: badFile, encoding: .utf8) else { return [] }
        let pattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.state/
        return Set(text.matches(of: pattern).map { String($0.output) })
    }

    /// `<UUID>.state`: the only names `load` reads, so a hand-edited session.json can't point outside sessions/.
    static func isStateFileName(_ name: String) -> Bool {
        name.hasSuffix(".state") && UUID(uuidString: String(name.dropLast(6))) != nil
    }
}

extension SessionRecord {
    /// Keeps back/forward state only for the `limit` most recently active tabs that have one, plus every pinned
    /// tab; the others restore by URL only. Ties keep the earlier tab.
    public func cappingStates(to limit: Int) -> SessionRecord {
        // `space` -1 is the window's own tabs, else an index into `otherSpaces`.
        var ranked: [(window: Int, space: Int, tab: Int, order: Int, date: Date)] = []
        for (w, window) in windows.enumerated() {
            for (t, tab) in window.tabs.enumerated() where tab.interactionState != nil && !tab.isPinned {
                ranked.append((w, -1, t, ranked.count, tab.lastActive ?? .distantPast))
            }
            for (s, space) in window.otherSpaces.enumerated() {
                for (t, tab) in space.tabs.enumerated() where tab.interactionState != nil && !tab.isPinned {
                    ranked.append((w, s, t, ranked.count, tab.lastActive ?? .distantPast))
                }
            }
        }
        ranked.sort { $0.date != $1.date ? $0.date > $1.date : $0.order < $1.order }
        var capped = self
        for entry in ranked.dropFirst(max(limit, 0)) {
            if entry.space < 0 {
                capped.windows[entry.window].tabs[entry.tab].interactionState = nil
            } else {
                capped.windows[entry.window].otherSpaces[entry.space].tabs[entry.tab].interactionState = nil
            }
        }
        return capped
    }
}

/// When a debounced session save runs: `debounce` after the latest change, but never later than `maxLatency`
/// after the first change not yet saved, so steady tab switching can't put the save off for good.
public enum SessionSaveTiming {
    public static let debounce: TimeInterval = 10
    public static let maxLatency: TimeInterval = 30

    public static func deadline(lastChange: Date, firstUnsaved: Date) -> Date {
        min(lastChange.addingTimeInterval(debounce), firstUnsaved.addingTimeInterval(maxLatency))
    }
}
