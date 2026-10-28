import Foundation

/// Whether a URL handed to Paddle by another app (Finder, `open`, a script) may load. In-app loads (address bar,
/// bookmarks, links) do not go through this.
///
/// Allowed: http, https, about, and `file:` only for the document types Info.plist declares
/// (`public.html`, `public.xhtml`, `com.apple.webarchive`: html, htm, xhtml, xht, xhtm, webarchive).
public enum OpenableURL {
    public static let fileExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "xhtm", "webarchive"]

    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host(percentEncoded: false)?.isEmpty == false
        case "about":
            return true
        case "file":
            guard url.isFileURL, !url.hasDirectoryPath else { return false }
            if let host = url.host(percentEncoded: false), !host.isEmpty, host.lowercased() != "localhost" { return false }
            return fileExtensions.contains(url.pathExtension.lowercased())
        default:
            return false
        }
    }
}
