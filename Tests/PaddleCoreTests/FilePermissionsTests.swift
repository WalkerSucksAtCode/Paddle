import Foundation
@testable import PaddleCore
import Testing

struct FilePermissionsTests {
    func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func pureRules() {
        #expect(FilePermissions.isTooOpen(0o644))
        #expect(FilePermissions.isTooOpen(0o750))
        #expect(!FilePermissions.isTooOpen(0o600))
        #expect(FilePermissions.tightened(0o644, directory: false) == 0o600)
        #expect(FilePermissions.tightened(0o755, directory: true) == 0o700)
    }

    @Test func tightensFilesAndFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "perm-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let file = root.appending(path: "history.sqlite")
        let wal = root.appending(path: "history.sqlite-wal")
        try Data("x".utf8).write(to: file)
        try Data("x".utf8).write(to: wal)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wal.path)

        #expect(FilePermissions.restrict(root, directory: true))
        #expect(mode(root) == 0o700)
        FilePermissions.restrictDatabase(file)
        #expect(mode(file) == 0o600)
        #expect(mode(wal) == 0o600)
        #expect(!FilePermissions.restrict(file, directory: false))
        #expect(!FilePermissions.restrict(root.appending(path: "missing"), directory: false))
    }

    @Test func createsPrivateFolders() {
        let root = FileManager.default.temporaryDirectory.appending(path: "perm-\(UUID().uuidString)/a/b", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        FilePermissions.createPrivateFolder(root)
        #expect(mode(root) == 0o700)
    }
}
