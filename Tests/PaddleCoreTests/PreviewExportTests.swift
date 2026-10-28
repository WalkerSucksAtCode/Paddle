import Foundation
@testable import PaddleCore
import Testing

struct PreviewExportTests {
    @Test func onlyHTTPAndHTTPSPagesAreFetched() {
        #expect(PreviewExport.canFetch(URL(string: "https://example.com/a.pdf")!))
        #expect(PreviewExport.canFetch(URL(string: "HTTP://example.com/")!))
        #expect(!PreviewExport.canFetch(URL(string: "file:///tmp/a.pdf")!))
        #expect(!PreviewExport.canFetch(URL(string: "data:application/pdf;base64,AAAA")!))
        #expect(!PreviewExport.canFetch(URL(string: "ftp://example.com/a.pdf")!))
    }

    @Test func sizeCapIs512MB() {
        #expect(PreviewExport.maxBytes == 512 * 1024 * 1024)
        #expect(PreviewExport.isWithinSizeLimit(PreviewExport.maxBytes))
        #expect(!PreviewExport.isWithinSizeLimit(PreviewExport.maxBytes + 1))
        #expect(!PreviewExport.isWithinSizeLimit(-1))
    }

    @Test func onlyFilesStartingWithPDFAreAccepted() {
        #expect(PreviewExport.isPDF(Data("%PDF-1.7\n".utf8)))
        #expect(!PreviewExport.isPDF(Data("<html>".utf8)))
        #expect(!PreviewExport.isPDF(Data("%PD".utf8)))
        #expect(PreviewExport.isAcceptable(Data("%PDF-1.4".utf8)))
        #expect(!PreviewExport.isAcceptable(Data("<script>".utf8)))
    }

    @Test func foldersOlderThanADayAreStale() {
        let now = Date()
        #expect(PreviewExport.isStale(created: now.addingTimeInterval(-86_401), now: now))
        #expect(!PreviewExport.isStale(created: now.addingTimeInterval(-86_399), now: now))
    }

    @Test func exportFoldersAreOwnerOnlyAndStaleOnesAreRemoved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Paddle Preview", isDirectory: true)
        let fresh = try PreviewExport.makeFolder(in: root)
        let stale = try PreviewExport.makeFolder(in: root)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: stale.path)

        let perms = try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700)
        PreviewExport.removeStaleFolders(in: root)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}
