import CryptoKit
import Foundation
import Security

/// AMO install checks (no network; `StoreInstaller` fetches): lookup (`apiURL`, `decodeAddon`),
/// download (`isAllowedAMODownload`, `checkDownload`), gecko id (`manifestNamesGUID`) and signature
/// (`verifySignature`).
///
/// Signature as Firefox checks it: every file listed in `META-INF/manifest.mf` with SHA-256; that
/// digest in `META-INF/mozilla.sf`; `META-INF/mozilla.rsa` a detached CMS signature over the `.sf` by
/// a certificate whose CN is the add-on's guid. Chain-to-Mozilla is checked only when a root is
/// passed (`bundledRootCertificate()`). Without one the package is `.unverifiedChain`: hash and
/// signature checked, certificate not.
public enum AMO {
    /// The only hosts a lookup, a download or a redirect may use.
    static let hosts: Set<String> = ["addons.mozilla.org", "addons.cdn.mozilla.net"]
    /// The largest lookup answer accepted. An add-on's API page is a few KB.
    public static let maxLookupSize = 1024 * 1024

    static let manifestPath = "META-INF/manifest.mf"
    static let signatureFilePath = "META-INF/mozilla.sf"
    static let signaturePath = "META-INF/mozilla.rsa"

    /// Why an add-on was refused. The text follows "Not installed: ".
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// The slug or guid can't be made into a lookup address.
        case badID
        /// The lookup answer isn't JSON.
        case unreadable
        /// A field is missing or has the wrong type; the field's path, such as "current_version.file.url".
        case malformed(String)
        /// The add-on has no current version.
        case noCurrentVersion
        /// The guid isn't a valid add-on id, or isn't the guid that was asked for.
        case otherAddon
        /// The file isn't on an allowed Mozilla host over https.
        case fileNotAllowed
        /// The API's hash isn't `sha256:` followed by 64 hex digits.
        case badHash
        /// The download isn't the size the API gave.
        case sizeMismatch
        /// The download's SHA-256 isn't the one the API gave.
        case hashMismatch
        /// The package lacks `META-INF/manifest.mf`, `mozilla.sf` or `mozilla.rsa`.
        case unsigned
        /// A `META-INF/` file other than the signature files and the COSE pair (a name that differs in case included).
        case strayMetaInf(String)
        /// A signature file isn't a readable JAR manifest, or lists a name it shouldn't (the path).
        case unreadableSignature(String)
        /// A file the signature manifest doesn't list.
        case unlisted(String)
        /// A file the signature manifest lists but the package lacks.
        case missing(String)
        /// A listed file with no SHA-256 digest. SHA-1 alone is refused.
        case noSHA256(String)
        /// A file whose digest differs from the manifest's.
        case digest(String)
        /// `mozilla.sf`'s `SHA256-Digest-Manifest` isn't the SHA-256 of `manifest.mf`.
        case manifestDigest
        /// `mozilla.rsa` isn't a readable CMS signature.
        case cms
        /// `mozilla.rsa` isn't signed by exactly one certificate.
        case signers
        /// The signature doesn't verify over `mozilla.sf`.
        case signature
        /// The signing certificate's common name isn't the add-on's guid.
        case certificateName
        /// The signing certificate doesn't chain to the bundled root.
        case chain
        /// `manifest.json` doesn't name the add-on's guid as its gecko id.
        case manifestID
        /// A file in the package can't be read (its path).
        case unreadableFile(String)

        public var errorDescription: String? {
            switch self {
            case .badID: "Paddle couldn't make the lookup address for this add-on"
            case .unreadable: "addons.mozilla.org's answer isn't readable JSON"
            case .malformed(let field): "addons.mozilla.org's answer has no usable \(field)"
            case .noCurrentVersion: "addons.mozilla.org lists no current version for this add-on"
            case .otherAddon: "addons.mozilla.org's answer is for another add-on"
            case .fileNotAllowed: "its file isn't on addons.mozilla.org"
            case .badHash: "addons.mozilla.org's hash for the file isn't SHA-256"
            case .sizeMismatch: "the download isn't the size addons.mozilla.org gave"
            case .hashMismatch: "the download doesn't match the SHA-256 addons.mozilla.org gave"
            case .unsigned: "the add-on isn't signed (META-INF/manifest.mf, mozilla.sf and mozilla.rsa are needed)"
            case .strayMetaInf(let name): "the package has an unexpected file in META-INF/: \(name)"
            case .unreadableSignature(let path): "\(path) isn't a readable signature file"
            case .unlisted(let path): "\(path) isn't listed in META-INF/manifest.mf"
            case .missing(let path): "META-INF/manifest.mf lists \(path), which the package doesn't have"
            case .noSHA256(let path): "META-INF/manifest.mf has no SHA-256 digest for \(path)"
            case .digest(let path): "\(path) doesn't match its digest in META-INF/manifest.mf"
            case .manifestDigest: "META-INF/mozilla.sf doesn't match META-INF/manifest.mf"
            case .cms: "META-INF/mozilla.rsa isn't a readable signature"
            case .signers: "META-INF/mozilla.rsa isn't signed by exactly one certificate"
            case .signature: "META-INF/mozilla.rsa doesn't verify META-INF/mozilla.sf"
            case .certificateName: "the signing certificate isn't named for this add-on's id"
            case .chain: "the signing certificate doesn't chain to Mozilla's root"
            case .manifestID: "manifest.json doesn't name this add-on's id as its Firefox id"
            case .unreadableFile(let path): "a file in the package can't be read: \(path)"
            }
        }
    }

    /// How far a package's signature was checked. `.verified`: the certificate chains to the bundled Mozilla root.
    /// `.unverifiedChain`: no root is bundled, so the hash and signature were checked and the chain was not.
    public enum Trust: Sendable, Equatable {
        case verified
        case unverifiedChain
    }

    /// A package whose signature checks passed.
    public struct Signed: Sendable, Equatable {
        /// The add-on's guid, which the signing certificate is named for.
        public let guid: String
        public let trust: Trust
    }

    /// What the API says about an add-on's current version.
    public struct Addon: Sendable, Equatable {
        /// The add-on's guid. The package's `manifest.json` must name it as its gecko id.
        public let guid: String
        /// The `en-US` name, else the first locale's in sorted order. Extension text: sanitize before showing it.
        public let name: String
        public let version: String
        /// The `.xpi`'s address; always an `isAllowedAMODownload` address.
        public let fileURL: URL
        /// SHA-256 of the file, lowercase hex.
        public let sha256: String
        /// The file's size, when the API gives one.
        public let size: Int?
    }

    // MARK: - Lookup

    /// The API address for an add-on by slug, numeric id or guid: `https://addons.mozilla.org/api/v5/addons/addon/<id>/`.
    /// Nil unless `storeID` passes `isSlug` or `isGUID`.
    public static func apiURL(storeID: String) -> URL? {
        guard isSlug(storeID) || isGUID(storeID),
              let encoded = storeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(encoded)/")
    }

    /// Reads the API's answer for `requested`, a slug or guid. Strict: a missing or mistyped field, a guid that isn't a
    /// valid add-on id (or, when `requested` is a guid, isn't that one), no current version, a file address outside
    /// `isAllowedAMODownload`, or a hash that isn't `sha256:` and 64 hex digits is refused. Other fields are ignored.
    public static func decodeAddon(_ answer: Data, requested: String) throws -> Addon {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: answer)
        } catch let error as DecodingError {
            let field = fieldPath(error)
            throw field.isEmpty ? Failure.unreadable : Failure.malformed(field)
        } catch {
            throw Failure.unreadable
        }
        guard isGUID(response.guid) else { throw Failure.malformed("guid") }
        if isGUID(requested), response.guid != requested { throw Failure.otherAddon }
        guard let name = response.name.value else { throw Failure.malformed("name") }
        guard let current = response.currentVersion else { throw Failure.noCurrentVersion }
        guard !current.version.isEmpty else { throw Failure.malformed("current_version.version") }
        guard let url = URL(string: current.file.url), isAllowedAMODownload(url) else { throw Failure.fileNotAllowed }
        guard let sha256 = parseSHA256(current.file.hash) else { throw Failure.badHash }
        return Addon(
            guid: response.guid, name: name, version: current.version, fileURL: url, sha256: sha256, size: current.file.size
        )
    }

    /// Whether a lookup, a download or a redirect may use `url`: https on the default port, no user or password, and
    /// exactly `addons.mozilla.org` or `addons.cdn.mozilla.net`.
    public static func isAllowedAMODownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Checks a downloaded `.xpi` against the API's answer: its size when the API gives one, then its SHA-256.
    public static func checkDownload(_ file: Data, for addon: Addon) throws {
        if let size = addon.size, size != file.count { throw Failure.sizeMismatch }
        guard digestHex(file) == addon.sha256 else { throw Failure.hashMismatch }
    }

    /// Whether `manifest` (a parsed `manifest.json`) names `guid` as its gecko id: `browser_specific_settings.gecko.id`,
    /// or the older `applications.gecko.id`. Each one present must be `guid`, and at least one must be present.
    public static func manifestNamesGUID(_ manifest: [String: Any], guid: String) -> Bool {
        var named = 0
        for key in ["browser_specific_settings", "applications"] {
            guard let settings = manifest[key] as? [String: Any], let gecko = settings["gecko"] else { continue }
            guard let gecko = gecko as? [String: Any], (gecko["id"] as? String) == guid else { return false }
            named += 1
        }
        return named > 0
    }

    /// The add-on's name from an addons.mozilla.org page title ("uBlock Origin – Get this Extension for 🦊 Firefox
    /// (en-US)"): the text before the first dash-separated suffix. Nil when that is empty.
    public static func pageName(title: String) -> String? {
        var name = title
        for separator in [" – ", " — ", " - "] {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An add-on slug: 1 to 100 lowercase ASCII letters, digits, hyphens or underscores. Numeric ids pass too.
    static func isSlug(_ text: String) -> Bool {
        (1...100).contains(text.count) && text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    /// A guid: `{` a UUID `}` in braces (hex, either case), or an email-like id `name@domain` of ASCII letters, digits,
    /// `-`, `_`, `.` and `+` around one `@`. At most 128 characters.
    static func isGUID(_ text: String) -> Bool {
        guard (1...128).contains(text.count) else { return false }
        if text.hasPrefix("{") || text.hasSuffix("}") {
            guard text.hasPrefix("{"), text.hasSuffix("}") else { return false }
            let inner = Array(text.dropFirst().dropLast())
            guard inner.count == 36 else { return false }
            return inner.indices.allSatisfy { index in
                [8, 13, 18, 23].contains(index) ? inner[index] == "-" : inner[index].isHexDigit
            }
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "-_.+@".unicodeScalars.contains(scalar)
        }
    }

    // MARK: - Files

    /// Every regular file under `folder`, read whole, by path with NFC normalization (as `StoreInstall.fileHashes` names
    /// them). Directories are walked; anything else (a link, a special file) is refused, since its bytes couldn't be
    /// checked against the signature.
    public static func readFiles(in folder: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else {
            throw Failure.unreadableFile("the folder itself")
        }
        var files: [String: Data] = [:]
        while let path = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            guard type == .typeRegular else { throw Failure.unreadableFile(path) }
            let key = path.precomposedStringWithCanonicalMapping
            guard files[key] == nil, let data = try? Data(contentsOf: folder.appending(path: path)) else {
                throw Failure.unreadableFile(path)
            }
            files[key] = data
        }
        return files
    }

    // MARK: - Signature

    /// Checks a signed add-on's files. `files` is every regular file in the package by path, with its bytes. Requires:
    /// `META-INF/manifest.mf`, `mozilla.sf` and `mozilla.rsa`; every other file listed in the manifest with a SHA-256
    /// digest that matches (a SHA-1 digest, if listed, must match too; SHA-1 alone is refused), and no listed file
    /// missing or unlisted; `mozilla.sf`'s `SHA256-Digest-Manifest` equal to the manifest's SHA-256; `mozilla.rsa` a
    /// detached CMS signature over `mozilla.sf` by exactly one certificate that verifies; and that certificate's common
    /// name equal to `guid`. Nothing else may sit in `META-INF/` (a name that differs from one of those only in case is
    /// refused too), except Mozilla's COSE pair, `cose.manifest` and `cose.sig`. Mozilla lists that pair in
    /// `manifest.mf`, so its bytes are checked like any other file's; the COSE signature itself is not checked.
    ///
    /// With `anchor` (Mozilla's root), the certificate must also chain to it, and the trust is `.verified`. Without one,
    /// the trust is `.unverifiedChain`: everything else was checked, the chain was not. Never report that as verified.
    public static func verifySignature(files: [String: Data], guid: String, anchor: SecCertificate?) throws -> Signed {
        guard let manifestBytes = files[manifestPath], let signatureFile = files[signatureFilePath],
              let signatureBytes = files[signaturePath] else { throw Failure.unsigned }
        // Only the three signature files and Mozilla's COSE pair may sit in META-INF/, and only the three signature
        // files go unlisted: the COSE pair is covered by manifest.mf like any other file.
        let signatureFiles: Set<String> = [manifestPath, signatureFilePath, signaturePath]
        let coseFiles: Set<String> = ["META-INF/cose.manifest", "META-INF/cose.sig"]
        if let stray = files.keys.sorted().first(where: {
            $0.lowercased().hasPrefix("meta-inf/") && !signatureFiles.contains($0) && !coseFiles.contains($0)
        }) {
            throw Failure.strayMetaInf(stray)
        }

        // Every file listed with a matching digest, and nothing listed that the package lacks.
        guard let sections = jarSections(manifestBytes) else { throw Failure.unreadableSignature(manifestPath) }
        var listed: [String: [String: String]] = [:]
        for section in sections.dropFirst() where !section.isEmpty {
            guard let name = section["name"]?.precomposedStringWithCanonicalMapping,
                  !name.lowercased().hasPrefix("meta-inf/") || coseFiles.contains(name),
                  listed[name] == nil else { throw Failure.unreadableSignature(manifestPath) }
            listed[name] = section
        }
        if let extra = files.keys.filter({ !signatureFiles.contains($0) }).sorted().first(where: { listed[$0] == nil }) {
            throw Failure.unlisted(extra)
        }
        for name in listed.keys.sorted() {
            guard let data = files[name] else { throw Failure.missing(name) }
            guard let section = listed[name], let sha256 = section["sha256-digest"] else { throw Failure.noSHA256(name) }
            guard matches(data, base64: sha256, sha256: true) else { throw Failure.digest(name) }
            if let sha1 = section["sha1-digest"], !matches(data, base64: sha1, sha256: false) { throw Failure.digest(name) }
        }

        // The signature file names the manifest's digest, and the signature covers the signature file.
        guard let signatureSections = jarSections(signatureFile) else { throw Failure.unreadableSignature(signatureFilePath) }
        guard let manifestDigest = signatureSections.first?["sha256-digest-manifest"],
              matches(manifestBytes, base64: manifestDigest, sha256: true) else { throw Failure.manifestDigest }
        let signer = try signerOf(signature: signatureBytes, content: signatureFile)

        var commonName: CFString?
        guard SecCertificateCopyCommonName(signer.leaf, &commonName) == errSecSuccess,
              (commonName as String?) == guid else { throw Failure.certificateName }
        guard let anchor else { return Signed(guid: guid, trust: .unverifiedChain) }
        guard chains(to: anchor, through: signer.certificates) else { throw Failure.chain }
        return Signed(guid: guid, trust: .verified)
    }

    /// The one signer of the detached CMS `signature` over `content`, once its signature verifies: the signer's
    /// certificate, and every certificate the signature carries (the chain it can be checked through). A signature that
    /// carries content of its own is refused: CMSDecoder verifies that content and ignores the detached `content`.
    static func signerOf(signature: Data, content: Data) throws -> (leaf: SecCertificate, certificates: [SecCertificate]) {
        guard !signature.isEmpty else { throw Failure.cms }
        var decoderRef: CMSDecoder?
        guard CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else { throw Failure.cms }
        let updated = signature.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard updated == errSecSuccess, CMSDecoderSetDetachedContent(decoder, content as CFData) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { throw Failure.cms }
        // Detached only: with content inside, the signature would be over that content, not over mozilla.sf.
        var embedded: CFData?
        guard CMSDecoderCopyContent(decoder, &embedded) == errSecSuccess, embedded == nil else { throw Failure.signature }
        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess, signerCount == 1 else { throw Failure.signers }
        // Signature only: the chain is checked by `chains(to:through:)`, against the anchor alone.
        var status = CMSSignerStatus.unsigned
        guard CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil) == errSecSuccess,
              status == .valid else { throw Failure.signature }
        var leafRef: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &leafRef) == errSecSuccess, let leaf = leafRef else { throw Failure.cms }
        var carried: CFArray?
        guard CMSDecoderCopyAllCerts(decoder, &carried) == errSecSuccess else { throw Failure.cms }
        return (leaf, [leaf] + ((carried as? [SecCertificate]) ?? []))
    }

    /// Whether `certificates` (the signer first) build a chain that `anchor` alone anchors, under the basic X.509 policy
    /// and the current date. Nothing else in the system's trust store counts, and nothing is fetched over the network:
    /// the chain must be complete in the package.
    static func chains(to anchor: SecCertificate, through certificates: [SecCertificate]) -> Bool {
        var trustRef: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trustRef) == errSecSuccess,
              let trust = trustRef else { return false }
        return SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
            && SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess
            && SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
            && SecTrustEvaluateWithError(trust, nil)
    }

    /// SHA-256 of Mozilla's add-on root (`CN=root-ca-production-amo`, the 2024 reissue valid to 2200), as Firefox's
    /// `security/manager/ssl/addons-public.pem` holds it and Firefox 157 carries it.
    public static let rootFingerprint = Data([
        0xc8, 0xa8, 0x0e, 0x9a, 0xfa, 0xef, 0x4e, 0x21, 0x9b, 0x6f, 0xb5, 0xd7, 0xa7, 0x1d, 0x0f, 0x10,
        0x12, 0x23, 0xba, 0xc5, 0x00, 0x1a, 0xc2, 0x8f, 0x9b, 0x0d, 0x43, 0xdc, 0x59, 0xa1, 0x06, 0xdb,
    ])

    /// The root certificate that signs add-on certificates, from `AMO/addons-root.der` in the app's resources, and
    /// only if its bytes are the ones `rootFingerprint` names. Nil otherwise, and installs are then unverified.
    public static func bundledRootCertificate() -> SecCertificate? {
        guard let url = Bundle.main.url(forResource: "addons-root", withExtension: "der", subdirectory: "AMO"),
              let der = try? Data(contentsOf: url), Data(SHA256.hash(data: der)) == rootFingerprint else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// Whether `base64` is the SHA-256 digest of `data`, or the SHA-1 digest when `sha256` is false.
    static func matches(_ data: Data, base64: String, sha256: Bool) -> Bool {
        guard let expected = Data(base64Encoded: base64) else { return false }
        return sha256 ? expected == Data(SHA256.hash(data: data)) : expected == Data(Insecure.SHA1.hash(data: data))
    }

    /// The sections of a JAR manifest or signature file, main section first, then one per entry. An attribute is
    /// `name: value`; a line starting with one space continues the value before it; a blank line ends a section.
    /// Attribute names are lowercased. Nil for anything else: a line without `: `, a name that isn't ASCII letters,
    /// digits, `-` or `_`, a name repeated in a section, a continuation with nothing before it, or text that isn't UTF-8.
    static func jarSections(_ data: Data) -> [[String: String]]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var sections: [[String: String]] = [[:]]
        var lastName: String?
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                sections.append([:])
                lastName = nil
            } else if line.hasPrefix(" ") {
                guard let name = lastName else { return nil }
                sections[sections.count - 1][name, default: ""].append(contentsOf: line.dropFirst())
            } else {
                guard let separator = line.range(of: ": ") else { return nil }
                let key = line[..<separator.lowerBound]
                guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
                else { return nil }
                let name = key.lowercased()
                guard sections[sections.count - 1][name] == nil else { return nil }
                sections[sections.count - 1][name] = String(line[separator.upperBound...])
                lastName = name
            }
        }
        return sections
    }

    // MARK: - Pieces

    /// The lowercase hex SHA-256 of `data`.
    static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The lowercase hex of a `sha256:` hash with 64 hex digits; nil for anything else.
    static func parseSHA256(_ hash: String) -> String? {
        guard hash.hasPrefix("sha256:") else { return nil }
        let hex = hash.dropFirst(7).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// The dotted path a decoding error points at ("current_version.file.url"); empty for a bad document.
    static func fieldPath(_ error: DecodingError) -> String {
        let keys: [any CodingKey]
        switch error {
        case .keyNotFound(let key, let context): keys = context.codingPath + [key]
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context): keys = context.codingPath
        @unknown default: keys = []
        }
        return keys.map(\.stringValue).joined(separator: ".")
    }

    /// The API's answer, as decoded. Only the fields used are declared.
    private struct Response: Decodable {
        let guid: String
        let name: Localized
        let currentVersion: Version?

        enum CodingKeys: String, CodingKey {
            case guid, name
            case currentVersion = "current_version"
        }
    }

    private struct Version: Decodable {
        let version: String
        let file: File
    }

    private struct File: Decodable {
        let url: String
        let hash: String
        let size: Int?
    }

    /// An API name: a string, or a map from locale to string.
    private enum Localized: Decodable {
        case plain(String)
        case locales([String: String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .plain(text)
            } else {
                self = .locales(try container.decode([String: String].self))
            }
        }

        /// The trimmed name: `en-US`, else the first locale's in sorted order. Nil when there is none or it is empty.
        var value: String? {
            let name: String?
            switch self {
            case .plain(let text): name = text
            case .locales(let locales): name = locales["en-US"] ?? locales.keys.sorted().first.flatMap { locales[$0] }
            }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}
