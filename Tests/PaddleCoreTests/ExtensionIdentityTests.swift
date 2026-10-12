import Foundation
@testable import PaddleCore
import Testing

struct ExtensionIdentityTests {
    private func isLowerHex32(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    @Test func stableForSameNameAndSalt() {
        #expect(ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s") == ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s"))
    }

    @Test func differsAcrossSaltsAndNames() {
        let base = ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s1")
        #expect(base != ExtensionIdentity.identifier(forFolder: "ubolite", salt: "s2"))
        #expect(base != ExtensionIdentity.identifier(forFolder: "bitwarden", salt: "s1"))
    }

    @Test func identifierIs32LowercaseHex() {
        #expect(isLowerHex32(ExtensionIdentity.identifier(forFolder: "Ünïcode folder", salt: "salt")))
    }

    @Test func saltIs32LowercaseHexAndRandom() {
        let a = ExtensionIdentity.makeSalt(), b = ExtensionIdentity.makeSalt()
        #expect(isLowerHex32(a) && isLowerHex32(b))
        #expect(a != b)
    }

    @Test func baseURLHasSchemeAndHost() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        let url = ExtensionIdentity.baseURL(for: id)
        #expect(url.scheme == "webkit-extension")
        #expect(url.host == id)
        #expect(url.absoluteString == "webkit-extension://\(id)/")
    }

    @Test func identifierOfURLRoundTripsAndRejectsOthers() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        #expect(ExtensionIdentity.identifier(of: ExtensionIdentity.baseURL(for: id)) == id)
        #expect(ExtensionIdentity.identifier(of: URL(string: "webkit-extension://\(id)/options.html?a=1")) == id)
        #expect(ExtensionIdentity.identifier(of: URL(string: "https://example.com/")) == nil)
        #expect(ExtensionIdentity.identifier(of: URL(string: "http://\(id)/")) == nil)
        #expect(ExtensionIdentity.identifier(of: nil) == nil)
    }

    @Test func extensionsMayOpenWebPagesBlankAndTheirOwnPagesOnly() {
        let id = ExtensionIdentity.identifier(forFolder: "x", salt: "s")
        let other = ExtensionIdentity.identifier(forFolder: "y", salt: "s")
        func may(_ string: String, _ from: String? = id) -> Bool {
            ExtensionIdentity.extensionMayOpen(URL(string: string)!, extensionID: from)
        }
        #expect(may("https://example.com/"))
        #expect(may("HTTP://example.com/"))
        #expect(may("about:blank"))
        #expect(may("webkit-extension://\(id)/options.html"))
        #expect(!may("webkit-extension://\(other)/options.html"))
        #expect(!may("webkit-extension://\(id)/options.html", nil))
        #expect(!may("file:///Users/Walker/Library/Application%20Support/Paddle/session.json"))
        #expect(!may("about:config"))
        #expect(!may("data:text/html,hi"))
        #expect(!may("javascript:alert(1)"))
        #expect(!may("x-apple.systempreferences:"))
    }
}
