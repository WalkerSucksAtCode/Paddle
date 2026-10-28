import Foundation

/// Whether a URL host names this machine or a local network, which the control bridge's `open_url` asks about first.
/// A name that only resolves to a private address through DNS can't be told apart here.
public enum PrivateHost {
    public static func isPrivate(_ host: String) -> Bool {
        var host = host.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }

        if host.contains(":") {
            var address = host
            if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
            return isPrivateIPv6(address)
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if let v4 = parseIPv4(host) { return isPrivateIPv4(v4) }
        return false
    }

    /// An IPv4 address in any spelling `inet_aton` takes: one to four parts, each decimal, 0x hex or leading-0 octal,
    /// the last part filling the remaining bytes. Nil if `host` isn't one.
    static func parseIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard let value = parseNumber(String(part)) else { return nil }
            values.append(value)
        }
        let last = values.removeLast()
        var result: UInt64 = 0
        for value in values {
            guard value <= 255 else { return nil }
            result = (result << 8) | value
        }
        let lastBytes = 4 - values.count
        guard last < (UInt64(1) << UInt64(8 * lastBytes)) else { return nil }
        result = (result << UInt64(8 * lastBytes)) | last
        return UInt32(result)
    }

    private static func parseNumber(_ text: String) -> UInt64? {
        guard !text.isEmpty else { return nil }
        var digits = Substring(text)
        var radix = 10
        if digits.hasPrefix("0x") {
            digits = digits.dropFirst(2)
            radix = 16
            if digits.isEmpty { return 0 }
        } else if digits.count > 1, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let value = UInt64(digits, radix: radix)
        guard let value, value <= UInt64(UInt32.max) else { return nil }
        return value
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let a = UInt8(address >> 24), b = UInt8((address >> 16) & 0xFF)
        switch a {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(b)
        case 169: return b == 254
        case 172: return (16...31).contains(b)
        case 192: return b == 168
        default: return false
        }
    }

    private static func isPrivateIPv6(_ text: String) -> Bool {
        var storage = in6_addr()
        guard inet_pton(AF_INET6, text, &storage) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &storage) { Array($0) }
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return true }  // :: and ::1
        if bytes[0] & 0xFE == 0xFC { return true }  // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }  // fe80::/10
        // IPv4-mapped (::ffff:a.b.c.d) and the deprecated IPv4-compatible (::a.b.c.d) forms carry an IPv4 address.
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        let compatible = bytes[0..<12].allSatisfy { $0 == 0 }
        if mapped || compatible {
            let v4 = bytes[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return isPrivateIPv4(v4)
        }
        return false
    }
}
