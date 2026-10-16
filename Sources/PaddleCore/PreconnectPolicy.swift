import Foundation

/// Which site to open a connection to before the user commits to a page (`speculativeLoading`), and when not to
/// open it again. One per window.
///
/// Only http(s) origins with a host qualify. The same origin is warmed at most once per `interval`: WebKit keeps
/// an idle connection for about a minute, so a second preconnect sooner does nothing but cost a lookup.
public struct PreconnectPolicy: Sendable {
    public var interval: TimeInterval
    private var recent: [String: Date] = [:]

    public init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    /// `scheme://host[:port]` of `url` when it should be warmed now (and records that it was), else nil.
    public mutating func originToWarm(_ url: URL?, now: Date = Date()) -> URL? {
        guard let origin = Self.origin(of: url) else { return nil }
        let key = origin.absoluteString
        if let last = recent[key], now.timeIntervalSince(last) < interval { return nil }
        recent = recent.filter { now.timeIntervalSince($0.value) < interval }
        recent[key] = now
        return origin
    }

    /// `scheme://host[:port]`, lowercased, for http(s) URLs with a host that could be a site: a dotted name, an IP
    /// literal or localhost. A half-typed word (`exampl`) is not one.
    public static func origin(of url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              host.contains(".") || host.contains(":") || host == "localhost",
              !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }
}
