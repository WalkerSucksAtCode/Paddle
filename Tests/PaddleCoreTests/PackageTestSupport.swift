import CryptoKit
import Foundation
import Security

/// Builds synthetic ZIP archives and CRX3 packages for the store-install tests. Nothing here touches the network.

extension Data {
    mutating func put16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func put32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

/// A minimal ZIP writer: every entry stored (whatever `method` claims), no data descriptors.
enum TestZip {
    struct Item {
        var name: String
        var data = Data()
        var flags: UInt16 = 0x0800
        var method: UInt16 = 0
        /// Nil: a regular file (0o100644) or, for a name ending in `/`, a folder (0o040755).
        var mode: UInt32?
        var madeBy: UInt16 = 0x031E
        /// Written into the local header instead of `name`.
        var localName: String?
        /// Raw name bytes, overriding `name` in both headers.
        var rawName: [UInt8]?
    }

    static func file(_ name: String, _ text: String = "x") -> Item {
        Item(name: name, data: Data(text.utf8))
    }

    static func make(_ items: [Item]) -> Data {
        var out = Data()
        var central = Data()
        for item in items {
            let offset = UInt32(out.count)
            let name = item.rawName.map { Data($0) } ?? Data(item.name.utf8)
            let localName = item.localName.map { Data($0.utf8) } ?? name
            let crc = crc32(item.data)
            let mode = item.mode ?? (item.name.hasSuffix("/") ? 0o040755 : 0o100644)

            out.put32(0x0403_4B50)
            out.put16(20)
            out.put16(item.flags)
            out.put16(item.method)
            out.put16(0)
            out.put16(0x21)
            out.put32(crc)
            out.put32(UInt32(item.data.count))
            out.put32(UInt32(item.data.count))
            out.put16(UInt16(localName.count))
            out.put16(0)
            out.append(localName)
            out.append(item.data)

            central.put32(0x0201_4B50)
            central.put16(item.madeBy)
            central.put16(20)
            central.put16(item.flags)
            central.put16(item.method)
            central.put16(0)
            central.put16(0x21)
            central.put32(crc)
            central.put32(UInt32(item.data.count))
            central.put32(UInt32(item.data.count))
            central.put16(UInt16(name.count))
            central.put16(0)
            central.put16(0)
            central.put16(0)
            central.put16(0)
            central.put32(mode << 16)
            central.put32(offset)
            central.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.put32(0x0605_4B50)
        out.put16(0)
        out.put16(0)
        out.put16(UInt16(items.count))
        out.put16(UInt16(items.count))
        out.put32(UInt32(central.count))
        out.put32(directoryOffset)
        out.put16(0)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// Protobuf wire-format pieces.
enum TestProto {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func bytes(_ field: UInt64, _ body: Data) -> Data {
        varint(field << 3 | 2) + varint(UInt64(body.count)) + body
    }
}

/// DER pieces, for wrapping a PKCS#1 key in a `SubjectPublicKeyInfo`.
enum TestDER {
    static func item(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        let count = body.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = withUnsafeBytes(of: UInt32(count).bigEndian) { Array($0) }
            while length.first == 0 { length.removeFirst() }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        return out + body
    }

    static let rsaAlgorithm = item(0x30, item(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])) + Data([0x05, 0x00]))

    static func rsaSPKI(pkcs1: Data) -> Data {
        item(0x30, rsaAlgorithm + item(0x03, Data([0]) + pkcs1))
    }
}

/// An RSA key pair made for the test run, with its public key as `SubjectPublicKeyInfo` DER.
final class TestRSAKey: @unchecked Sendable {
    let privateKey: SecKey
    let spki: Data

    init(bits: Int = 2048) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        spki = TestDER.rsaSPKI(pkcs1: pkcs1)
    }

    func sign(_ message: Data) -> Data {
        SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
    }

    static let developer = TestRSAKey()
    static let publisher = TestRSAKey()
    static let stranger = TestRSAKey()
}

/// A CRX3 package builder.
enum TestCRX {
    /// One signer: a key's DER and how it signs.
    struct Signer {
        var spki: Data
        var isRSA: Bool
        var sign: (Data) -> Data

        static func rsa(_ key: TestRSAKey) -> Signer {
            Signer(spki: key.spki, isRSA: true, sign: key.sign)
        }

        static func ecdsa(_ key: P256.Signing.PrivateKey) -> Signer {
            Signer(spki: key.publicKey.derRepresentation, isRSA: false) { try! key.signature(for: $0).derRepresentation }
        }
    }

    static func crxID(_ spki: Data) -> Data {
        Data(SHA256.hash(data: spki).prefix(16))
    }

    static func signedData(crxID: Data) -> Data {
        TestProto.bytes(1, crxID)
    }

    static func message(signedData: Data, zip: Data) -> Data {
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        message.put32(UInt32(signedData.count))
        return message + signedData + zip
    }

    static func proof(key: Data, signature: Data) -> Data {
        TestProto.bytes(1, key) + TestProto.bytes(2, signature)
    }

    /// The header: each signer's proof (field 2 RSA, 3 ECDSA), `extra` raw fields, then `signed_header_data`.
    /// `corrupt` changes one signer's signature (by index) before it is written.
    static func header(signers: [Signer], signedData: Data, zip: Data, extra: Data = Data(), corrupt: Int? = nil) -> Data {
        let message = message(signedData: signedData, zip: zip)
        var header = Data()
        for (index, signer) in signers.enumerated() {
            var signature = signer.sign(message)
            if index == corrupt { signature[signature.startIndex + 10] ^= 0x01 }
            header += TestProto.bytes(signer.isRSA ? 2 : 3, proof(key: signer.spki, signature: signature))
        }
        return header + extra + TestProto.bytes(10000, signedData)
    }

    static func package(header: Data, zip: Data, version: UInt32 = 3, magic: String = "Cr24", headerLength: UInt32? = nil) -> Data {
        var out = Data(magic.utf8)
        out.put32(version)
        out.put32(headerLength ?? UInt32(header.count))
        return out + header + zip
    }

    /// A whole package whose `crx_id` is `idKey`'s (the first signer's, by default).
    static func build(zip: Data, signers: [Signer], idKey: Data? = nil, extra: Data = Data(), corrupt: Int? = nil) -> Data {
        let signed = signedData(crxID: crxID(idKey ?? signers[0].spki))
        return package(header: header(signers: signers, signedData: signed, zip: zip, extra: extra, corrupt: corrupt), zip: zip)
    }

    static let sampleZip = TestZip.make([TestZip.file("manifest.json", #"{"manifest_version":3,"name":"Test","version":"1.0"}"#), TestZip.file("bg.js", "1")])
}
