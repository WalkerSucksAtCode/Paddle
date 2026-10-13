import CryptoKit
import Foundation
@testable import PaddleCore
import Testing

struct StoreInstallTests {
    private let developer = TestRSAKey.developer
    private let publisher = TestRSAKey.publisher
    private var developerID: String { ExtensionIdentity.chromeID(publicKeyDER: developer.spki) }

    /// A fresh temporary folder; deleted by the caller's `defer`.
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "StoreInstallTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Signed package → verify → ZIP check → ditto → checks → swap in: the whole path a store download takes.
    @Test func signedPackageUnpacksAndSwapsIn() throws {
        let manifest = #"{"manifest_version":3,"name":"__MSG_appName__","default_locale":"en","version":"5.9.1"}"#
        let zip = TestZip.make([
            TestZip.file("manifest.json", manifest),
            TestZip.Item(name: "_locales/"),
            TestZip.Item(name: "_locales/en/"),
            TestZip.file("_locales/en/messages.json", #"{"APPNAME": {"message": "Sponsor Block!"}}"#),
            TestZip.Item(name: "bg.js", data: Data("1".utf8), mode: 0o104755),
        ])
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer), .rsa(publisher)])
        let verified = try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [Data(SHA256.hash(data: publisher.spki))])
        let entries = try ZipSafety.entries(in: verified.zip)

        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = root.appending(path: "extensions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        let staging = extensions.appending(path: ".installing-\(developerID)", directoryHint: .isDirectory)
        let package = try StoreInstall.unpack(
            zip: verified.zip, entries: entries, store: .chromeWebStore, id: developerID, into: staging,
            scratch: root.appending(path: "scratch")
        )

        #expect(package.id == developerID)
        #expect(package.displayName == "Sponsor Block!")
        #expect(package.version == "5.9.1")
        #expect(package.fileHashes["manifest.json"] == hex(manifest))
        #expect(package.fileHashes["bg.js"] == hex("1"))
        #expect(package.fileHashes.count == 3)
        let mode = try FileManager.default.attributesOfItem(atPath: staging.appending(path: "bg.js").path)[.posixPermissions] as? Int
        #expect(mode == 0o644)

        let plan = StoreInstall.plan(
            id: developerID, store: .chromeWebStore, version: package.version, displayName: package.displayName,
            sources: ExtensionSources(), existingFolders: []
        )
        #expect(plan == .install(folder: "sponsor-block"))
        let destination = extensions.appending(path: "sponsor-block", directoryHint: .isDirectory)
        let hadOld = try StoreInstall.swapIn(staged: staging, destination: destination, aside: extensions.appending(path: ".replaced-x"))
        #expect(!hadOld)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let scan = ExtensionScan.scan(extensions, forbiddenRoots: [])
        #expect(scan.entries.map(\.name) == ["sponsor-block"])
    }

    private func unpackError(_ items: [TestZip.Item], store: Persona.Source = .chromeWebStore, id: String? = nil) throws -> StoreInstall.Failure? {
        let zip = TestZip.make(items)
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try StoreInstall.unpack(
                zip: zip, entries: try ZipSafety.entries(in: zip), store: store, id: id ?? developerID,
                into: root.appending(path: "staging"), scratch: root.appending(path: "scratch")
            )
            return nil
        } catch let failure as StoreInstall.Failure {
            return failure
        }
    }

    @Test func refusesPackagesWithoutAUsableManifest() throws {
        #expect(try unpackError([TestZip.file("a.js")]) == .noManifest)
        #expect(try unpackError([TestZip.Item(name: "inner/"), TestZip.file("inner/manifest.json", "{}")]) == .noManifest)
        #expect(try unpackError([TestZip.Item(name: "manifest.json/"), TestZip.file("manifest.json/x", "{}")]) == .noManifest)
        #expect(try unpackError([TestZip.file("manifest.json", "not json")]) == .manifestUnreadable)
        #expect(try unpackError([TestZip.file("manifest.json", "[1]")]) == .manifestUnreadable)
    }

    @Test func refusesAManifestKeyForAnotherExtension() throws {
        let stranger = TestRSAKey.stranger.spki.base64EncodedString()
        #expect(try unpackError([TestZip.file("manifest.json", #"{"key":"\#(stranger)"}"#)]) == .keyMismatch)
        #expect(try unpackError([TestZip.file("manifest.json", #"{"key":7}"#)]) == .keyMismatch)
        let own = developer.spki.base64EncodedString()
        #expect(try unpackError([TestZip.file("manifest.json", #"{"key":"\#(own)","name":"A"}"#)]) == nil)
    }

    /// Cross-browser add-ons carry a Chrome `key`; the add-on's signature is what checks it (`AMO.verifySignature`), so
    /// the Chrome key rule applies to Chrome Web Store packages only.
    @Test func aChromeKeyIsCheckedOnlyForChromeWebStorePackages() throws {
        let stranger = TestRSAKey.stranger.spki.base64EncodedString()
        let item = TestZip.file("manifest.json", #"{"key":"\#(stranger)","name":"A","browser_specific_settings":{"gecko":{"id":"a@example.com"}}}"#)
        #expect(try unpackError([item], store: .mozillaAddons, id: "a@example.com") == nil)
        #expect(try unpackError([item], store: .chromeWebStore) == .keyMismatch)
    }

    @Test func refusesAnExistingStagingFolder() throws {
        let zip = TestZip.make([TestZip.file("manifest.json", "{}")])
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #expect(throws: StoreInstall.Failure.stagingExists) {
            try StoreInstall.unpack(
                zip: zip, entries: try ZipSafety.entries(in: zip), store: .chromeWebStore, id: developerID, into: staging,
                scratch: root.appending(path: "scratch")
            )
        }
    }

    @Test func nameFallsBackToTheID() throws {
        let zip = TestZip.make([TestZip.file("manifest.json", #"{"name":"__MSG_missing__","default_locale":"en"}"#)])
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try StoreInstall.unpack(
            zip: zip, entries: try ZipSafety.entries(in: zip), store: .chromeWebStore, id: developerID.uppercased(),
            into: root.appending(path: "staging"), scratch: root.appending(path: "scratch")
        )
        #expect(package.displayName == developerID)
        #expect(package.version == nil)
    }

    @Test func localizedNames() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "_locales/en_US", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"extName": {"message": "Dark Reader"}}"#.utf8).write(to: folder.appending(path: "messages.json"))
        let manifest: [String: Any] = ["default_locale": "en_US"]
        #expect(StoreInstall.localized("Plain", manifest: manifest, root: root) == "Plain")
        #expect(StoreInstall.localized("__MSG_extname__", manifest: manifest, root: root) == "Dark Reader")
        #expect(StoreInstall.localized("__MSG_other__", manifest: manifest, root: root) == nil)
        #expect(StoreInstall.localized("__MSG_extName__", manifest: [:], root: root) == nil)
        #expect(StoreInstall.localized("__MSG_extName__", manifest: ["default_locale": "../_locales/en_US"], root: root) == nil)
        #expect(StoreInstall.displayName(manifest: ["name": "__MSG_extName__", "default_locale": "en_US"], root: root) == "Dark Reader")
        #expect(StoreInstall.displayName(manifest: [:], root: root) == nil)
    }

    @Test func plans() {
        var sources = ExtensionSources()
        sources.recordInstall(folder: "sponsorblock", store: .chromeWebStore, id: developerID, version: "5.9.1", fileHashes: [:], now: Date())
        let existing: Set<String> = ["sponsorblock", "dark-reader"]
        #expect(StoreInstall.plan(id: developerID.uppercased(), store: .chromeWebStore, version: "5.9.1", displayName: "x", sources: sources, existingFolders: existing)
            == .alreadyInstalled(folder: "sponsorblock", version: "5.9.1"))
        #expect(StoreInstall.plan(id: developerID, store: .chromeWebStore, version: "5.10", displayName: "x", sources: sources, existingFolders: existing)
            == .replace(folder: "sponsorblock", oldVersion: "5.9.1", newVersion: "5.10"))
        // Its folder was deleted: a fresh install.
        #expect(StoreInstall.plan(id: developerID, store: .chromeWebStore, version: "5.9.1", displayName: "SponsorBlock", sources: sources, existingFolders: ["dark-reader"])
            == .install(folder: "sponsorblock"))
        // Another extension's name collides.
        #expect(StoreInstall.plan(id: String(repeating: "a", count: 32), store: .chromeWebStore, version: "1", displayName: "Dark Reader", sources: sources, existingFolders: existing)
            == .install(folder: "dark-reader-2"))
    }

    @Test func swapKeepsTheOldCopyUntilFinishedAndRollsBack() throws {
        let fm = FileManager.default
        let root = try temporaryFolder()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appending(path: "ext"), staged = root.appending(path: ".installing"), aside = root.appending(path: ".replaced")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "manifest.json"))
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appending(path: "manifest.json"))

        #expect(try StoreInstall.swapIn(staged: staged, destination: destination, aside: aside))
        #expect(try String(contentsOf: destination.appending(path: "manifest.json"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: aside.appending(path: "manifest.json"), encoding: .utf8) == "old")

        try StoreInstall.rollBack(destination: destination, aside: aside, hadOld: true)
        #expect(try String(contentsOf: destination.appending(path: "manifest.json"), encoding: .utf8) == "old")
        #expect(!fm.fileExists(atPath: aside.path))
    }

    @Test func failedSwapRestoresTheOldCopy() throws {
        let fm = FileManager.default
        let root = try temporaryFolder()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appending(path: "ext"), aside = root.appending(path: ".replaced")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "manifest.json"))
        #expect(throws: (any Error).self) {
            try StoreInstall.swapIn(staged: root.appending(path: "missing"), destination: destination, aside: aside)
        }
        #expect(try String(contentsOf: destination.appending(path: "manifest.json"), encoding: .utf8) == "old")
        #expect(!fm.fileExists(atPath: aside.path))
    }

    @Test func freshInstallRollsBackToNothing() throws {
        let fm = FileManager.default
        let root = try temporaryFolder()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appending(path: "ext"), staged = root.appending(path: ".installing")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        #expect(try !StoreInstall.swapIn(staged: staged, destination: destination, aside: root.appending(path: ".replaced")))
        try StoreInstall.rollBack(destination: destination, aside: root.appending(path: ".replaced"), hadOld: false)
        #expect(!fm.fileExists(atPath: destination.path))
    }

    @Test func changedFiles() {
        let recorded = ["manifest.json": "a", "bg.js": "b", "gone.js": "c"]
        let current = ["manifest.json": "a", "bg.js": "B", "new.js": "d"]
        #expect(StoreInstall.changedFiles(recorded: recorded, current: current) == ["bg.js", "gone.js", "new.js"])
        #expect(StoreInstall.changedFiles(recorded: [:], current: current).isEmpty)
        #expect(StoreInstall.changedFiles(recorded: recorded, current: recorded).isEmpty)
    }

    @Test func storePageNames() {
        #expect(StoreInstall.storePageName(title: "SponsorBlock for YouTube - Chrome Web Store") == "SponsorBlock for YouTube")
        #expect(StoreInstall.storePageName(title: "  Dark Reader  ") == "Dark Reader")
        #expect(StoreInstall.storePageName(title: "Chrome Web Store") == nil)
        #expect(StoreInstall.storePageName(title: "") == nil)
    }

    @Test func pruneDropsGoneFolders() {
        var sources = ExtensionSources()
        sources.records["a"] = .init(store: .chromeWebStore, id: developerID)
        sources.records["b"] = .init(store: .chromeWebStore, id: String(repeating: "b", count: 32))
        let unchanged = sources.prune(keeping: ["a", "b"])
        #expect(!unchanged)
        let dropped = sources.prune(keeping: ["a"])
        #expect(dropped)
        #expect(Array(sources.records.keys) == ["a"])
    }
}
