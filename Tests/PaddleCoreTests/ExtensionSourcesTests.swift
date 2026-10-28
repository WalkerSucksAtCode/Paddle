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

    @Test func recordsWhetherTheCertificateChainWasVerified() throws {
        var sources = ExtensionSources()
        sources.recordInstall(
            folder: "ublock", store: .mozillaAddons, id: "uBlock0@raymondhill.net", version: "1", fileHashes: [:],
            verified: false, now: .now
        )
        let text = String(decoding: try sources.encoded(), as: UTF8.self)
        #expect(text.contains(#""verified" : false"#))
        #expect(try ExtensionSources.decode(try sources.encoded()).records["ublock"]?.verified == false)
        let legacy = try ExtensionSources.decode(Data(#"{"sponsorblock": {"store": "chromeWebStore", "id": "\#(id)"}}"#.utf8))
        #expect(legacy.records["sponsorblock"]?.verified == nil)
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

    @Test func findsAnAddonBySlugOrGuid() {
        var sources = ExtensionSources()
        sources.recordInstall(
            folder: "ublock", store: .mozillaAddons, id: "uBlock0@raymondhill.net", version: "1", fileHashes: [:],
            slug: "ublock-origin", now: .now
        )
        sources.recordInstall(folder: "old", store: .mozillaAddons, id: "old@example.com", version: "1", fileHashes: [:], now: .now)
        #expect(sources.folder(forStoreID: "ublock-origin", store: .mozillaAddons) == "ublock")
        #expect(sources.folder(forStoreID: "UBLOCK-origin", store: .mozillaAddons) == "ublock")
        #expect(sources.folder(forStoreID: "uBlock0@raymondhill.net", store: .mozillaAddons) == "ublock")
        #expect(sources.folder(forStoreID: "ublock-origin", store: .chromeWebStore) == nil)
        #expect(sources.folder(forStoreID: "other-slug", store: .mozillaAddons) == nil)
        #expect(sources.folder(forStoreID: "old@example.com", store: .mozillaAddons) == "old")
        #expect(sources.folder(forStoreID: "old", store: .mozillaAddons) == nil)
    }

    @Test func recordsTheSlugOfAnAddon() throws {
        var sources = ExtensionSources()
        sources.recordInstall(
            folder: "ublock", store: .mozillaAddons, id: "uBlock0@raymondhill.net", version: "1", fileHashes: [:],
            slug: "ublock-origin", now: .now
        )
        let text = String(decoding: try sources.encoded(), as: UTF8.self)
        #expect(text.contains(#""slug" : "ublock-origin""#))
        #expect(try ExtensionSources.decode(try sources.encoded()) == sources)
        let legacy = try ExtensionSources.decode(Data(#"{"ublock": {"store": "mozillaAddons", "id": "uBlock0@raymondhill.net"}}"#.utf8))
        #expect(legacy.records["ublock"]?.slug == nil)
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

struct ExtensionSourcesDeclinedVersionTests {
    @Test func aDeclinedVersionRoundTripsAndOlderFilesReadAsNone() throws {
        var sources = ExtensionSources()
        sources.records["sample"] = ExtensionSources.Record(
            store: .chromeWebStore, id: "mnjggcdmjocbbbhaepdhchncahnbgone", version: "1.0", declinedVersion: "2.0"
        )
        let back = try ExtensionSources.decode(try sources.encoded())
        #expect(back.records["sample"]?.declinedVersion == "2.0")
        let older = Data(#"{"sample":{"store":"chromeWebStore","id":"mnjggcdmjocbbbhaepdhchncahnbgone","version":"1.0","fileHashes":{}}}"#.utf8)
        #expect(try ExtensionSources.decode(older).records["sample"]?.declinedVersion == nil)
    }

    @Test func adoptionFieldsRoundTripAndOldFilesDecode() throws {
        var sources = ExtensionSources()
        sources.adopt(folder: "protonpass", guid: "{abc}", slug: "proton-pass", version: "1.2", fileHashes: ["manifest.json": "aa"], now: Date(timeIntervalSince1970: 1_791_000_000.5))
        sources.declineAdoption(folder: "other")
        let back = try ExtensionSources.decode(try sources.encoded())
        #expect(back == sources)
        #expect(back.declinedAdoption == ["other"])
        let record = try #require(back.records["protonpass"])
        #expect(record.adopted == true && record.store == .mozillaAddons && record.id == "{abc}" && record.slug == "proton-pass")
        #expect(record.version == "1.2" && record.verified == nil && record.lastCheck == nil && record.fileHashes == ["manifest.json": "aa"])
        let old = try ExtensionSources.decode(Data(#"{"a":{"store":"mozillaAddons","id":"x@y"}}"#.utf8))
        #expect(old.declinedAdoption == nil && old.records["a"]?.adopted == nil)
        let text = String(decoding: try old.encoded(), as: UTF8.self)
        #expect(!text.contains("declinedAdoption") && !text.contains("adopted"))
    }

    @Test func declineAndStopAreIdempotentAndAdoptClearsTheDecline() throws {
        var sources = ExtensionSources()
        sources.declineAdoption(folder: "x")
        sources.declineAdoption(folder: "x")
        #expect(sources.declinedAdoption == ["x"] && sources.hasDeclinedAdoption("x"))
        sources.adopt(folder: "x", guid: "g@h", slug: nil, version: nil, fileHashes: [:], now: .now)
        #expect(sources.declinedAdoption == nil && !sources.hasDeclinedAdoption("x"))
        let stopped = sources.stopAdopted(folder: "x")
        #expect(stopped)
        #expect(sources.records["x"] == nil && sources.hasDeclinedAdoption("x"))
        sources.records["s"] = .init(store: .mozillaAddons, id: "s@t")
        let stoppedStore = sources.stopAdopted(folder: "s")
        #expect(!stoppedStore && sources.records["s"] != nil)
    }
}
