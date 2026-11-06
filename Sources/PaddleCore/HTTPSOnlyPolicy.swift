import Foundation

/// HTTPS-only mode: which http:// navigations Paddle loads over https:// instead.
public enum HTTPSOnlyPolicy {
    /// The https form of `url` (port 80 dropped, everything else kept), or nil when no upgrade applies: the mode is
    /// off, the URL isn't http, its host is empty or local, the host (also without `www.`) is in `sessionExceptions`
    /// (normalized hosts), or the site's settings allow http.
    public static func upgrade(
        _ url: URL, enabled: Bool, siteAllowsHTTP: Bool, sessionExceptions: Set<String>
    ) -> URL? {
        guard enabled, !siteAllowsHTTP, url.scheme?.lowercased() == "http",
              let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else { return nil }
        let host = PaddleConfig.normalizedHost(rawHost)
        guard !isLocal(host: host) else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if sessionExceptions.contains(host) || sessionExceptions.contains(bare) || sessionExceptions.contains("www." + bare) {
            return nil
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    /// True for hosts that never leave the machine or network: localhost, `.local`, `.home.arpa`, `.internal`,
    /// single-label names, loopback, private and link-local IP addresses in any `inet_aton` spelling (`127.1`,
    /// `0x7f.1`, octal), and `.onion` services, which never carry a cert for their own name so an upgrade only
    /// breaks them (Chrome and Firefox exempt them too).
    public static func isLocal(host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".home.arpa") || host.hasSuffix(".internal") || host.hasSuffix(".onion") { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        if let v4 = PrivateHost.parseIPv4(host) {
            let n = [UInt8((v4 >> 24) & 0xFF), UInt8((v4 >> 16) & 0xFF)]
            return n[0] == 0 || n[0] == 127 || n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1]))
                || (n[0] == 192 && n[1] == 168) || (n[0] == 169 && n[1] == 254)
        }
        return !host.contains(".")
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        return withUnsafeBytes(of: address) { bytes in
            let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            return loopback || (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)
        }
    }
}
