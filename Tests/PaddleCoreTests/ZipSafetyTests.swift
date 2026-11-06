import Foundation
@testable import PaddleCore
import Testing
import zlib

struct ZipSafetyTests {
    private typealias Item = TestZip.Item

    private func refusal(_ items: [Item], limits: ZipSafety.Limits = .init()) -> ZipSafety.Refusal? {
        refusal(TestZip.make(items), limits: limits)
    }

    private func refusal(_ data: Data, limits: ZipSafety.Limits = .init()) -> ZipSafety.Refusal? {
        do {
            _ = try ZipSafety.entries(in: data, limits: limits)
            return nil
        } catch let error as ZipSafety.Refusal {
            return error
        } catch {
            return .damaged("unexpected \(error)")
        }
    }

    @Test func validArchiveListsEntries() throws {
        let zip = TestZip.make([
            TestZip.file("manifest.json", "{}"),
            Item(name: "icons/"),
            TestZip.file("icons/16.png", "png"),
            TestZip.file("js/deep/bg.js", "1234"),
            TestZip.file("__MACOSX/._manifest.json", "meta"),
            Item(name: "lib.js", data: Data("abc".utf8), method: 8),
        ])
        let entries = try ZipSafety.entries(in: zip)
        #expect(entries.map(\.name) == ["manifest.json", "icons", "icons/16.png", "js/deep/bg.js", "__MACOSX/._manifest.json", "lib.js"])
        #expect(entries.map(\.isDirectory) == [false, true, false, false, false, false])
        #expect(entries[3].uncompressedSize == 4)
        #expect(entries[0].crc32 == TestZip.crc32(Data("{}".utf8)))
        #expect(entries.filter(\.isMacMetadata).map(\.name) == ["__MACOSX/._manifest.json"])
        #expect(try ZipSafety.entries(in: TestZip.make([])).isEmpty)
    }

    @Test(arguments: ["../x", "a/../../x", "/abs", "a\\b", "a/./b", "./a", "a//b", "a/..", "nul\u{0}.js", "tab\t.js", ".."])
    func unsafeNamesAreRefused(name: String) {
        #expect(refusal([TestZip.file(name)]) == .unsafeName(name))
    }

    @Test func invalidUTF8NameIsRefused() {
        guard case .unsafeName? = refusal([Item(name: "", rawName: [0x61, 0xFF, 0x62])]) else {
            Issue.record("expected unsafeName")
            return
        }
    }

    @Test func linksAndSpecialFilesAreRefused() {
        #expect(refusal([Item(name: "link.js", data: Data("/etc/passwd".utf8), mode: 0o120777)]) == .symlink("link.js"))
        // A link made by any system, not only Unix.
        #expect(refusal([Item(name: "link.js", mode: 0o120777, madeBy: 0x0014)]) == .symlink("link.js"))
        #expect(refusal([Item(name: "fifo", data: Data(), mode: 0o010644)]) == .specialFile("fifo"))
        #expect(refusal([Item(name: "dev", data: Data(), mode: 0o020644)]) == .specialFile("dev"))
        #expect(refusal([Item(name: "dir-as-file", data: Data(), mode: 0o040755)]) == .specialFile("dir-as-file"))
        #expect(refusal([Item(name: "file-as-dir/", mode: 0o100644)]) == .specialFile("file-as-dir/"))
        // No mode bits at all (a DOS-made entry) is fine.
        #expect(refusal([Item(name: "plain.js", mode: 0, madeBy: 0x0014)]) == nil)
    }

    @Test func duplicatesAreRefused() {
        #expect(refusal([TestZip.file("manifest.json"), TestZip.file("Manifest.JSON")]) == .duplicate("Manifest.JSON"))
        #expect(refusal([TestZip.file("a.js"), TestZip.file("a.js")]) == .duplicate("a.js"))
        // Same name in composed and decomposed forms.
        #expect(refusal([TestZip.file("caf\u{E9}.js"), TestZip.file("cafe\u{301}.js")]) == .duplicate("cafe\u{301}.js"))
        #expect(refusal([Item(name: "a/"), TestZip.file("a")]) == .duplicate("a"))
        // A file that is also another entry's folder, in either order.
        #expect(refusal([TestZip.file("lib"), TestZip.file("lib/x.js")]) == .duplicate("lib"))
        #expect(refusal([TestZip.file("LIB/x.js"), TestZip.file("lib")]) == .duplicate("LIB"))
    }

    @Test func encryptedEntriesAreRefused() {
        #expect(refusal([Item(name: "secret.js", flags: 0x0801)]) == .encrypted("secret.js"))
        #expect(refusal([Item(name: "strong.js", flags: 0x0040)]) == .encrypted("strong.js"))
    }

    @Test func compressionMethodsOtherThanStoredAndDeflateAreRefused() {
        #expect(refusal([Item(name: "a.js", method: 12)]) == .unsupportedCompression("a.js", method: 12))
        #expect(refusal([Item(name: "a.js", method: 99)]) == .unsupportedCompression("a.js", method: 99))
    }

    @Test func capsApply() {
        let items = (0..<3).map { TestZip.file("f\($0).js", "1234") }
        #expect(refusal(items, limits: .init(maxEntries: 2)) == .tooManyEntries)
        #expect(refusal(items, limits: .init(maxEntries: 3)) == nil)
        #expect(refusal(items, limits: .init(maxTotalUncompressedSize: 11)) == .tooLarge)
        #expect(refusal(items, limits: .init(maxTotalUncompressedSize: 12)) == nil)
    }

    @Test func truncatedOrInconsistentDirectoriesAreRefused() {
        let zip = TestZip.make([TestZip.file("a.js"), TestZip.file("b.js")])
        let eocd = zip.count - 22
        // Cut 10 bytes off the end of the central directory and shrink its size to match.
        var cut = zip.subdata(in: 0..<(eocd - 10)) + zip.subdata(in: eocd..<zip.count)
        let size = Int(cut[cut.count - 10]) | Int(cut[cut.count - 9]) << 8
        cut[cut.count - 10] = UInt8((size - 10) & 0xFF)
        cut[cut.count - 9] = UInt8((size - 10) >> 8)
        guard case .damaged? = refusal(cut) else { Issue.record("expected damaged for a cut directory"); return }

        // The archive chopped anywhere: no end record at the end any more.
        #expect(refusal(zip.prefix(zip.count - 1)) == .notZip)
        #expect(refusal(Data("not a zip at all, just some text".utf8)) == .notZip)
        #expect(refusal(Data()) == .notZip)

        // Entry counts that disagree.
        var counts = zip
        counts[eocd + 8] = 1
        guard case .damaged? = refusal(counts) else { Issue.record("expected damaged for counts"); return }

        // A central directory offset past the data.
        var offset = zip
        offset[eocd + 19] = 0x7F
        guard case .damaged? = refusal(offset) else { Issue.record("expected damaged for offset"); return }
    }

    @Test func zip64AndSplitArchivesAreRefused() {
        var zip64 = TestZip.make([TestZip.file("a.js")])
        let eocd = zip64.count - 22
        zip64[eocd + 8] = 0xFF; zip64[eocd + 9] = 0xFF; zip64[eocd + 10] = 0xFF; zip64[eocd + 11] = 0xFF
        #expect(refusal(zip64) == .zip64)
        var split = TestZip.make([TestZip.file("a.js")])
        split[eocd + 4] = 1
        #expect(refusal(split) == .multiDisk)
    }

    @Test func localHeaderMustAgree() {
        guard case .damaged? = refusal([Item(name: "good.js", localName: "../bad.js")]) else {
            Issue.record("expected damaged")
            return
        }
    }

    @Test func folderWithContentsIsRefused() {
        guard case .damaged? = refusal([Item(name: "dir/", data: Data("x".utf8))]) else {
            Issue.record("expected damaged")
            return
        }
    }

    @Test func trailingCommentIsAllowed() throws {
        var zip = TestZip.make([TestZip.file("a.js")])
        let comment = Data("hello".utf8)
        zip[zip.count - 2] = UInt8(comment.count)
        zip += comment
        #expect(try ZipSafety.entries(in: zip).map(\.name) == ["a.js"])
    }

    // MARK: - Unpacked tree

    private func makeTree(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "paddle-zip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The CRC-32 of `text`, as the archive's central directory would carry it.
    private func crc32(_ text: String) -> UInt32 {
        Data(text.utf8).withUnsafeBytes { raw in
            UInt32(truncatingIfNeeded: zlib.crc32(0, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(raw.count)))
        }
    }

    @Test func unpackedTreeMustMatch() throws {
        let entries = [
            ZipSafety.Entry(name: "manifest.json", isDirectory: false, uncompressedSize: 2, crc32: crc32("{}")),
            ZipSafety.Entry(name: "js/bg.js", isDirectory: false, uncompressedSize: 4, crc32: crc32("1234")),
            ZipSafety.Entry(name: "empty", isDirectory: true, uncompressedSize: 0, crc32: 0),
            ZipSafety.Entry(name: "__MACOSX/._manifest.json", isDirectory: false, uncompressedSize: 4, crc32: crc32("abcd")),
        ]
        let root = try makeTree { root in
            try write(root, "manifest.json", "{}")
            try write(root, "js/bg.js", "1234")
            try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try ZipSafety.verifyUnpacked(root, matches: entries)

        try write(root, "extra.js", "x")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("extra.js")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
        try FileManager.default.removeItem(at: root.appending(path: "extra.js"))

        try write(root, "js/bg.js", "12345")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("js/bg.js")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
        try write(root, "js/bg.js", "1234")

        // Same size, different bytes: only the CRC tells this corruption from the real file.
        try write(root, "js/bg.js", "5678")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("js/bg.js")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
        try write(root, "js/bg.js", "1234")

        try FileManager.default.removeItem(at: root.appending(path: "manifest.json"))
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("manifest.json")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
        try write(root, "manifest.json", "{}")

        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "/etc")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("link")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
        try FileManager.default.removeItem(at: root.appending(path: "link"))

        // A link standing in for a listed file is refused too.
        try FileManager.default.removeItem(at: root.appending(path: "manifest.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "manifest.json").path, withDestinationPath: "/etc/hosts")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("manifest.json")) { try ZipSafety.verifyUnpacked(root, matches: entries) }
    }

    @Test func unpackedRootMustBeAFolder() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "paddle-zip-missing-\(UUID().uuidString)")
        #expect(throws: ZipSafety.Refusal.unpackedMismatch("the folder itself")) { try ZipSafety.verifyUnpacked(missing, matches: []) }
    }

    @Test func refusalsReadPlainly() {
        #expect(ZipSafety.Refusal.unsafeName("../x").localizedDescription == "unsafe file name: ../x")
        #expect(ZipSafety.Refusal.notZip.localizedDescription == "not a ZIP archive")
    }
}
