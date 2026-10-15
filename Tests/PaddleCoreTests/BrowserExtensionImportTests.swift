import Foundation
@testable import PaddleCore
import Testing

struct BrowserExtensionImportTests {
    private static let storeID = String(repeating: "a", count: 32)
    private static let edgeID = String(repeating: "b", count: 32)
    private static let msgID = String(repeating: "c", count: 32)

    private func source(_ browser: ImportSource.Browser, _ dir: URL) -> ImportSource {
        ImportSource(
            browser: browser, profileName: "Default", directory: dir, historyFile: dir.appending(path: "History"),
            settingsFile: dir.appending(path: "Preferences"), hasHistory: true, hasSettings: true, hasExtensions: true)
    }

    private func chromium(_ browser: ImportSource.Browser = .chrome, file: String = "Secure Preferences") throws -> (ImportFixture, ImportSource) {
        let f = try ImportFixture()
        let a = Self.storeID, b = Self.edgeID, c = Self.msgID
        let json = """
        {"extensions":{"settings":{
          "\(a)":{"location":1,"from_webstore":true,"state":1,"manifest":{"name":"zeta Store","update_url":"https://clients2.google.com/service/update2/crx"}},
          "\(b)":{"location":1,"state":1,"manifest":{"name":"Edge Thing","update_url":"https://edge.microsoft.com/extensionwebstorebase/v1/crx"}},
          "\(c)":{"location":1,"from_webstore":true,"disable_reasons":[1],"manifest":{"name":"__MSG_Ext_Name__","default_locale":"en"}},
          "dddddddddddddddddddddddddddddddd":{"location":4,"state":1,"manifest":{"name":"Alpha Unpacked"}},
          "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee":{"location":5,"manifest":{"name":"Component"}},
          "ffffffffffffffffffffffffffffffff":{"location":1,"manifest":{"name":"A Theme","theme":{}}},
          "gggggggggggggggggggggggggggggggg":{"location":1,"state":1},
          "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq":{"location":1,"state":0,"from_webstore":true,"manifest":{"name":"Off"}}
        }}}
        """
        let profile = "Library/Application Support/Google/Chrome/Default"
        _ = try f.write(json, to: "\(profile)/\(file)")
        _ = try f.write("{\"ext_name\":{\"message\":\"Localized Name\"}}", to: "\(profile)/Extensions/\(c)/1.0_0/_locales/en/messages.json")
        _ = try f.write("{\"EXT_NAME\":{\"message\":\"Newest Name\"}}", to: "\(profile)/Extensions/\(c)/2.0_0/_locales/en/messages.json")
        return (f, source(browser, f.home.appending(path: profile, directoryHint: .isDirectory)))
    }

    @Test func chromiumListsStoreUnpackedAndLocalizedSorted() throws {
        let (f, src) = try chromium()
        _ = f
        let list = try BrowserExtensionReader.read(src)
        #expect(list.map(\.name) == ["Alpha Unpacked", "Edge Thing", "Newest Name", "Off", "zeta Store"])
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        #expect(byName["zeta Store"]?.link == .chromeWebStore(id: Self.storeID))
        #expect(byName["zeta Store"]?.notInstallable == nil)
        #expect(byName["Alpha Unpacked"]?.link == nil)
        #expect(byName["Alpha Unpacked"]?.notInstallable == "Added by hand, not from a store")
        #expect(byName["Edge Thing"]?.notInstallable == "From Microsoft Edge Add-ons")
        // "Off" has a store flag but an id that isn't 32 letters a-p: no link.
        #expect(byName["Off"]?.link == nil)
    }

    @Test func chromiumEnabledFlags() throws {
        let (f, src) = try chromium()
        _ = f
        let byName = Dictionary(uniqueKeysWithValues: try BrowserExtensionReader.read(src).map { ($0.name, $0) })
        #expect(byName["zeta Store"]?.enabled == true)
        #expect(byName["Newest Name"]?.enabled == false)  // disable_reasons set
        #expect(byName["Off"]?.enabled == false)  // state 0
    }

    @Test func chromiumFallsBackToPreferencesAndSkipsStoreLinkOnEdge() throws {
        let (f, src) = try chromium(.edge, file: "Preferences")
        _ = f
        let byName = Dictionary(uniqueKeysWithValues: try BrowserExtensionReader.read(src).map { ($0.name, $0) })
        // Edge: from_webstore alone doesn't mean the Chrome Web Store.
        #expect(byName["Newest Name"]?.link == nil)
        #expect(byName["zeta Store"]?.link == .chromeWebStore(id: Self.storeID))
    }

    @Test func missingMessageFallsBackToID() throws {
        let f = try ImportFixture()
        let id = Self.msgID
        _ = try f.write("{\"extensions\":{\"settings\":{\"\(id)\":{\"location\":1,\"manifest\":{\"name\":\"__MSG_nope__\"}}}}}", to: "p/Secure Preferences")
        let list = try BrowserExtensionReader.read(source(.brave, f.home.appending(path: "p", directoryHint: .isDirectory)))
        #expect(list.map(\.name) == [id])
    }

    @Test func firefoxKeepsOnlyProfileExtensions() throws {
        let f = try ImportFixture()
        let json = """
        {"addons":[
          {"id":"ublock@x.net","location":"app-profile","type":"extension","active":true,"defaultLocale":{"name":"uBlock"},"sourceURI":"https://addons.mozilla.org/firefox/downloads/file/1/u.xpi"},
          {"id":"cdn@x.net","location":"app-profile","type":"extension","active":false,"defaultLocale":{"name":"cdn thing"},"sourceURI":"https://addons.cdn.mozilla.net/user-media/a.xpi"},
          {"id":"hand@x.net","location":"app-profile","type":"extension","active":true,"defaultLocale":{"name":"Sideloaded"},"sourceURI":"https://example.com/a.xpi"},
          {"id":"nouri@x.net","location":"app-profile","type":"extension","active":true},
          {"id":"theme@x.net","location":"app-profile","type":"theme","active":true,"defaultLocale":{"name":"Theme"}},
          {"id":"builtin@x.net","location":"app-builtin","type":"extension","active":true,"defaultLocale":{"name":"Builtin"}},
          {"id":"system@x.net","location":"app-system-defaults","type":"extension","active":true,"defaultLocale":{"name":"System"}}
        ]}
        """
        _ = try f.write(json, to: "ff/extensions.json")
        let list = try BrowserExtensionReader.read(source(.firefox, f.home.appending(path: "ff", directoryHint: .isDirectory)))
        #expect(list.map(\.name) == ["cdn thing", "nouri@x.net", "Sideloaded", "uBlock"])
        #expect(list[0].link == .mozillaAddons(slug: "cdn@x.net"))
        #expect(list[0].enabled == false)
        #expect(list[3].link == .mozillaAddons(slug: "ublock@x.net"))
        #expect(list[2].link == nil)
        #expect(list[2].notInstallable == "Added by hand, not from addons.mozilla.org")
        #expect(list[1].notInstallable != nil)
    }

    @Test func safariHasNone() throws {
        let f = try ImportFixture()
        #expect(try BrowserExtensionReader.read(source(.safari, f.home)).isEmpty)
    }

    @Test func missingFileThrowsMissing() throws {
        let f = try ImportFixture()
        #expect(throws: BrowserImportError.self) { try BrowserExtensionReader.read(source(.firefox, f.home)) }
    }
}
