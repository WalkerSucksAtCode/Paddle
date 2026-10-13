import CryptoKit
import Foundation
import Security

/// Chrome's CRX3 package: `Cr24`, a little-endian UInt32 format version (3), a little-endian UInt32 header length,
/// a `CrxFileHeader` protobuf of that length, then the ZIP archive. Every proof in the header signs the same
/// message: `"CRX3 SignedData"`, one 0x00 byte, the length of `signed_header_data` (UInt32 LE), the
/// `signed_header_data` bytes and the whole ZIP. Mirrors `components/crx_file/crx_verifier.cc`, stricter where that
/// is lenient: a package is refused on anything this code doesn't understand.
public enum CRX3 {
    /// Larger files are refused before parsing.
    public static let maxFileSize = 100 * 1024 * 1024
    /// Larger headers are refused; real ones are a few KB.
    public static let maxHeaderSize = 64 * 1024

    /// SHA-256 of the Chrome Web Store's publisher key (`kPublisherKeyHash` in `crx_verifier.cc`). Every package
    /// the store serves carries an RSA proof by this key.
    public static let webStorePublisherKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe, 0x24, 0x97, 0xcc, 0x9b, 0x04,
        0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2, 0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ])

    public enum VerifyError: Error, Equatable, Sendable, LocalizedError {
        /// Over `maxFileSize`.
        case tooLarge
        /// No `Cr24` magic.
        case notCRX3
        /// `Cr24` with a format version other than 3.
        case unsupportedVersion(UInt32)
        /// The file ends inside the fixed fields or the header.
        case truncated
        /// The header length is over `maxHeaderSize`.
        case headerTooLarge
        /// The header protobuf, `signed_header_data` or a proof is malformed or missing a field.
        case malformedHeader
        /// A proof's public key isn't a key this code reads (RSA `SubjectPublicKeyInfo` for RSA proofs, P-256 for
        /// ECDSA proofs).
        case unsupportedKey
        /// At least one proof's signature fails.
        case badSignature
        /// No proof is made with the key whose id is `crx_id`.
        case noDeveloperSignature
        /// `crx_id` isn't the id that was asked for.
        case wrongExtension
        /// A publisher key is required and no RSA proof uses one.
        case missingStoreSignature

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "the package is over 100 MB"
            case .notCRX3: "not a CRX3 package"
            case .unsupportedVersion(let version): "not a CRX3 package (format version \(version))"
            case .truncated: "the package is cut short"
            case .headerTooLarge: "the package header is over 64 KB"
            case .malformedHeader: "the package header is damaged"
            case .unsupportedKey: "the package is signed with a key Paddle can't read"
            case .badSignature: "signature does not verify"
            case .noDeveloperSignature: "the package is not signed by its extension's own key"
            case .wrongExtension: "the package is for a different extension"
            case .missingStoreSignature: "missing the Chrome Web Store signature"
            }
        }
    }

    /// A package whose every check passed.
    public struct Verified: Sendable, Equatable {
        /// The extension id (`crx_id` in the a–p alphabet), equal to the id that was asked for.
        public let id: String
        /// The developer key's `SubjectPublicKeyInfo` DER: the key whose id is `id`. Its base64 is what a
        /// manifest `key` holds.
        public let developerPublicKey: Data
        /// Where the ZIP sits in the input, as offsets from its first byte.
        public let zipRange: Range<Int>
        /// The ZIP archive, indexed from 0.
        public let zip: Data
    }

    /// One `AsymmetricKeyProof`.
    struct Proof: Equatable {
        var publicKey: Data
        var signature: Data
    }

    /// The parts of a `CrxFileHeader` this code uses.
    struct Header: Equatable {
        var rsa: [Proof] = []
        var ecdsa: [Proof] = []
        var signedHeaderData = Data()
    }

    /// Checks `data` as a CRX3 package for `expectedID` and returns its ZIP. Requires all of: format version 3;
    /// every proof's signature valid (one bad proof fails the package); a proof by the key whose id is `crx_id`;
    /// `crx_id` equal to `expectedID`; and, when `publisherKeyHashes` isn't empty, an RSA proof by a key whose
    /// SHA-256 (of its DER `SubjectPublicKeyInfo`) is in the set. Pass `[webStorePublisherKeyHash]` for store
    /// downloads.
    public static func verify(_ data: Data, expectedID: String, publisherKeyHashes: Set<Data>) throws -> Verified {
        let (header, zipRange) = try parse(data)
        let start = data.startIndex
        let zip = data.subdata(in: (start + zipRange.lowerBound)..<(start + zipRange.upperBound))

        let crxID = try parseSignedData(header.signedHeaderData)
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        message.append(littleEndian: UInt32(header.signedHeaderData.count))
        message.append(header.signedHeaderData)
        message.append(zip)

        var developerKey: Data?
        var hasPublisher = false
        for proof in header.rsa {
            try verifyRSA(proof, message: message)
            let hash = Data(SHA256.hash(data: proof.publicKey))
            if hash.prefix(16) == crxID, developerKey == nil { developerKey = proof.publicKey }
            if publisherKeyHashes.contains(hash) { hasPublisher = true }
        }
        for proof in header.ecdsa {
            try verifyECDSA(proof, message: message)
            if Data(SHA256.hash(data: proof.publicKey)).prefix(16) == crxID, developerKey == nil { developerKey = proof.publicKey }
        }
        guard let developerKey else { throw VerifyError.noDeveloperSignature }
        let id = ExtensionIdentity.chromeID(publicKeyDER: developerKey)
        guard ExtensionIdentity.isChromeID(id), id == expectedID.lowercased() else { throw VerifyError.wrongExtension }
        if !publisherKeyHashes.isEmpty, !hasPublisher { throw VerifyError.missingStoreSignature }
        return Verified(id: id, developerPublicKey: developerKey, zipRange: zipRange, zip: zip)
    }

    /// The header and the ZIP's range (offsets from the first byte of `data`). Checks the fixed fields, sizes and
    /// header structure only, no signatures.
    static func parse(_ data: Data) throws -> (Header, Range<Int>) {
        guard data.count <= maxFileSize else { throw VerifyError.tooLarge }
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4, bytes[0..<4].elementsEqual("Cr24".utf8) else { throw VerifyError.notCRX3 }
        guard bytes.count == 12 else { throw VerifyError.truncated }
        let version = UInt32(littleEndian: bytes, at: 4)
        guard version == 3 else { throw VerifyError.unsupportedVersion(version) }
        let headerLength = Int(UInt32(littleEndian: bytes, at: 8))
        guard headerLength <= maxHeaderSize else { throw VerifyError.headerTooLarge }
        guard data.count >= 12 + headerLength else { throw VerifyError.truncated }
        let start = data.startIndex
        let header = try parseHeader([UInt8](data[(start + 12)..<(start + 12 + headerLength)]))
        return (header, (12 + headerLength)..<data.count)
    }

    /// `CrxFileHeader`: 2 `sha256_with_rsa`, 3 `sha256_with_ecdsa` (repeated `AsymmetricKeyProof`), 10000
    /// `signed_header_data` (once). Other fields are skipped.
    static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        var header = Header()
        var sawSignedData = false
        var reader = ProtobufReader(bytes)
        do {
            while let field = try reader.next() {
                switch field.number {
                case 2, 3:
                    guard case .bytes(let body) = field.value else { throw VerifyError.malformedHeader }
                    let proof = try parseProof(Array(body))
                    if field.number == 2 { header.rsa.append(proof) } else { header.ecdsa.append(proof) }
                case 10000:
                    guard case .bytes(let body) = field.value, !sawSignedData else { throw VerifyError.malformedHeader }
                    header.signedHeaderData = Data(body)
                    sawSignedData = true
                default:
                    continue
                }
            }
        } catch is ProtobufReader.Malformed {
            throw VerifyError.malformedHeader
        }
        guard sawSignedData else { throw VerifyError.malformedHeader }
        return header
    }

    /// `AsymmetricKeyProof`: 1 `public_key`, 2 `signature`, each once and non-empty.
    static func parseProof(_ bytes: [UInt8]) throws -> Proof {
        var key: Data?
        var signature: Data?
        var reader = ProtobufReader(bytes)
        while let field = try reader.next() {
            guard field.number == 1 || field.number == 2 else { continue }
            guard case .bytes(let body) = field.value, !body.isEmpty else { throw VerifyError.malformedHeader }
            if field.number == 1 {
                guard key == nil else { throw VerifyError.malformedHeader }
                key = Data(body)
            } else {
                guard signature == nil else { throw VerifyError.malformedHeader }
                signature = Data(body)
            }
        }
        guard let key, let signature else { throw VerifyError.malformedHeader }
        return Proof(publicKey: key, signature: signature)
    }

    /// `SignedData`: 1 `crx_id`, once, exactly 16 bytes.
    static func parseSignedData(_ data: Data) throws -> Data {
        var crxID: Data?
        var reader = ProtobufReader([UInt8](data))
        do {
            while let field = try reader.next() {
                guard field.number == 1 else { continue }
                guard case .bytes(let body) = field.value, body.count == 16, crxID == nil else { throw VerifyError.malformedHeader }
                crxID = Data(body)
            }
        } catch is ProtobufReader.Malformed {
            throw VerifyError.malformedHeader
        }
        guard let crxID else { throw VerifyError.malformedHeader }
        return crxID
    }

    // MARK: - Signatures

    /// RSA PKCS#1 v1.5 with SHA-256 over `message`. Keys from 1024 to 8192 bits.
    static func verifyRSA(_ proof: Proof, message: Data) throws {
        guard let pkcs1 = try? rsaPublicKey(fromSPKI: [UInt8](proof.publicKey)) else { throw VerifyError.unsupportedKey }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, nil) else {
            throw VerifyError.unsupportedKey
        }
        let bits = SecKeyGetBlockSize(key) * 8
        guard (1024...8192).contains(bits) else { throw VerifyError.unsupportedKey }
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, proof.signature as CFData, nil) else {
            throw VerifyError.badSignature
        }
    }

    /// ECDSA P-256 with SHA-256 over `message`; the signature is DER. The key's DER must be exactly what CryptoKit
    /// would write for it, so the bytes the id is hashed from are the key that verifies.
    static func verifyECDSA(_ proof: Proof, message: Data) throws {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: proof.publicKey),
              key.derRepresentation == proof.publicKey else { throw VerifyError.unsupportedKey }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature),
              key.isValidSignature(signature, for: message) else { throw VerifyError.badSignature }
    }

    /// The PKCS#1 `RSAPublicKey` inside an RSA `SubjectPublicKeyInfo`:
    /// `SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { RSAPublicKey } }`, DER, nothing trailing,
    /// and the `RSAPublicKey` itself `SEQUENCE { INTEGER, INTEGER }` with nothing trailing.
    static func rsaPublicKey(fromSPKI spki: [UInt8]) throws -> [UInt8] {
        let rsaEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        var outer = DERReader(spki)
        var info = DERReader(try outer.read(tag: 0x30))
        try outer.end()
        var algorithm = DERReader(try info.read(tag: 0x30))
        let bitString = try info.read(tag: 0x03)
        try info.end()
        guard try algorithm.read(tag: 0x06).elementsEqual(rsaEncryption) else { throw DERReader.Malformed() }
        guard try algorithm.read(tag: 0x05).isEmpty else { throw DERReader.Malformed() }
        try algorithm.end()
        guard bitString.first == 0 else { throw DERReader.Malformed() }
        let pkcs1 = Array(bitString.dropFirst())
        var check = DERReader(pkcs1)
        var rsaKey = DERReader(try check.read(tag: 0x30))
        try check.end()
        _ = try rsaKey.read(tag: 0x02)
        _ = try rsaKey.read(tag: 0x02)
        try rsaKey.end()
        return pkcs1
    }
}

// MARK: - Protobuf

/// Reads protobuf wire format: varints and length-delimited fields are returned; 64-bit, 32-bit and group fields
/// are skipped. Refuses truncation, varints over 10 bytes (or a 10th byte over 1), field number 0, lengths past the
/// end, unmatched group ends, groups nested over 16 deep and wire types 6 and 7.
struct ProtobufReader {
    struct Malformed: Error {}

    enum Value {
        case varint(UInt64)
        case bytes(ArraySlice<UInt8>)
        case skipped
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The next field, nil at a clean end.
    mutating func next() throws -> (number: UInt64, value: Value)? {
        guard offset < bytes.count else { return nil }
        let (number, wireType) = try tag()
        switch wireType {
        case 0: return (number, .varint(try varint()))
        case 2: return (number, .bytes(try lengthDelimited()))
        case 1: try skip(8); return (number, .skipped)
        case 5: try skip(4); return (number, .skipped)
        case 3: try skipGroup(number, depth: 1); return (number, .skipped)
        default: throw Malformed()
        }
    }

    private mutating func tag() throws -> (UInt64, UInt64) {
        let tag = try varint()
        let number = tag >> 3
        guard number >= 1, number <= 0x1FFF_FFFF else { throw Malformed() }
        return (number, tag & 7)
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { throw Malformed() }
            let byte = bytes[offset]
            offset += 1
            if index == 9, byte > 1 { throw Malformed() }
            result |= UInt64(byte & 0x7F) << (7 * UInt64(index))
            if byte & 0x80 == 0 { return result }
        }
        throw Malformed()
    }

    private mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
        let length = try varint()
        guard length <= UInt64(bytes.count - offset) else { throw Malformed() }
        let body = bytes[offset..<(offset + Int(length))]
        offset += Int(length)
        return body
    }

    private mutating func skip(_ count: Int) throws {
        guard bytes.count - offset >= count else { throw Malformed() }
        offset += count
    }

    private mutating func skipGroup(_ number: UInt64, depth: Int) throws {
        guard depth <= 16 else { throw Malformed() }
        while true {
            guard offset < bytes.count else { throw Malformed() }
            let (inner, wireType) = try tag()
            switch wireType {
            case 0: _ = try varint()
            case 1: try skip(8)
            case 2: _ = try lengthDelimited()
            case 5: try skip(4)
            case 3: try skipGroup(inner, depth: depth + 1)
            case 4:
                guard inner == number else { throw Malformed() }
                return
            default: throw Malformed()
            }
        }
    }
}

// MARK: - DER

/// Reads DER tag-length-value items with single-byte tags and definite, minimal lengths up to 4 bytes.
struct DERReader {
    struct Malformed: Error {}

    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The contents of the next item, which must have tag `tag`.
    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard offset < bytes.count, bytes[offset] == tag else { throw Malformed() }
        offset += 1
        guard offset < bytes.count else { throw Malformed() }
        let first = bytes[offset]
        offset += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), bytes.count - offset >= count, bytes[offset] != 0 else { throw Malformed() }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[offset])
                offset += 1
            }
            guard length >= 0x80 else { throw Malformed() }
        }
        guard length <= bytes.count - offset else { throw Malformed() }
        let contents = Array(bytes[offset..<(offset + length)])
        offset += length
        return contents
    }

    /// Throws unless everything was read.
    func end() throws {
        guard offset == bytes.count else { throw Malformed() }
    }
}

// MARK: - Little-endian helpers

extension UInt32 {
    init(littleEndian bytes: [UInt8], at offset: Int) {
        self = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}
