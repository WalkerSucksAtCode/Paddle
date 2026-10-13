import Foundation
@testable import PaddleCore
import Testing

struct ChromeUpdateCheckTests {
    let id = "mnjggcdmjocbbbhaepdhchncahnbgone"

    /// A gupdate answer with `body` as the `app` element's content.
    func answer(app: String) -> Data {
        Data(#"<?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod"><daystart elapsed_seconds="12345"/>\#(app)</gupdate>"#.utf8)
    }

    func app(_ check: String, appid: String? = nil, status: String = "ok") -> String {
        "<app appid=\"\(appid ?? id)\" status=\"\(status)\">\(check)</app>"
    }

    @Test func noUpdateIsReadWithGoogleDaystartPresent() throws {
        let data = answer(app: app(#"<updatecheck status="noupdate"/>"#))
        #expect(try ChromeUpdateCheck.parse(data, id: id) == .noUpdate)
    }

    @Test func aNewerVersionIsRead() throws {
        let check = #"<updatecheck status="ok" version="5.9.2" codebase="https://clients2.google.com/service/update2/crx/x.crx"/>"#
        #expect(try ChromeUpdateCheck.parse(answer(app: app(check)), id: id) == .update(version: "5.9.2"))
    }

    @Test func anAnswerForAnotherExtensionIsRefused() {
        let other = "abcdefghijklmnopabcdefghijklmnop"
        let check = #"<updatecheck status="ok" version="9.0"/>"#
        #expect(throws: ChromeUpdateCheck.Failure.otherApp) { try ChromeUpdateCheck.parse(answer(app: app(check, appid: other)), id: id) }
        // Ids compare exactly: an upper-case echo is not the id Paddle asked for.
        let upper = app(check, appid: id.uppercased())
        #expect(throws: ChromeUpdateCheck.Failure.otherApp) { try ChromeUpdateCheck.parse(answer(app: upper), id: id) }
        #expect(throws: ChromeUpdateCheck.Failure.otherApp) {
            try ChromeUpdateCheck.parse(answer(app: #"<app status="ok"><updatecheck status="ok" version="9.0"/></app>"#), id: id)
        }
    }

    @Test func anAppStatusOtherThanOkIsRefused() {
        let failure = ChromeUpdateCheck.Failure.refused("error-unknownApplication")
        #expect(throws: failure) { try ChromeUpdateCheck.parse(answer(app: app("", status: "error-unknownApplication")), id: id) }
        let check = #"<updatecheck status="noupdate"/>"#
        #expect(throws: ChromeUpdateCheck.Failure.refused("restricted")) {
            try ChromeUpdateCheck.parse(answer(app: app(check, status: "restricted")), id: id)
        }
    }

    @Test func anUpdateCheckStatusOtherThanOkOrNoupdateIsRefused() {
        let check = #"<updatecheck status="error-osnotsupported"/>"#
        #expect(throws: ChromeUpdateCheck.Failure.refused("error-osnotsupported")) {
            try ChromeUpdateCheck.parse(answer(app: app(check)), id: id)
        }
    }

    @Test func anOkAnswerNeedsAChromeVersion() {
        let none = #"<updatecheck status="ok" codebase="https://clients2.google.com/x.crx"/>"#
        #expect(throws: ChromeUpdateCheck.Failure.noVersion) { try ChromeUpdateCheck.parse(answer(app: app(none)), id: id) }
        for version in ["5.9.x", "", "5.9.2.1.1", "5.9b2"] {
            let check = #"<updatecheck status="ok" version="\#(version)"/>"#
            #expect(throws: ChromeUpdateCheck.Failure.noVersion) { try ChromeUpdateCheck.parse(answer(app: app(check)), id: id) }
        }
    }

    @Test func theShapeIsChecked() {
        let check = #"<updatecheck status="noupdate"/>"#
        // Not XML.
        #expect(throws: ChromeUpdateCheck.Failure.malformed) { try ChromeUpdateCheck.parse(Data("<gupdate><app".utf8), id: id) }
        // Another root.
        #expect(throws: ChromeUpdateCheck.Failure.malformed) {
            try ChromeUpdateCheck.parse(Data("<html>\(app(check))</html>".utf8), id: id)
        }
        // No app, or two.
        #expect(throws: ChromeUpdateCheck.Failure.malformed) { try ChromeUpdateCheck.parse(Data("<gupdate/>".utf8), id: id) }
        #expect(throws: ChromeUpdateCheck.Failure.malformed) { try ChromeUpdateCheck.parse(answer(app: app(check) + app(check)), id: id) }
        // An updatecheck outside the app, or none inside it, or two.
        #expect(throws: ChromeUpdateCheck.Failure.malformed) {
            try ChromeUpdateCheck.parse(Data(#"<gupdate><updatecheck status="noupdate"/></gupdate>"#.utf8), id: id)
        }
        #expect(throws: ChromeUpdateCheck.Failure.malformed) { try ChromeUpdateCheck.parse(answer(app: app("")), id: id) }
        #expect(throws: ChromeUpdateCheck.Failure.malformed) { try ChromeUpdateCheck.parse(answer(app: app(check + check)), id: id) }
    }

    @Test func checkAddressCarriesIdAndInstalledVersion() throws {
        let url = try #require(ChromeUpdateCheck.url(id: id.uppercased(), installedVersion: "5.9.1"))
        let text = url.absoluteString
        #expect(text.hasPrefix("https://clients2.google.com/service/update2/crx?response=updatecheck&acceptformat=crx3&prodversion="))
        #expect(text.contains("&prodversion=\(BrowserVersions.current.chromeFullVersion)&"))
        #expect(text.hasSuffix("&x=id%3D\(id)%26v%3D5.9.1%26uc"))
    }

    @Test func checkAddressRefusesBadInput() {
        #expect(ChromeUpdateCheck.url(id: "not-an-id", installedVersion: "5.9.1") == nil)
        #expect(ChromeUpdateCheck.url(id: id, installedVersion: "5.9.x") == nil)
        #expect(ChromeUpdateCheck.url(id: id, installedVersion: "") == nil)
        let odd = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0 beta", firefoxVersion: "157.0")
        #expect(ChromeUpdateCheck.url(id: id, installedVersion: "5.9.1", versions: odd) == nil)
    }
}
