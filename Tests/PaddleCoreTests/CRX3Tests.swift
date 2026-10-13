import CryptoKit
import Foundation
@testable import PaddleCore
import Testing

struct CRX3Tests {
    private let zip = TestCRX.sampleZip
    private let developer = TestRSAKey.developer
    private let publisher = TestRSAKey.publisher
    private var developerID: String { ExtensionIdentity.chromeID(publicKeyDER: developer.spki) }
    private var publisherHash: Data { Data(SHA256.hash(data: publisher.spki)) }

    @Test func publisherKeyHashIsGooglesKey() {
        let hex = CRX3.webStorePublisherKeyHash.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf")
    }

    @Test func validPackageVerifiesWithoutPublisher() throws {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        let verified = try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [])
        #expect(verified.id == developerID)
        #expect(verified.developerPublicKey == developer.spki)
        #expect(verified.zip == zip)
        #expect(crx.subdata(in: verified.zipRange) == zip)
        #expect(try ZipSafety.entries(in: verified.zip).map(\.name) == ["manifest.json", "bg.js"])
    }

    @Test func validPackageVerifiesWithPublisherAndECDSA() throws {
        let ecdsa = P256.Signing.PrivateKey()
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer), .rsa(publisher), .ecdsa(ecdsa)])
        let verified = try CRX3.verify(crx, expectedID: developerID.uppercased(), publisherKeyHashes: [publisherHash])
        #expect(verified.id == developerID)
    }

    @Test func ecdsaDeveloperKeyVerifies() throws {
        let ecdsa = P256.Signing.PrivateKey()
        let crx = TestCRX.build(zip: zip, signers: [.ecdsa(ecdsa)])
        let id = ExtensionIdentity.chromeID(publicKeyDER: ecdsa.publicKey.derRepresentation)
        #expect(try CRX3.verify(crx, expectedID: id, publisherKeyHashes: []).developerPublicKey == ecdsa.publicKey.derRepresentation)
    }

    @Test func slicedInputVerifies() throws {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        let padded = Data([1, 2, 3]) + crx
        let verified = try CRX3.verify(padded[3...], expectedID: developerID, publisherKeyHashes: [])
        #expect(verified.zip == zip)
    }

    @Test func unknownFieldsOfEveryWireTypeAreSkipped() throws {
        var extra = Data()
        extra += TestProto.varint(5 << 3 | 0)
        extra += TestProto.varint(300)
        extra += TestProto.varint(6 << 3 | 1)
        extra += Data(repeating: 7, count: 8)
        extra += TestProto.varint(7 << 3 | 5)
        extra += Data(repeating: 7, count: 4)
        extra += TestProto.bytes(8, Data("skip me".utf8))
        // A group holding a varint field.
        extra += TestProto.varint(9 << 3 | 3)
        extra += TestProto.varint(1 << 3 | 0)
        extra += TestProto.varint(1)
        extra += TestProto.varint(9 << 3 | 4)
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)], extra: extra)
        #expect(try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: []).id == developerID)
    }

    @Test func flippedZipByteFails() {
        var crx = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        crx[crx.count - 30] ^= 0x01
        #expect(throws: CRX3.VerifyError.badSignature) { try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: []) }
    }

    @Test func flippedSignatureByteFails() {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)], corrupt: 0)
        #expect(throws: CRX3.VerifyError.badSignature) { try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: []) }
        let ecdsa = P256.Signing.PrivateKey()
        let bad = TestCRX.build(zip: zip, signers: [.rsa(developer), .ecdsa(ecdsa)], corrupt: 1)
        #expect(throws: CRX3.VerifyError.badSignature) { try CRX3.verify(bad, expectedID: developerID, publisherKeyHashes: []) }
    }

    @Test func wrongExpectedIDFails() {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        let other = ExtensionIdentity.chromeID(publicKeyDER: publisher.spki)
        #expect(throws: CRX3.VerifyError.wrongExtension) { try CRX3.verify(crx, expectedID: other, publisherKeyHashes: []) }
        #expect(throws: CRX3.VerifyError.wrongExtension) { try CRX3.verify(crx, expectedID: "", publisherKeyHashes: []) }
    }

    @Test func crxIDMatchingNoProofFails() {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)], idKey: TestRSAKey.stranger.spki)
        let strangerID = ExtensionIdentity.chromeID(publicKeyDER: TestRSAKey.stranger.spki)
        #expect(throws: CRX3.VerifyError.noDeveloperSignature) { try CRX3.verify(crx, expectedID: strangerID, publisherKeyHashes: []) }
    }

    @Test func requiredPublisherMissingFails() {
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        #expect(throws: CRX3.VerifyError.missingStoreSignature) {
            try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [publisherHash])
        }
        #expect(throws: CRX3.VerifyError.missingStoreSignature) {
            try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [CRX3.webStorePublisherKeyHash])
        }
    }

    @Test func publisherKeyOnlyCountsAsRSA() {
        let ecdsa = P256.Signing.PrivateKey()
        let ecdsaHash = Data(SHA256.hash(data: ecdsa.publicKey.derRepresentation))
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer), .ecdsa(ecdsa)])
        #expect(throws: CRX3.VerifyError.missingStoreSignature) {
            try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [ecdsaHash])
        }
    }

    @Test func extraInvalidProofFailsThePackage() {
        let stranger = TestRSAKey.stranger
        let wrongMessage = TestCRX.Signer(spki: stranger.spki, isRSA: true) { _ in stranger.sign(Data("something else".utf8)) }
        let crx = TestCRX.build(zip: zip, signers: [.rsa(developer), .rsa(publisher), wrongMessage])
        #expect(throws: CRX3.VerifyError.badSignature) {
            try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [publisherHash])
        }
    }

    @Test func structuralRefusals() {
        let good = TestCRX.build(zip: zip, signers: [.rsa(developer)])
        let headerLength = Int(good[8]) | Int(good[9]) << 8
        func check(_ data: Data, _ error: CRX3.VerifyError, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(throws: error, sourceLocation: sourceLocation) { try CRX3.verify(data, expectedID: developerID, publisherKeyHashes: []) }
        }
        check(good.prefix(12 + headerLength - 5), .truncated)
        check(good.prefix(10), .truncated)
        check(Data(), .notCRX3)
        check(Data("Cr2".utf8), .notCRX3)
        check(Data("PK\u{3}\u{4}".utf8) + good.dropFirst(4), .notCRX3)
        let header = good.subdata(in: 12..<(12 + headerLength))
        check(TestCRX.package(header: header, zip: zip, version: 2), .unsupportedVersion(2))
        check(TestCRX.package(header: header, zip: zip, headerLength: UInt32(CRX3.maxHeaderSize + 1)), .headerTooLarge)
        check(TestCRX.package(header: header, zip: zip, headerLength: UInt32.max), .headerTooLarge)
    }

    @Test func malformedHeadersAreRefused() {
        let signed = TestCRX.signedData(crxID: TestCRX.crxID(developer.spki))
        let goodHeader = TestCRX.header(signers: [.rsa(developer)], signedData: signed, zip: zip)
        func check(_ header: Data, sourceLocation: SourceLocation = #_sourceLocation) {
            let crx = TestCRX.package(header: header, zip: zip)
            #expect(throws: CRX3.VerifyError.malformedHeader, sourceLocation: sourceLocation) {
                try CRX3.verify(crx, expectedID: developerID, publisherKeyHashes: [])
            }
        }
        // An 11-byte varint, a 10-byte varint with a high last byte, a length past the end, field 0, wire type 7.
        check(goodHeader + TestProto.varint(5 << 3) + Data(repeating: 0xFF, count: 10) + Data([0]))
        check(goodHeader + TestProto.varint(5 << 3) + Data(repeating: 0xFF, count: 9) + Data([2]))
        check(goodHeader + TestProto.varint(8 << 3 | 2) + TestProto.varint(1_000))
        check(goodHeader + Data([0x00, 0x01]))
        check(goodHeader + TestProto.varint(5 << 3 | 7))
        // An unterminated group and a mismatched group end.
        check(goodHeader + TestProto.varint(9 << 3 | 3))
        check(goodHeader + TestProto.varint(9 << 3 | 3) + TestProto.varint(8 << 3 | 4))
        // No signed_header_data, two of them, a crx_id that isn't 16 bytes.
        check(goodHeader.prefix(goodHeader.count - TestProto.bytes(10000, signed).count))
        check(goodHeader + TestProto.bytes(10000, signed))
        check(TestCRX.header(signers: [.rsa(developer)], signedData: TestProto.bytes(1, Data(count: 15)), zip: zip))
        // A proof without a signature.
        check(TestProto.bytes(2, TestProto.bytes(1, developer.spki)) + TestProto.bytes(10000, signed))
    }

    @Test func keysThatArentRSAOrP256AreRefused() {
        // An RSA proof whose key is a P-256 SubjectPublicKeyInfo.
        let ecdsa = P256.Signing.PrivateKey()
        let misfiled = TestCRX.Signer(spki: ecdsa.publicKey.derRepresentation, isRSA: true) { try! ecdsa.signature(for: $0).derRepresentation }
        let crx = TestCRX.build(zip: zip, signers: [misfiled])
        let id = ExtensionIdentity.chromeID(publicKeyDER: ecdsa.publicKey.derRepresentation)
        #expect(throws: CRX3.VerifyError.unsupportedKey) { try CRX3.verify(crx, expectedID: id, publisherKeyHashes: []) }
    }

    @Test func rsaSPKIParsing() throws {
        let pkcs1 = try CRX3.rsaPublicKey(fromSPKI: [UInt8](developer.spki))
        #expect(TestDER.rsaSPKI(pkcs1: Data(pkcs1)) == developer.spki)
        #expect(throws: (any Error).self) { try CRX3.rsaPublicKey(fromSPKI: [UInt8](developer.spki) + [0]) }
        #expect(throws: (any Error).self) { try CRX3.rsaPublicKey(fromSPKI: [UInt8](developer.spki.dropLast())) }
        #expect(throws: (any Error).self) { try CRX3.rsaPublicKey(fromSPKI: [UInt8](P256.Signing.PrivateKey().publicKey.derRepresentation)) }
    }

    @Test func tooLargeIsRefusedBeforeParsing() {
        let huge = Data("Cr24".utf8) + Data(count: CRX3.maxFileSize)
        #expect(throws: CRX3.VerifyError.tooLarge) { try CRX3.verify(huge, expectedID: developerID, publisherKeyHashes: []) }
    }

    @Test func errorsReadPlainly() {
        #expect(CRX3.VerifyError.notCRX3.localizedDescription == "not a CRX3 package")
        #expect(CRX3.VerifyError.badSignature.localizedDescription == "signature does not verify")
        #expect(CRX3.VerifyError.wrongExtension.localizedDescription == "the package is for a different extension")
        #expect(CRX3.VerifyError.missingStoreSignature.localizedDescription == "missing the Chrome Web Store signature")
    }
}
