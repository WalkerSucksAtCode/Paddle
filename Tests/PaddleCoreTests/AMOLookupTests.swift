import CryptoKit
import Foundation
@testable import PaddleCore
import Testing

/// The addons.mozilla.org API answer, the download checks, slug and guid validation, and the manifest's gecko id.
/// Nothing here touches the network.
struct AMOLookupTests {
    private let guid = "uBlock0@raymondhill.net"
    private let digest = String(repeating: "ab", count: 32)

    /// A complete API answer for the sample add-on, as a dictionary a test can change before it is written as JSON.
    private func sample() -> [String: Any] {
        let file: [String: Any] = [
            "url": "https://addons.mozilla.org/firefox/downloads/file/1/ublock_origin-1.60.0.xpi",
            "hash": "sha256:\(digest)",
            "size": 42,
            "permissions": ["tabs"],
        ]
        let current: [String: Any] = ["version": "1.60.0", "file": file]
        return ["guid": guid, "slug": "ublock-origin", "name": "uBlock Origin", "current_version": current]
    }

    /// The sample answer as JSON, with `top`, `version` or `file` applied to its top level, its `current_version` or
    /// its `current_version.file` first.
    private func answer(
        top: (inout [String: Any]) -> Void = { _ in },
        version: (inout [String: Any]) -> Void = { _ in },
        file: (inout [String: Any]) -> Void = { _ in }
    ) -> Data {
        var document = sample()
        var current = document["current_version"] as? [String: Any] ?? [:]
        var fileObject = current["file"] as? [String: Any] ?? [:]
        file(&fileObject)
        current["file"] = fileObject
        version(&current)
        document["current_version"] = current
        top(&document)
        return (try? JSONSerialization.data(withJSONObject: document)) ?? Data()
    }

    /// The failure `body` throws, if it throws an `AMO.Failure`.
    private func refusal<T>(_ body: () throws -> T) -> AMO.Failure? {
        do {
            _ = try body()
            return nil
        } catch let failure as AMO.Failure {
            return failure
        } catch {
            return nil
        }
    }

    @Test func decodesTheSampleAnswer() throws {
        let addon = try AMO.decodeAddon(answer(), requested: "ublock-origin")
        #expect(addon.guid == guid)
        #expect(addon.name == "uBlock Origin")
        #expect(addon.version == "1.60.0")
        #expect(addon.fileURL.absoluteString == "https://addons.mozilla.org/firefox/downloads/file/1/ublock_origin-1.60.0.xpi")
        #expect(addon.sha256 == digest)
        #expect(addon.size == 42)
        #expect(try AMO.decodeAddon(answer(), requested: guid) == addon)
    }

    @Test func namesComeFromTheEnglishEntryOfALocaleMap() throws {
        let english = answer(top: { $0["name"] = ["de": "Werbeblocker", "en-US": "Ad Blocker"] })
        #expect(try AMO.decodeAddon(english, requested: "ublock-origin").name == "Ad Blocker")
        let noEnglish = answer(top: { $0["name"] = ["fr": "Bloqueur", "de": "Blocker"] })
        #expect(try AMO.decodeAddon(noEnglish, requested: "ublock-origin").name == "Blocker")
    }

    @Test func refusesAnAnswerThatIsNotStrictlyUsable() {
        let cases: [(Data, AMO.Failure)] = [
            (Data("<html>".utf8), .unreadable),
            (Data("[]".utf8), .unreadable),
            (answer(top: { $0["guid"] = nil }), .malformed("guid")),
            (answer(top: { $0["guid"] = "not an id" }), .malformed("guid")),
            (answer(top: { $0["name"] = nil }), .malformed("name")),
            (answer(top: { $0["name"] = " " }), .malformed("name")),
            (answer(top: { $0["name"] = ["en-US": 7] }), .malformed("name.en-US")),
            (answer(top: { $0["current_version"] = nil }), .noCurrentVersion),
            (answer(top: { $0["current_version"] = NSNull() }), .noCurrentVersion),
            (answer(version: { $0["version"] = nil }), .malformed("current_version.version")),
            (answer(version: { $0["version"] = "" }), .malformed("current_version.version")),
            (answer(version: { $0["file"] = nil }), .malformed("current_version.file")),
            (answer(file: { $0["url"] = nil }), .malformed("current_version.file.url")),
            (answer(file: { $0["url"] = "http://addons.mozilla.org/x.xpi" }), .fileNotAllowed),
            (answer(file: { $0["url"] = "https://example.com/x.xpi" }), .fileNotAllowed),
            (answer(file: { $0["url"] = "https://addons.mozilla.org.example.com/x.xpi" }), .fileNotAllowed),
            (answer(file: { $0["url"] = "/firefox/downloads/file/1/x.xpi" }), .fileNotAllowed),
            (answer(file: { $0["hash"] = nil }), .malformed("current_version.file.hash")),
            (answer(file: { $0["hash"] = "md5:\(digest)" }), .badHash),
            (answer(file: { $0["hash"] = "sha256:abc" }), .badHash),
            (answer(file: { $0["size"] = "42" }), .malformed("current_version.file.size")),
        ]
        for (index, (json, expected)) in cases.enumerated() {
            #expect(refusal { try AMO.decodeAddon(json, requested: "ublock-origin") } == expected, "case \(index)")
        }
        #expect(refusal { try AMO.decodeAddon(answer(), requested: "other@example.org") } == .otherAddon)
    }

    @Test func aDownloadMustMatchTheSizeAndHashTheAPIGave() throws {
        let file = Data("x".utf8)
        let url = try #require(URL(string: "https://addons.mozilla.org/firefox/downloads/file/1/x.xpi"))
        let addon = AMO.Addon(guid: guid, name: "x", version: "1", fileURL: url, sha256: AMO.digestHex(file), size: 1)
        try AMO.checkDownload(file, for: addon)
        #expect(refusal { try AMO.checkDownload(Data("xy".utf8), for: addon) } == .sizeMismatch)
        #expect(refusal { try AMO.checkDownload(Data("y".utf8), for: addon) } == .hashMismatch)
        let unsized = AMO.Addon(guid: guid, name: "x", version: "1", fileURL: url, sha256: AMO.digestHex(file), size: nil)
        try AMO.checkDownload(file, for: unsized)
    }

    @Test func slugsAndGUIDsAreValidated() {
        for slug in ["ublock-origin", "dark_reader", "12345", "a", String(repeating: "a", count: 100)] {
            #expect(AMO.isSlug(slug), "\(slug)")
        }
        for slug in ["", "UBlock", "ublock origin", "ublock/origin", "..", ".", "ublöck", "a@b", "{abc}", "a.b",
                     String(repeating: "a", count: 101)] {
            #expect(!AMO.isSlug(slug), "\(slug)")
        }
        for id in ["uBlock0@raymondhill.net", "addon@example.org", "jid1-xyz_1@jetpack", "{4b547b2c-e114-4344-9b70-09b2fe0785f3}"] {
            #expect(AMO.isGUID(id), "\(id)")
        }
        for id in ["", "nobody", "@example.org", "name@", "a@b@c", "x@y z", "x@y/../z",
                   "{4b547b2c-e114-4344-9b70-09b2fe0785f}", "{4b547b2c_e114-4344-9b70-09b2fe0785f3}", "{not-a-uuid}",
                   "{4b547b2c-e114-4344-9b70-09b2fe0785f3"] {
            #expect(!AMO.isGUID(id), "\(id)")
        }
    }

    @Test func theAPIAddressIsBuiltOnlyFromAValidSlugOrGUID() {
        #expect(AMO.apiURL(storeID: "ublock-origin")?.absoluteString
            == "https://addons.mozilla.org/api/v5/addons/addon/ublock-origin/")
        #expect(AMO.apiURL(storeID: guid)?.absoluteString == "https://addons.mozilla.org/api/v5/addons/addon/uBlock0@raymondhill.net/")
        #expect(AMO.apiURL(storeID: "{4b547b2c-e114-4344-9b70-09b2fe0785f3}")?.absoluteString
            .contains("/addon/%7B4b547b2c-e114-4344-9b70-09b2fe0785f3%7D/") == true)
        for bad in ["", "../etc", "UBlock", "a?b=c", "ublock origin", "{nope}"] {
            #expect(AMO.apiURL(storeID: bad) == nil, "\(bad)")
        }
    }

    @Test func downloadsMayOnlyUseTheMozillaHostsOverHTTPS() {
        for allowed in ["https://addons.mozilla.org/firefox/downloads/file/1/x.xpi", "https://addons.cdn.mozilla.net/a/b.xpi?sig=1",
                        "https://addons.mozilla.org:443/x", "https://ADDONS.mozilla.org/x"] {
            #expect(AMO.isAllowedAMODownload(URL(string: allowed) ?? URL(fileURLWithPath: "/")), "\(allowed)")
        }
        for refused in ["http://addons.mozilla.org/x", "https://addons.mozilla.org:8443/x", "https://user@addons.mozilla.org/x",
                        "https://addons.mozilla.org.example.com/x", "https://evil.addons.mozilla.org/x", "https://mozilla.org/x",
                        "https://cdn.mozilla.net/x", "ftp://addons.mozilla.org/x", "/relative/x.xpi"] {
            #expect(!AMO.isAllowedAMODownload(URL(string: refused) ?? URL(fileURLWithPath: "/")), "\(refused)")
        }
    }

    @Test func theManifestMustNameTheGUIDAsItsGeckoID() {
        func gecko(_ id: String) -> [String: Any] { ["gecko": ["id": id]] }
        #expect(AMO.manifestNamesGUID(["browser_specific_settings": gecko(guid)], guid: guid))
        #expect(AMO.manifestNamesGUID(["applications": gecko(guid)], guid: guid))
        #expect(AMO.manifestNamesGUID(["browser_specific_settings": gecko(guid), "applications": gecko(guid)], guid: guid))
        #expect(!AMO.manifestNamesGUID(["browser_specific_settings": gecko("other@example.org")], guid: guid))
        #expect(!AMO.manifestNamesGUID(["browser_specific_settings": gecko(guid), "applications": gecko("other@example.org")],
                                       guid: guid))
        #expect(!AMO.manifestNamesGUID(["name": "no id"], guid: guid))
        #expect(!AMO.manifestNamesGUID(["browser_specific_settings": ["gecko": ["name": "x"]]], guid: guid))
        #expect(!AMO.manifestNamesGUID(["browser_specific_settings": ["gecko": "\(guid)"]], guid: guid))
    }

    @Test func pageNamesComeFromTheTitle() {
        #expect(AMO.pageName(title: "uBlock Origin – Get this Extension for 🦊 Firefox (en-US)") == "uBlock Origin")
        #expect(AMO.pageName(title: "Dark Reader — Add-ons for Firefox") == "Dark Reader")
        #expect(AMO.pageName(title: "Ad-Block - Get this Extension") == "Ad-Block")
        #expect(AMO.pageName(title: "Plain Name") == "Plain Name")
        #expect(AMO.pageName(title: " – Get this Extension") == nil)
        #expect(AMO.pageName(title: "") == nil)
    }

    @Test func theDigestParserAcceptsOnlySHA256WithSixtyFourHexDigits() {
        #expect(AMO.parseSHA256("sha256:" + String(repeating: "AB", count: 32)) == digest)
        #expect(AMO.parseSHA256("sha256:" + String(repeating: "ab", count: 31)) == nil)
        #expect(AMO.parseSHA256("SHA256:" + digest) == nil)
        #expect(AMO.parseSHA256("sha1:" + digest) == nil)
        #expect(AMO.parseSHA256(digest) == nil)
    }

    @Test func jarSectionsReadContinuationsAndRefuseBrokenLines() throws {
        let text = "Manifest-Version: 1.0\r\n\r\nName: long\r\n name\r\nSHA256-Digest: AAAA\r\n\r\nName: other\r\n\r\n"
        let sections = try #require(AMO.jarSections(Data(text.utf8)))
        #expect(sections.count == 5)
        #expect(sections[0] == ["manifest-version": "1.0"])
        #expect(sections[1] == ["name": "longname", "sha256-digest": "AAAA"])
        #expect(sections[2] == ["name": "other"])
        #expect(AMO.jarSections(Data("Name: a\r\nName: b\r\n".utf8)) == nil)
        #expect(AMO.jarSections(Data("no separator here\r\n".utf8)) == nil)
        #expect(AMO.jarSections(Data(" continuation first\r\n".utf8)) == nil)
        #expect(AMO.jarSections(Data("Bad Name: x\r\n".utf8)) == nil)
        #expect(AMO.jarSections(Data([0xFF, 0xFE, 0x00])) == nil)
    }
}
