import Testing
@testable import PaddleCore

struct DownloadFilenameTests {
    @Test func replacesSeparators() {
        #expect(DownloadFilename.sanitized("a/b:c.txt") == "a-b-c.txt")
        #expect(DownloadFilename.sanitized("../../x.sh") == "-..-x.sh")
    }

    @Test func stripsLeadingDotsAndSpaces() {
        #expect(DownloadFilename.sanitized("..  .bashrc") == "bashrc")
        #expect(DownloadFilename.sanitized("  a.txt ") == "a.txt")
    }

    @Test func stripsControlAndBidi() {
        #expect(DownloadFilename.sanitized("a\u{0}b\nc\u{202E}txt.exe") == "abctxt.exe")
        #expect(DownloadFilename.sanitized("x\u{2066}y\u{2069}.pdf") == "xy.pdf")
    }

    @Test func emptyFallsBack() {
        #expect(DownloadFilename.sanitized("") == "download")
        #expect(DownloadFilename.sanitized("...") == "download")
        #expect(DownloadFilename.sanitized("\u{202E}\n") == "download")
    }

    @Test func capsBytesKeepingExtension() {
        let long = String(repeating: "é", count: 300) + ".pdf"
        let out = DownloadFilename.sanitized(long)
        #expect(out.utf8.count <= 255)
        #expect(out.hasSuffix(".pdf"))
    }
}
