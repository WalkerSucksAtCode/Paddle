import Foundation
@testable import PaddleCore
import Testing

struct ExtensionSourcesTests {
    private let id = "mnjggcdmjocbbbhaepdhchncahnbgone"

    @Test func roundTrips() throws {
        var sources = ExtensionSources()
        sources.recordInstall(
            folder: "sponsorblock", store: .chromeWebStore, id: id, version: "5.9.1",
            fileHashes: ["manifest.json": String(repeating: "a", count: 64)], now: Date(timeIntervalSince1970: 1_791_000_000.7)
        )
        sources.records["ublock"] = .init(store: .mozillaAddons, id: "uBlock0@raymondhill.net", version: "1.60.0")
        let decoded = try ExtensionSources.decode(try sources.encoded())
        #expect(decoded == sources)
        #expect(decoded.records["sponsorblock"]?.installedAt == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(decoded.records["sponsorblock"]?.lastCheck == Date(timeIntervalSince1970: 1_791_000_000))
        let text = String(decoding: try sources.encoded(), as: UTF8.self)
        #expect(text.contains(#""store" : "chromeWebStore""#))
        #expect(text.contains(#""installedAt" : "2026-10-03T"#))
    }

    @Test func missingOptionalFieldsDecode() throws {
        let json = #"{"sponsorblock": {"store": "chromeWebStore", "id": "\#(id)"}, "x": {"store": "mozillaAddons", "id": "x@y", "version": "1", "installedAt": "2026-10-12T09:00:00Z"}}"#
        let sources = try ExtensionSources.decode(Data(json.utf8))
        let record = try #require(sources.records["sponsorblock"])
        #expect(record.store == .chromeWebStore && record.id == id)
        #expect(record.version == nil && record.installedAt == nil && record.lastCheck == nil && record.fileHashes.isEmpty)
        #expect(sources.records["x"]?.installedAt != nil)
        #expect(throws: (any Error).self) { try ExtensionSources.decode(Data(#"{"a": {"id": "x"}}"#.utf8)) }
        #expect(throws: (any Error).self) { try ExtensionSources.decode(Data(#"{"a": {"store": "elsewhere", "id": "x"}}"#.utf8)) }
        #expect(try ExtensionSources.decode(Data("{}".utf8)).records.isEmpty)
    }

    @Test func findsTheFolderForAStoreID() {
        var sources = ExtensionSources()
        sources.recordInstall(folder: "sponsorblock", store: .chromeWebStore, id: id, version: "1", fileHashes: [:], now: .now)
        sources.recordInstall(folder: "ublock", store: .mozillaAddons, id: "uBlock0@raymondhill.net", version: "1", fileHashes: [:], now: .now)
        #expect(sources.folder(forStoreID: id, store: .chromeWebStore) == "sponsorblock")
        #expect(sources.folder(forStoreID: id.uppercased(), store: .chromeWebStore) == "sponsorblock")
        #expect(sources.folder(forStoreID: id, store: .mozillaAddons) == nil)
        #expect(sources.folder(forStoreID: "uBlock0@raymondhill.net", store: .mozillaAddons) == "ublock")
        #expect(sources.folder(forStoreID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", store: .chromeWebStore) == nil)
    }

    @Test(arguments: [
        ("SponsorBlock for YouTube - Skip Sponsorships", "sponsorblock-for-youtube-skip-sponsorshi"),
        ("uBlock Origin Lite", "ublock-origin-lite"),
        ("Ünïcode Tööls", "unicode-tools"),
        ("  ..hidden  ", "hidden"),
        ("../../etc", "etc"),
        ("___", "extension"),
        ("", "extension"),
        ("日本語", "extension"),
        ("Dark Reader 4.9", "dark-reader-4-9"),
        ("a" + String(repeating: "b", count: 50), "a" + String(repeating: "b", count: 39)),
    ])
    func folderNamesAreSafe(display: String, expected: String) {
        let name = ExtensionSources.folderName(forDisplayName: display, existing: [])
        #expect(name == expected)
        #expect(!name.isEmpty && name.count <= 40 && !name.hasPrefix(".") && !name.hasPrefix("-") && !name.hasSuffix("-"))
        #expect(name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
    }

    @Test func folderNamesAvoidCollisions() {
        #expect(ExtensionSources.folderName(forDisplayName: "Dark Reader", existing: ["dark-reader"]) == "dark-reader-2")
        #expect(ExtensionSources.folderName(forDisplayName: "Dark Reader", existing: ["Dark-Reader", "dark-reader-2"]) == "dark-reader-3")
        #expect(ExtensionSources.folderName(forDisplayName: "", existing: ["extension"]) == "extension-2")
        let long = String(repeating: "x", count: 40)
        let next = ExtensionSources.folderName(forDisplayName: long, existing: [long])
        #expect(next == String(repeating: "x", count: 38) + "-2")
        // Cut to fit the suffix, a trailing hyphen doesn't stay.
        let hyphen = String(repeating: "x", count: 37) + "-yy"
        #expect(ExtensionSources.folderName(forDisplayName: hyphen, existing: [hyphen]) == String(repeating: "x", count: 37) + "-2")
    }
}
