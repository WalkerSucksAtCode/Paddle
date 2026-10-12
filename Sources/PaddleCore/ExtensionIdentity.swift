import CryptoKit
import Foundation

/// Stable per-install extension ids. The id becomes the extension's `runtime.id` and the host of its
/// `webkit-extension://` URLs. A per-install salt keeps sites from guessing it from a well-known folder name.
public enum ExtensionIdentity {
    public static let scheme = "webkit-extension"

    /// 32 random lowercase hex characters, stored once (in `extension-id-salt`).
    public static func makeSalt() -> String {
        hex(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }

    /// 32 lowercase hex characters: the first 16 bytes of SHA256(`salt` + ":" + `name`).
    public static func identifier(forFolder name: String, salt: String) -> String {
        hex(Array(SHA256.hash(data: Data("\(salt):\(name)".utf8)).prefix(16)))
    }

    /// `webkit-extension://<identifier>/`
    public static func baseURL(for identifier: String) -> URL {
        URL(string: "\(scheme)://\(identifier)/") ?? URL(fileURLWithPath: "/")
    }

    /// The extension id (the host) of a `webkit-extension://` URL; nil for any other URL or nil.
    public static func identifier(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == scheme, let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Whether an extension (or one of its pages) may put `url` in a tab: web pages, about:blank and its own pages.
    /// Not file:, another extension's pages or other schemes; Paddle starts those loads itself, past WebKit's
    /// checks on the extension's origin.
    public static func extensionMayOpen(_ url: URL, extensionID: String?) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        case "about": url.absoluteString.lowercased() == "about:blank"
        case scheme: extensionID != nil && identifier(of: url)?.lowercased() == extensionID?.lowercased()
        default: false
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
