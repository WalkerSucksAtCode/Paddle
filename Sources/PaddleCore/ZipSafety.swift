import Foundation

/// ZIP central directory before unpack, and the unpacked folder after. Refused: ZIP64, split archives,
/// encryption, compression other than stored/deflate, links and special files, names that could land
/// outside the destination or collide on a case-insensitive disk, and local headers that disagree with
/// the central directory.
public enum ZipSafety {
    /// One file or folder in the archive.
    public struct Entry: Sendable, Equatable {
        /// The path inside the archive, without the trailing `/` a folder entry has.
        public let name: String
        public let isDirectory: Bool
        public let uncompressedSize: UInt64
        public let crc32: UInt32

        public init(name: String, isDirectory: Bool, uncompressedSize: UInt64, crc32: UInt32) {
            self.name = name
            self.isDirectory = isDirectory
            self.uncompressedSize = uncompressedSize
            self.crc32 = crc32
        }

        /// Under `__MACOSX/`: Finder's resource-fork copies. Allowed; `ditto` may turn them into extended attributes
        /// instead of files.
        public var isMacMetadata: Bool { name == "__MACOSX" || name.hasPrefix("__MACOSX/") }
    }

    /// The caps. Tests pass smaller ones.
    struct Limits: Sendable {
        var maxEntries = 20_000
        var maxTotalUncompressedSize: UInt64 = 500 * 1024 * 1024
    }

    public enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// No end-of-central-directory record.
        case notZip
        case zip64
        case multiDisk
        /// Counts, sizes or offsets that don't add up, or a central directory or local header cut short.
        case damaged(String)
        case encrypted(String)
        case unsupportedCompression(String, method: UInt16)
        /// Not valid UTF-8, absolute, a backslash, NUL or control character, an empty, `.` or `..` component, or
        /// too long.
        case unsafeName(String)
        case symlink(String)
        /// Neither a regular file nor a folder (device, FIFO, socket), or a type that disagrees with the name.
        case specialFile(String)
        /// Two entries that name the same path on a case-insensitive disk, or a file that is also a folder.
        case duplicate(String)
        case tooManyEntries
        case tooLarge
        /// The unpacked folder has something the archive didn't list, lacks something it did, or a size differs.
        case unpackedMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .notZip: "not a ZIP archive"
            case .zip64: "ZIP64 archives aren't supported"
            case .multiDisk: "split archives aren't supported"
            case .damaged(let why): "the archive is damaged (\(why))"
            case .encrypted(let name): "encrypted entry: \(name)"
            case .unsupportedCompression(let name, let method): "unsupported compression (method \(method)): \(name)"
            case .unsafeName(let name): "unsafe file name: \(name)"
            case .symlink(let name): "the archive contains a link: \(name)"
            case .specialFile(let name): "not a regular file or folder: \(name)"
            case .duplicate(let name): "two entries with the same name: \(name)"
            case .tooManyEntries: "the archive has more than 20,000 entries"
            case .tooLarge: "the archive unpacks to more than 500 MB"
            case .unpackedMismatch(let path): "the unpacked files don't match the archive: \(path)"
            }
        }
    }

    /// The entries of the ZIP in `data`, in central-directory order, after every check passed.
    public static func entries(in data: Data) throws -> [Entry] {
        try entries(in: data, limits: Limits())
    }

    static func entries(in data: Data, limits: Limits) throws -> [Entry] {
        let bytes = [UInt8](data)
        let end = try endRecord(bytes)
        guard end.entryCount <= limits.maxEntries else { throw Refusal.tooManyEntries }

        var entries: [Entry] = []
        var keys: [String: Bool] = [:]  // folded path → is a folder
        var spans: [(start: Int, end: Int)] = []
        var total: UInt64 = 0
        var offset = end.directoryOffset
        let directoryEnd = end.directoryOffset + end.directorySize

        for _ in 0..<end.entryCount {
            guard directoryEnd - offset >= 46 else { throw Refusal.damaged("central directory cut short") }
            guard u32(bytes, offset) == 0x0201_4B50 else { throw Refusal.damaged("bad central directory entry") }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let crc = u32(bytes, offset + 16)
            let compressedSize = u32(bytes, offset + 20)
            let uncompressedSize = u32(bytes, offset + 24)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let diskStart = u16(bytes, offset + 34)
            let external = u32(bytes, offset + 38)
            let localOffset = u32(bytes, offset + 42)
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard directoryEnd - offset >= recordLength else { throw Refusal.damaged("central directory cut short") }
            let rawName = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            offset += recordLength

            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF,
                  diskStart != 0xFFFF else { throw Refusal.zip64 }
            guard diskStart == 0 else { throw Refusal.multiDisk }
            guard let decoded = String(validating: rawName, as: UTF8.self) else {
                throw Refusal.unsafeName(String(decoding: rawName, as: UTF8.self))
            }
            // Bit 0: encrypted; bit 6: strong encryption; bit 13: masked local headers.
            guard flags & 0x2041 == 0 else { throw Refusal.encrypted(decoded) }
            guard method == 0 || method == 8 else { throw Refusal.unsupportedCompression(decoded, method: method) }

            let isDirectory = decoded.hasSuffix("/")
            let name = isDirectory ? String(decoded.dropLast()) : decoded
            try checkName(name, raw: decoded)
            try checkType(external: external, isDirectory: isDirectory, name: decoded)
            if isDirectory, uncompressedSize != 0 {
                throw Refusal.damaged("folder with contents: \(decoded)")
            }
            if method == 0, compressedSize != uncompressedSize { throw Refusal.damaged("stored sizes differ: \(decoded)") }

            // The local header must sit before the central directory and agree with it.
            let local = Int(localOffset)
            guard local <= end.directoryOffset, end.directoryOffset - local >= 30, u32(bytes, local) == 0x0403_4B50 else {
                throw Refusal.damaged("bad local header: \(decoded)")
            }
            let localFlags = u16(bytes, local + 6)
            let localMethod = u16(bytes, local + 8)
            let localNameLength = Int(u16(bytes, local + 26))
            let localExtraLength = Int(u16(bytes, local + 28))
            let dataStart = local + 30 + localNameLength + localExtraLength
            guard dataStart <= end.directoryOffset, end.directoryOffset - dataStart >= Int(compressedSize) else {
                throw Refusal.damaged("entry runs past the archive: \(decoded)")
            }
            guard bytes[(local + 30)..<(local + 30 + localNameLength)].elementsEqual(rawName) else {
                throw Refusal.damaged("local name differs: \(decoded)")
            }
            guard localFlags & 0x2041 == 0 else { throw Refusal.encrypted(decoded) }
            guard localMethod == method else { throw Refusal.damaged("local method differs: \(decoded)") }
            spans.append((local, dataStart + Int(compressedSize)))

            // Names collide on APFS case- and normalization-insensitively; a file can't also be a folder.
            let key = folded(name)
            if keys[key] != nil { throw Refusal.duplicate(name) }
            keys[key] = isDirectory

            total += UInt64(uncompressedSize)
            guard total <= limits.maxTotalUncompressedSize else { throw Refusal.tooLarge }
            entries.append(Entry(name: name, isDirectory: isDirectory, uncompressedSize: UInt64(uncompressedSize), crc32: crc))
        }
        guard offset == directoryEnd else { throw Refusal.damaged("central directory size doesn't match its entries") }

        // A file can't also be the folder another entry sits in.
        for entry in entries {
            var parent = ""
            for component in entry.name.split(separator: "/").dropLast() {
                parent += parent.isEmpty ? String(component) : "/" + component
                if keys[folded(parent)] == false { throw Refusal.duplicate(parent) }
            }
        }

        // Entries must not share bytes (overlapping entries are how quine ZIP bombs work).
        let sorted = spans.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.start < a.end {
            throw Refusal.damaged("entries overlap")
        }
        return entries
    }

    /// Checks that `folder`, where the archive was unpacked, holds exactly `entries`: the same regular files with
    /// the same sizes and the same folders (including the parents of every entry), nothing else, and no links.
    /// `__MACOSX` entries may be missing, since `ditto` can turn them into extended attributes.
    public static func verifyUnpacked(_ folder: URL, matches entries: [Entry], fileManager: FileManager = .default) throws {
        let root = folder.path
        guard (try? fileManager.attributesOfItem(atPath: root)[.type] as? FileAttributeType) == .typeDirectory else {
            throw Refusal.unpackedMismatch("the folder itself")
        }
        var files: [String: UInt64] = [:]
        var directories = Set<String>()
        var optional = Set<String>()
        for entry in entries {
            let name = entry.name.precomposedStringWithCanonicalMapping
            if entry.isDirectory { directories.insert(name) } else { files[name] = entry.uncompressedSize }
            if entry.isMacMetadata { optional.insert(name) }
            var parent = ""
            for component in name.split(separator: "/").dropLast() {
                parent += parent.isEmpty ? String(component) : "/" + component
                directories.insert(parent)
                if entry.isMacMetadata { optional.insert(parent) }
            }
        }

        guard let enumerator = fileManager.enumerator(atPath: root) else { throw Refusal.unpackedMismatch("the folder itself") }
        var seen = Set<String>()
        while let next = enumerator.nextObject() as? String {
            let path = next.precomposedStringWithCanonicalMapping
            let attributes = enumerator.fileAttributes ?? [:]
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                guard directories.contains(path) else { throw Refusal.unpackedMismatch(path) }
            case .typeRegular?:
                guard let size = files[path], (attributes[.size] as? NSNumber)?.uint64Value == size else {
                    throw Refusal.unpackedMismatch(path)
                }
            default:
                throw Refusal.unpackedMismatch(path)
            }
            seen.insert(path)
        }
        for path in Set(files.keys).union(directories) where !seen.contains(path) && !optional.contains(path) {
            throw Refusal.unpackedMismatch(path)
        }
    }

    // MARK: - Pieces

    struct EndRecord {
        var entryCount: Int
        var directorySize: Int
        var directoryOffset: Int
    }

    /// The end-of-central-directory record: searched for from the end over the last 64 KB + 22 bytes, and it must
    /// end exactly at the end of the data (its comment included).
    static func endRecord(_ bytes: [UInt8]) throws -> EndRecord {
        guard bytes.count >= 22 else { throw Refusal.notZip }
        let lowest = max(0, bytes.count - (0xFFFF + 22))
        var position = bytes.count - 22
        var found: Int?
        while position >= lowest {
            if u32(bytes, position) == 0x0605_4B50, position + 22 + Int(u16(bytes, position + 20)) == bytes.count {
                found = position
                break
            }
            position -= 1
        }
        guard let eocd = found else { throw Refusal.notZip }
        if eocd >= 20, u32(bytes, eocd - 20) == 0x0706_4B50 { throw Refusal.zip64 }
        let disk = u16(bytes, eocd + 4)
        let directoryDisk = u16(bytes, eocd + 6)
        let entriesHere = u16(bytes, eocd + 8)
        let entriesTotal = u16(bytes, eocd + 10)
        let size = u32(bytes, eocd + 12)
        let offset = u32(bytes, eocd + 16)
        guard disk != 0xFFFF, directoryDisk != 0xFFFF, entriesHere != 0xFFFF, entriesTotal != 0xFFFF,
              size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Refusal.zip64 }
        guard disk == 0, directoryDisk == 0 else { throw Refusal.multiDisk }
        guard entriesHere == entriesTotal else { throw Refusal.damaged("entry counts differ") }
        guard Int(offset) + Int(size) == eocd else { throw Refusal.damaged("central directory is not where the archive says") }
        return EndRecord(entryCount: Int(entriesTotal), directorySize: Int(size), directoryOffset: Int(offset))
    }

    /// Refuses names that could land outside the destination or confuse the disk.
    static func checkName(_ name: String, raw: String) throws {
        guard !name.isEmpty, name.utf8.count <= 1024, !raw.hasPrefix("/"), !raw.contains("\\") else {
            throw Refusal.unsafeName(raw)
        }
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw Refusal.unsafeName(raw) }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != "..", component.utf8.count <= 255 else {
                throw Refusal.unsafeName(raw)
            }
        }
    }

    /// Unix mode bits (upper 16 bits of the external attributes), whatever system made the entry: a link or
    /// special file is refused, and a type must agree with the trailing `/`.
    static func checkType(external: UInt32, isDirectory: Bool, name: String) throws {
        let mode = external >> 16
        guard mode != 0 else { return }
        switch mode & 0o170000 {
        case 0: return
        case 0o100000: if isDirectory { throw Refusal.specialFile(name) }
        case 0o040000: if !isDirectory { throw Refusal.specialFile(name) }
        case 0o120000: throw Refusal.symlink(name)
        default: throw Refusal.specialFile(name)
        }
    }

    /// The key two names collide under on APFS.
    static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes, at: offset)
    }
}
