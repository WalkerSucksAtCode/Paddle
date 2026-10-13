import Foundation

/// Firefox's `.mozlz4` / `.jsonlz4` files (`search.json.mozlz4`, bookmark backups): the 8 bytes `mozLz40\0`, the
/// decompressed size as a little-endian UInt32, then one LZ4 block (not the LZ4 frame format).
///
/// The decoder trusts nothing in the file: every length and offset is checked against the input and against the
/// declared size, and the output never grows past `maxOutput`.
public enum MozLZ4 {
    public enum Error: Swift.Error, Equatable, Sendable {
        case notMozLZ4
        case tooLarge(declared: Int)
        case corrupt(String)
    }

    public static let magic: [UInt8] = Array("mozLz40\0".utf8)
    /// Largest output accepted: a search-engine file is a few tens of kilobytes.
    public static let defaultMaxOutput = 16 * 1024 * 1024

    public static func decompress(_ file: Data, maxOutput: Int = defaultMaxOutput) throws -> Data {
        let bytes = [UInt8](file)
        guard bytes.count >= 12, Array(bytes[0..<8]) == magic else { throw Error.notMozLZ4 }
        let declared = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        guard declared <= maxOutput else { throw Error.tooLarge(declared: declared) }
        let output = try decodeBlock(bytes, from: 12, expecting: declared)
        return Data(output)
    }

    /// Decodes one LZ4 block that must produce exactly `size` bytes.
    static func decodeBlock(_ input: [UInt8], from start: Int, expecting size: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(size)
        var i = start
        let end = input.count

        /// A length continued over extra bytes: 255 means "add the next byte too".
        func extendedLength(_ base: Int) throws -> Int {
            var length = base
            while true {
                guard i < end else { throw Error.corrupt("length runs past the end of the data") }
                let byte = Int(input[i])
                i += 1
                length += byte
                guard length <= size else { throw Error.corrupt("length is larger than the declared size") }
                if byte != 255 { return length }
            }
        }

        while i < end {
            let token = Int(input[i])
            i += 1

            var literals = token >> 4
            if literals == 15 { literals = try extendedLength(literals) }
            guard literals <= end - i else { throw Error.corrupt("literals run past the end of the data") }
            guard literals <= size - output.count else { throw Error.corrupt("output is larger than the declared size") }
            output.append(contentsOf: input[i..<i + literals])
            i += literals

            // The last sequence holds literals only.
            if i == end { break }

            guard end - i >= 2 else { throw Error.corrupt("match offset is cut off") }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= output.count else { throw Error.corrupt("match offset points before the start") }

            var matchLength = token & 15
            if matchLength == 15 { matchLength = try extendedLength(matchLength) }
            matchLength += 4
            guard matchLength <= size - output.count else { throw Error.corrupt("output is larger than the declared size") }
            // Byte by byte: a match may overlap the bytes it is writing (offset 1 repeats one byte).
            var from = output.count - offset
            for _ in 0..<matchLength {
                output.append(output[from])
                from += 1
            }
        }
        guard output.count == size else { throw Error.corrupt("decoded \(output.count) bytes, expected \(size)") }
        return output
    }
}
