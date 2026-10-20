import Foundation
@testable import PaddleCore
import Testing

struct FilterListTextTests {
    func ok(_ text: String) -> Bool { FilterListText.mayReplaceStoredList(Data(text.utf8)) }

    @Test func normalListIsAccepted() {
        #expect(ok("[Adblock Plus 2.0]\n! Title: x\n||ads.example^\n"))
        #expect(ok("! Title: x\n\n##.banner\n"))
    }

    @Test func commentOnlyAndHeaderOnlyAreRefused() {
        #expect(!ok("! Title: x\n! more\n\n"))
        #expect(!ok("[Adblock Plus 2.0]\n"))
        #expect(!ok("[Adblock Plus 2.0]\n! c\n   \n"))
    }

    @Test func wrongStartIsRefused() {
        #expect(!ok("<html>||ads.example^</html>"))
        #expect(!ok("||ads.example^\n"))
    }

    @Test func invalidUTF8IsRefused() {
        #expect(!FilterListText.mayReplaceStoredList(Data([0x21, 0x0A, 0xE9, 0x0A, 0x41])))
    }

    @Test func oversizeIsRefused() {
        var data = Data("! x\n||a^\n".utf8)
        data.append(Data(repeating: 0x61, count: FilterListText.maxBytes))
        #expect(!FilterListText.mayReplaceStoredList(data))
    }

    @Test func decodesUTF8WithAndWithoutBOM() {
        #expect(FilterListText.decode(Data("@@||ex.com^ é".utf8)) == "@@||ex.com^ é")
        #expect(FilterListText.decode(Data([0xEF, 0xBB, 0xBF] + Array("@@||a^".utf8))) == "@@||a^")
    }

    @Test func decodesUTF16WithBOM() {
        let le = Data([0xFF, 0xFE]) + "@@||a^".data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + "@@||a^".data(using: .utf16BigEndian)!
        #expect(FilterListText.decode(le) == "@@||a^")
        #expect(FilterListText.decode(be) == "@@||a^")
    }

    @Test func decodesLatin1() {
        #expect(FilterListText.decode(Data([0x21, 0x20, 0xE9])) == "! é")
    }
}
