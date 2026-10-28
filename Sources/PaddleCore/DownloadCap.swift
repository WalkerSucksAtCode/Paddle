import Foundation

/// Counts the bytes of a streamed download against a limit, so the download can be aborted as soon as it passes the
/// cap instead of after the whole body sits in memory.
public struct DownloadCap: Sendable, Equatable {
    public let limit: Int
    public private(set) var received = 0

    public init(limit: Int) { self.limit = limit }

    /// True when the server announced a body over the limit (a negative or unknown length is not an announcement).
    public func announcedTooLarge(_ expectedLength: Int64) -> Bool {
        expectedLength > Int64(limit)
    }

    /// Records `count` more bytes; false once the total is over the limit (the caller aborts).
    public mutating func add(_ count: Int) -> Bool {
        received += count
        return received <= limit
    }

    public static let feedBytes = 2 * 1_024 * 1_024
    public static let feedImageBytes = 3 * 1_024 * 1_024
}

/// Which hosts a feed's picture may be fetched from: not this machine and not the local network, so a feed cannot
/// make Paddle probe devices behind the router.
public enum FeedImagePolicy {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return !isLocalOrPrivate(host: host)
    }

    public static func isLocalOrPrivate(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if host.contains(":") { return isPrivateIPv6(host) }
        if let octets = ipv4(host) { return isPrivateIPv4(octets) }
        // A bare name without a dot resolves through the local network's search domains.
        if !host.contains(".") { return true }
        // Other numeric spellings of an address (0x7f.1, 2130706433, 017700000001) are not trusted.
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" || ("a"..."f").contains($0) }),
           host.first?.isNumber == true, host.split(separator: ".").allSatisfy({ $0.first?.isNumber == true }) { return true }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part), n <= 255 else { return nil }
            out.append(n)
        }
        return out
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        case (192, 0) where o[2] == 0: return true
        case (224..., _): return true
        default: return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        var h = host
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        if h == "::" || h == "::1" { return true }
        if h.hasPrefix("::ffff:") {
            let tail = String(h.dropFirst(7))
            if let octets = ipv4(tail) { return isPrivateIPv4(octets) }
            return true  // hex form of a mapped address: refuse
        }
        guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first, let value = Int(first.isEmpty ? "0" : first, radix: 16)
        else { return true }
        if value & 0xfe00 == 0xfc00 { return true }  // fc00::/7 unique local
        if value & 0xffc0 == 0xfe80 { return true }  // fe80::/10 link local
        if value & 0xff00 == 0xff00 { return true }  // multicast
        return false
    }
}
