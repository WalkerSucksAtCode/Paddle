import CryptoKit
import Foundation
import Security
@testable import PaddleCore
import Testing

/// Certificates made with /usr/bin/openssl in a folder of their own: a root, an intermediate it signs, and a leaf named
/// by `leafSubject`, plus whatever a test adds. Nothing outside the test trusts them.
struct TestPKI {
    enum Failure: Error {
        case openssl(String, String)
        case unreadable(String)
    }

    /// How a signature manifest records each file's digests.
    enum Digests {
        /// SHA-256 only, as Mozilla signs.
        case sha256
        /// SHA-1 only.
        case sha1Only
        /// SHA-256 and the right SHA-1.
        case both
        /// SHA-256 and a SHA-1 of other bytes.
        case wrongSHA1
    }

    let folder: URL

    /// A root, an intermediate it signs, and a leaf whose common name is `leafSubject`, named `root`, `intermediate`, `leaf`.
    static func make(leafSubject: String) throws -> TestPKI {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "AMOTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pki = TestPKI(folder: folder)
        try pki.certificate("root", subject: "Paddle Test Root", signedBy: nil, ca: true)
        try pki.certificate("intermediate", subject: "Paddle Test Intermediate", signedBy: "root", ca: true)
        try pki.certificate("leaf", subject: leafSubject, signedBy: "intermediate", ca: false)
        return pki
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `name`.key and `name`.pem: a self-signed root when `issuer` is nil, else a certificate that `issuer` signs. `ca`
    /// says whether it may sign certificates itself.
    func certificate(_ name: String, subject: String, signedBy issuer: String?, ca: Bool) throws {
        let extensions = ca
            ? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
            : "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectKeyIdentifier=hash\n"
        try Data(extensions.utf8).write(to: folder.appending(path: "\(name).ext"))
        try openssl([
            "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).csr", "-subj", "/CN=\(subject)",
        ])
        var arguments = ["x509", "-req", "-in", "\(name).csr", "-days", "3650", "-sha256", "-extfile", "\(name).ext", "-out", "\(name).pem"]
        if let issuer {
            arguments += ["-CA", "\(issuer).pem", "-CAkey", "\(issuer).key", "-CAcreateserial"]
        } else {
            arguments += ["-signkey", "\(name).key"]
        }
        try openssl(arguments)
    }

    /// `name`'s certificate as a SecCertificate, to pass as the anchor.
    func anchor(_ name: String) throws -> SecCertificate {
        try openssl(["x509", "-in", "\(name).pem", "-outform", "DER", "-out", "\(name).der"])
        let der = try Data(contentsOf: folder.appending(path: "\(name).der"))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.unreadable("\(name).der") }
        return certificate
    }

    /// `files` plus the three META-INF files that sign them, as Mozilla writes them (CRLF line endings): `manifest.mf`
    /// with the digests of each file, `mozilla.sf` with the manifest's SHA-256, and `mozilla.rsa`, the detached CMS
    /// signature over the `.sf` by `leaf`, carrying `chain`.
    func signed(
        _ files: [String: Data], leaf: String = "leaf", chain: String = "intermediate", digests: Digests = .sha256
    ) throws -> [String: Data] {
        var manifest = Self.manifestHead
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            manifest += "Name: \(name)\r\n"
            if digests != .sha1Only {
                manifest += "SHA256-Digest: \(Data(SHA256.hash(data: data)).base64EncodedString())\r\n"
            }
            switch digests {
            case .sha256: break
            case .sha1Only, .both:
                manifest += "SHA1-Digest: \(Data(Insecure.SHA1.hash(data: data)).base64EncodedString())\r\n"
            case .wrongSHA1:
                manifest += "SHA1-Digest: \(Data(Insecure.SHA1.hash(data: Data("other".utf8))).base64EncodedString())\r\n"
            }
            manifest += "\r\n"
        }
        return try signed(files, manifest: manifest, leaf: leaf, chain: chain)
    }

    /// The main section every test manifest starts with.
    static let manifestHead = "Manifest-Version: 1.0\r\nCreated-By: Paddle tests\r\n\r\n"

    /// One manifest section naming `name` with the SHA-256 of `data`.
    static func entry(_ name: String, _ data: Data) -> String {
        "Name: \(name)\r\nSHA256-Digest: \(Data(SHA256.hash(data: data)).base64EncodedString())\r\n\r\n"
    }

    /// `files` with `manifest` as `META-INF/manifest.mf`, written as given, and the `.sf` and `.rsa` that sign it.
    func signed(_ files: [String: Data], manifest: String, leaf: String = "leaf", chain: String = "intermediate") throws -> [String: Data] {
        let manifestData = Data(manifest.utf8)
        let manifestDigest = Data(SHA256.hash(data: manifestData)).base64EncodedString()
        let signatureFile = Data("Signature-Version: 1.0\r\nCreated-By: Paddle tests\r\nSHA256-Digest-Manifest: \(manifestDigest)\r\n\r\n".utf8)
        var package = files
        package["META-INF/manifest.mf"] = manifestData
        package["META-INF/mozilla.sf"] = signatureFile
        package["META-INF/mozilla.rsa"] = try sign(signatureFile, leaf: leaf, chain: chain)
        return package
    }

    /// The CMS signature (DER) of `content` by `leaf`, with `chain` carried in it: detached unless `attached`, and
    /// signed by `alsoBy` as well when given.
    func sign(_ content: Data, leaf: String, chain: String, attached: Bool = false, alsoBy: String? = nil) throws -> Data {
        try content.write(to: folder.appending(path: "signed-content"))
        var arguments = [
            "cms", "-sign", "-binary", "-in", "signed-content", "-signer", "\(leaf).pem", "-inkey", "\(leaf).key",
            "-certfile", "\(chain).pem", "-outform", "DER", "-md", "sha256", "-out", "signature.rsa",
        ]
        if attached { arguments.append("-nodetach") }
        if let alsoBy { arguments += ["-signer", "\(alsoBy).pem", "-inkey", "\(alsoBy).key"] }
        try openssl(arguments)
        return try Data(contentsOf: folder.appending(path: "signature.rsa"))
    }

    /// Runs /usr/bin/openssl in the folder; throws with its complaint when it fails.
    private func openssl(_ arguments: [String]) throws {
        let process = Process()
        let complaints = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = complaints
        try process.run()
        let text = String(decoding: complaints.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.openssl(arguments.first ?? "", text) }
    }
}

/// The signature checks on signed add-on packages, built with `TestPKI`.
struct AMOSignatureTests {
    private let guid = "paddle-test@example.org"

    /// The files of a small add-on whose `manifest.json` names `guid` as its gecko id.
    private func addon() -> [String: Data] {
        [
            "manifest.json": Data(#"{"manifest_version": 2, "name": "Paddle Test", "version": "1.0", "browser_specific_settings": {"gecko": {"id": "\#(guid)"}}}"#.utf8),
            "background.js": Data("console.log('hello');\n".utf8),
            "content/style.css": Data("body { color: black; }\n".utf8),
        ]
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

    @Test func aSignedAddonVerifiesAgainstTheRoot() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon())
        let signed = try AMO.verifySignature(files: files, guid: guid, anchor: pki.anchor("root"))
        #expect(signed == AMO.Signed(guid: guid, trust: .verified))
    }

    @Test func withoutARootTheSignatureVerifiesButTheChainIsNotChecked() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon())
        #expect(try AMO.verifySignature(files: files, guid: guid, anchor: nil) == AMO.Signed(guid: guid, trust: .unverifiedChain))
    }

    @Test func aTamperedFileIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files["background.js"] = Data("alert('evil');\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .digest("background.js"))
    }

    @Test func aFileTheManifestDoesNotListIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files["extra.js"] = Data("extra\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .unlisted("extra.js"))
    }

    @Test func aListedFileThePackageLacksIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files.removeValue(forKey: "content/style.css")
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .missing("content/style.css"))
    }

    @Test func aChangedManifestFailsTheSignatureFileDigest() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files["META-INF/manifest.mf"]?.append(Data("\r\n".utf8))
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .manifestDigest)
    }

    @Test func aChangedSignatureFileFailsTheSignature() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        let text = String(decoding: try #require(files["META-INF/mozilla.sf"]), as: UTF8.self)
        files["META-INF/mozilla.sf"] = Data(text.replacingOccurrences(of: "Created-By: Paddle tests", with: "Created-By: Mallory").utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .signature)
    }

    @Test func aSignatureFromAnotherRootIsRefusedWithTheAnchor() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        try pki.certificate("rogueRoot", subject: "Rogue Root", signedBy: nil, ca: true)
        try pki.certificate("rogue", subject: guid, signedBy: "rogueRoot", ca: false)
        let files = try pki.signed(addon(), leaf: "rogue", chain: "rogueRoot")
        let anchor = try pki.anchor("root")
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: anchor) } == .chain)
        // Without a root nothing is anchored, so the chain isn't checked (and isn't reported as verified).
        #expect(try AMO.verifySignature(files: files, guid: guid, anchor: nil) == AMO.Signed(guid: guid, trust: .unverifiedChain))
    }

    @Test func theCertificateNameMustBeTheGUID() throws {
        let pki = try TestPKI.make(leafSubject: "someone-else@example.org")
        defer { pki.remove() }
        let files = try pki.signed(addon())
        let anchor = try pki.anchor("root")
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: anchor) } == .certificateName)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .certificateName)
    }

    @Test func aSHA1OnlyManifestIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon(), digests: .sha1Only)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .noSHA256("background.js"))
    }

    @Test func aWrongSHA1BesideAMatchingSHA256IsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon(), digests: .wrongSHA1)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .digest("background.js"))
    }

    @Test func aMatchingSHA1BesideTheSHA256Verifies() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon(), digests: .both)
        #expect(try AMO.verifySignature(files: files, guid: guid, anchor: nil) == AMO.Signed(guid: guid, trust: .unverifiedChain))
    }

    @Test func aPackageWithoutItsSignatureFilesIsUnsigned() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files.removeValue(forKey: "META-INF/mozilla.rsa")
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .unsigned)
    }

    @Test func aMetaINFNameInAnotherCaseIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        files["meta-inf/mozilla.txt"] = Data("stray\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .strayMetaInf("meta-inf/mozilla.txt"))
    }

    @Test func theCOSEPairIsAllowedWhenListedButOtherMetaINFFilesAreRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var cose = addon()
        cose["META-INF/cose.manifest"] = Data("cose manifest\n".utf8)
        cose["META-INF/cose.sig"] = Data("cose signature\n".utf8)
        // Listed in manifest.mf, as Mozilla signs: checked like any other file.
        var files = try pki.signed(cose)
        #expect(try AMO.verifySignature(files: files, guid: guid, anchor: nil) == AMO.Signed(guid: guid, trust: .unverifiedChain))
        files["META-INF/cose.sig"] = Data("changed\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .digest("META-INF/cose.sig"))
        // Not listed: refused, not trusted silently.
        files = try pki.signed(addon())
        files["META-INF/cose.manifest"] = Data("cose manifest\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .unlisted("META-INF/cose.manifest"))
        files = try pki.signed(addon())
        files["META-INF/extra.txt"] = Data("stray\n".utf8)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .strayMetaInf("META-INF/extra.txt"))
    }

    @Test func aSignatureCarryingContentOfItsOwnIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        var files = try pki.signed(addon())
        // A valid signature by the right certificate, but over other bytes inside it: CMSDecoder would verify those.
        files["META-INF/mozilla.rsa"] = try pki.sign(Data("other content".utf8), leaf: "leaf", chain: "intermediate", attached: true)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: pki.anchor("root")) } == .signature)
        // Even over the right bytes: Mozilla's signature is detached, so anything else is refused.
        let sf = try #require(files["META-INF/mozilla.sf"])
        files["META-INF/mozilla.rsa"] = try pki.sign(sf, leaf: "leaf", chain: "intermediate", attached: true)
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: nil) } == .signature)
    }

    @Test func aSignatureWithTwoSignersIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        try pki.certificate("second", subject: guid, signedBy: "intermediate", ca: false)
        var files = try pki.signed(addon())
        let sf = try #require(files["META-INF/mozilla.sf"])
        files["META-INF/mozilla.rsa"] = try pki.sign(sf, leaf: "leaf", chain: "intermediate", alsoBy: "second")
        #expect(refusal { try AMO.verifySignature(files: files, guid: guid, anchor: pki.anchor("root")) } == .signers)
    }

    @Test func aWrappedNameInTheManifestVerifies() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = addon()
        var manifest = TestPKI.manifestHead
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            // JAR manifests wrap long lines; a continuation starts with one space.
            let section = TestPKI.entry(name, data)
            manifest += name == "content/style.css" ? section.replacingOccurrences(of: "content/st", with: "content/st\r\n ") : section
        }
        #expect(manifest.contains("content/st\r\n yle.css"))
        let signed = try pki.signed(files, manifest: manifest)
        #expect(try AMO.verifySignature(files: signed, guid: guid, anchor: pki.anchor("root")) == AMO.Signed(guid: guid, trust: .verified))
    }

    @Test func aBrokenManifestSectionIsRefused() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = addon()
        let sections = files.sorted { $0.key < $1.key }.map { TestPKI.entry($0.key, $0.value) }.joined()
        let background = try #require(files["background.js"])
        let digest = Data(SHA256.hash(data: background)).base64EncodedString()
        let broken = [
            // A section without a name.
            sections + "SHA256-Digest: \(digest)\r\n\r\n",
            // The same name twice.
            sections + TestPKI.entry("background.js", background),
            // A signature file listed as if it were content.
            sections + TestPKI.entry("META-INF/mozilla.sf", background),
        ]
        for (index, body) in broken.enumerated() {
            let signed = try pki.signed(files, manifest: TestPKI.manifestHead + body)
            #expect(refusal { try AMO.verifySignature(files: signed, guid: guid, anchor: nil) } == .unreadableSignature("META-INF/manifest.mf"),
                    "case \(index)")
        }
        // The intact manifest verifies, so each refusal above is the broken section's.
        let intact = try pki.signed(files, manifest: TestPKI.manifestHead + sections)
        #expect(try AMO.verifySignature(files: intact, guid: guid, anchor: nil) == AMO.Signed(guid: guid, trust: .unverifiedChain))
    }

    @Test func readingAPackageRefusesALink() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AMOLink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "sub/a.js"))
        #expect(try AMO.readFiles(in: root) == ["sub/a.js": Data("a".utf8)])
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link.js").path, withDestinationPath: "sub/a.js")
        #expect(refusal { try AMO.readFiles(in: root) } == .unreadableFile("link.js"))
    }

    @Test func aZIPPackageUnpacksAndVerifiesAfterwards() throws {
        let pki = try TestPKI.make(leafSubject: guid)
        defer { pki.remove() }
        let files = try pki.signed(addon())
        let zip = TestZip.make(files.sorted { $0.key < $1.key }.map { TestZip.Item(name: $0.key, data: $0.value) })
        let root = FileManager.default.temporaryDirectory.appending(path: "AMOZip-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ZipSafety.entries(in: zip)
        let package = try StoreInstall.unpack(
            zip: zip, entries: entries, store: .mozillaAddons, id: guid, into: root.appending(path: "staging"),
            scratch: root.appending(path: "scratch")
        )
        let unpacked = try AMO.readFiles(in: package.folder)
        #expect(unpacked == files)
        #expect(try AMO.verifySignature(files: unpacked, guid: guid, anchor: pki.anchor("root")) == AMO.Signed(guid: guid, trust: .verified))
    }
}

/// The root bundled in the app (`Resources/AMO/addons-root.der`) is the one `AMO.rootFingerprint` names: Mozilla's
/// `root-ca-production-amo`.
struct AMOBundledRootTests {
    @Test func bundledRootMatchesTheFingerprint() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/AMO/addons-root.der")
        let der = try Data(contentsOf: url.standardizedFileURL)
        #expect(Data(SHA256.hash(data: der)) == AMO.rootFingerprint)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "root-ca-production-amo")
    }
}
