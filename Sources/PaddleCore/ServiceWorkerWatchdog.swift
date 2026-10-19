import Foundation

/// When Paddle stops WebKit's service workers because one is holding a page's main request.
///
/// A site's service worker sees every navigation in its scope before the network does. A stuck one (its thread busy,
/// or a `respondWith` promise that never settles) leaves the page blank until WebKit gives up on it, then the network
/// answers at once: Reddit's worker held its front page 37 s that way after the Mac woke. Stopping the workers makes
/// WebKit send the held request to the network; the site's worker starts again on its next request.
///
/// Paddle steps in only when the main frame has had no response for `patience`, the page's site has a worker
/// registered (a slow server alone is left alone), and no stop happened in the last `cooldown`, so a site whose worker
/// is always slow can't stop everyone's workers on every page.
public struct ServiceWorkerWatchdog: Sendable {
    /// How long a main-frame navigation waits for its response before Paddle looks for a stuck worker.
    public static let patience: TimeInterval = 6
    public var cooldown: TimeInterval
    private var lastStop: Date?

    public init(cooldown: TimeInterval = 30) {
        self.cooldown = cooldown
    }

    /// Whether to stop service workers for a navigation to `host` that is still waiting, given the sites WebKit lists
    /// with worker registrations (record display names: registrable domains or bare hosts). Records the stop when yes.
    public mutating func shouldStop(host: String, registeredSites: Set<String>, now: Date = Date()) -> Bool {
        guard Self.hasRegistration(for: host, in: registeredSites) else { return false }
        if let lastStop, now.timeIntervalSince(lastStop) < cooldown { return false }
        lastStop = now
        return true
    }

    /// Whether one of `registeredSites` is `host` or a parent domain of it (`reddit.com` covers `www.reddit.com`).
    public static func hasRegistration(for host: String, in registeredSites: Set<String>) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        return registeredSites.contains { site in
            let site = site.lowercased()
            return !site.isEmpty && (host == site || host.hasSuffix("." + site))
        }
    }
}
