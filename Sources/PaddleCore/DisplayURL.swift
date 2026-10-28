import Foundation

/// The text the address field shows for a URL. `https://google.com@evil.com/` loads evil.com, but with the
/// `user:password@` part shown it reads like google.com, so the shown string drops it. The real URL is untouched.
public enum DisplayURL {
    public static func string(_ url: URL) -> String {
        let full = url.absoluteString
        guard full.contains("@"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user != nil || parts.password != nil else { return full }
        parts.user = nil
        parts.password = nil
        return parts.string ?? full
    }
}
