import Foundation
@testable import PaddleCore
import Testing

struct ExtensionScanTests {
    private let fm = FileManager.default

    /// Runs `body` with a fresh temp directory standing in for `extensions/`.
    private func withTemp(_ body: (URL) throws -> Void) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("PaddleExtScanTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    private func makeExtension(_ dir: URL, _ path: String) throws {
        let folder = dir.appendingPathComponent(path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
    }

    private func resolved(_ url: URL) -> URL { URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }

    @Test func manifestAtTopIsAnEntry() throws {
        try withTemp { dir in
            try makeExtension(dir, "ubolite")
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries == [ExtensionEntry(name: "ubolite", root: resolved(dir.appendingPathComponent("ubolite")))])
            #expect(result.problems.isEmpty)
        }
    }

    @Test func singleNestedFolderIsUsedAsRoot() throws {
        try withTemp { dir in
            try makeExtension(dir, "bitwarden/bitwarden-1.0")
            try fm.createDirectory(at: dir.appendingPathComponent("bitwarden/__MACOSX"), withIntermediateDirectories: true)
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries.map(\.name) == ["bitwarden"])
            #expect(result.entries.first?.root == resolved(dir.appendingPathComponent("bitwarden/bitwarden-1.0")))
        }
    }

    @Test func twoNestedFoldersAreNotGuessedBetween() throws {
        try withTemp { dir in
            try makeExtension(dir, "pair/a")
            try makeExtension(dir, "pair/b")
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries.isEmpty)
            #expect(result.problems["pair"] == "not an extension (needs manifest.json)")
        }
    }

    @Test func folderWithoutManifestIsAProblem() throws {
        try withTemp { dir in
            try fm.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries.isEmpty)
            #expect(result.problems["empty"] == "not an extension (needs manifest.json)")
        }
    }

    @Test func zipAndCrxNeedUnzipping() throws {
        try withTemp { dir in
            for file in ["a.zip", "b.crx", "C.ZIP", "notes.txt"] { try Data().write(to: dir.appendingPathComponent(file)) }
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries.isEmpty)
            #expect(result.problems == ["a.zip": "unzip it into a folder first", "b.crx": "unzip it into a folder first",
                                        "C.ZIP": "unzip it into a folder first"])
        }
    }

    @Test func hiddenAndUnderscoreNamesAreSkipped() throws {
        try withTemp { dir in
            try makeExtension(dir, ".hidden")
            try makeExtension(dir, "_disabled")
            try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try makeExtension(dir, "visible")
            let result = ExtensionScan.scan(dir, forbiddenRoots: [])
            #expect(result.entries.map(\.name) == ["visible"])
            #expect(result.problems.isEmpty)
        }
    }

    @Test func entriesAreSortedByName() throws {
        try withTemp { dir in
            for name in ["zeta", "alpha", "mid"] { try makeExtension(dir, name) }
            #expect(ExtensionScan.scan(dir, forbiddenRoots: []).entries.map(\.name) == ["alpha", "mid", "zeta"])
        }
    }

    @Test func missingDirectoryGivesNothing() {
        let result = ExtensionScan.scan(URL(fileURLWithPath: "/nonexistent/paddle-extensions"), forbiddenRoots: [])
        #expect(result.entries.isEmpty && result.problems.isEmpty)
    }

    @Test func symlinkedFolderResolvesToAnAbsoluteRoot() throws {
        try withTemp { dir in
            let checkout = dir.appendingPathComponent("checkout/real-ext")
            try makeExtension(dir, "checkout/real-ext")
            let extensions = dir.appendingPathComponent("extensions")
            try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: extensions.appendingPathComponent("dev"), withDestinationURL: checkout)
            let result = ExtensionScan.scan(extensions, forbiddenRoots: [])
            let entry = try #require(result.entries.first)
            #expect(entry.name == "dev")
            #expect(entry.root == resolved(checkout))
            #expect(entry.root.path.hasPrefix("/"))
            #expect(entry.root.pathComponents.allSatisfy { $0 != ".." && $0 != "." })
        }
    }

    @Test func symlinkToAForbiddenRootIsRefused() throws {
        try withTemp { dir in
            let home = dir.appendingPathComponent("home")
            try makeExtension(dir, "home") // home itself has a manifest, to prove the refusal is not about that
            let extensions = dir.appendingPathComponent("extensions")
            try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: extensions.appendingPathComponent("sneaky"), withDestinationURL: home)
            let result = ExtensionScan.scan(extensions, forbiddenRoots: [home])
            #expect(result.entries.isEmpty)
            #expect(result.problems["sneaky"] == "points at a protected folder")
        }
    }

    @Test func symlinkToAFolderContainingAForbiddenRootIsRefused() throws {
        try withTemp { dir in
            let support = dir.appendingPathComponent("tree/home/Library/Support")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tree/manifest.json"))
            let extensions = dir.appendingPathComponent("extensions")
            try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: extensions.appendingPathComponent("wide"), withDestinationURL: dir.appendingPathComponent("tree"))
            let result = ExtensionScan.scan(extensions, forbiddenRoots: [support])
            #expect(result.entries.isEmpty)
            #expect(result.problems["wide"] == "points at a protected folder")
        }
    }

    @Test func ordinaryFolderInsideAForbiddenRootIsAllowed() throws {
        try withTemp { dir in
            let extensions = dir.appendingPathComponent("extensions")
            try makeExtension(dir, "extensions/fine")
            // The extensions folder lives inside the forbidden "support" folder, as it does in the app.
            let result = ExtensionScan.scan(extensions, forbiddenRoots: [dir])
            #expect(result.entries.map(\.name) == ["fine"])
        }
    }
}
