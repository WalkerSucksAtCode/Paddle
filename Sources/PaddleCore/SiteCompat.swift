import Foundation

/// Paddle's built-in site fixes: a user agent for sites that misbehave with WebKit's own. One applies only to a host
/// config.json says nothing about: any `siteUserAgents` or `sitePersonas` entry covering the host wins, `""` and
/// `"none"` included, so either turns a fix off (`PaddleConfig.pageUserAgent(forHost:)`). WebKit's own site quirks
/// (Safari's list) are already on in every Paddle web view; these cover what they don't.
public enum SiteCompat {
    public struct Entry: Sendable, Equatable {
        /// The persona whose user agent the site is sent, at `BrowserVersions.current`, so it never goes stale.
        public let persona: Persona
        /// Why the site needs it, for Settings and the README.
        public let reason: String
    }

    private static let protonSignIn = Entry(
        persona: .firefox,
        reason: "Proton's sign-in picks how to talk to Proton Pass from the browser name; with Safari's it never reaches the extension."
    )

    /// Host suffix (matched as `siteUserAgents` keys are: `"example.com"` also covers its subdomains) to its fix.
    public static let defaults: [String: Entry] = [
        "account.proton.me": protonSignIn,
        "pass.proton.me": protonSignIn,
    ]

    /// The built-in fix for `host` (longest matching host suffix), whatever config.json says.
    public static func entry(forHost host: String) -> Entry? {
        let host = PaddleConfig.normalizedHost(host)
        return defaults
            .filter { key, _ in PaddleConfig.hostKey(key, matches: host) }
            .max { PaddleConfig.hostKeyPrecedes($0.key, $1.key) }?
            .value
    }
}
