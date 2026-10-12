import Foundation

/// View > View Source: the page's current DOM as plain, escaped text. It is what the page looks like now (after
/// its scripts ran), read from the open page; Paddle does not fetch the address again, so nothing is sent to the
/// site a second time, with or without cookies.
public enum ViewSource {
    /// `Source of example.com`; the whole address for pages without a host (file:, data:).
    public static func title(for url: URL?) -> String {
        guard let url else { return "Source" }
        if let host = url.host(), !host.isEmpty { return "Source of \(host)" }
        return "Source of \(url.absoluteString.prefix(80))"
    }

    /// A self-contained page showing `source` as monospaced text. Its content security policy allows no scripts,
    /// frames, images or network loads; only its own inline style.
    public static func page(source: String, url: URL?) -> String {
        let address = url?.absoluteString ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(HTMLText.escape(title(for: url)))</title>
        <style>
          body { margin: 0; color: CanvasText; background: Canvas; }
          header { font: 12px -apple-system, sans-serif; padding: 8px 12px; color: GrayText;
                   border-bottom: 1px solid color-mix(in srgb, GrayText 30%, transparent); overflow-wrap: anywhere; }
          pre { font: 12px ui-monospace, Menlo, monospace; margin: 0; padding: 12px;
                white-space: pre-wrap; overflow-wrap: anywhere; tab-size: 4; }
        </style></head>
        <body><header>Current DOM of \(HTMLText.escape(address)), as the page shows it now (after its scripts ran). \
        Not re-downloaded from the site.</header>
        <pre>\(HTMLText.escape(source))</pre></body></html>
        """
    }
}

public enum HTMLText {
    /// Escapes text for HTML element content and quoted attribute values.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\0": out += "\u{FFFD}"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }
}
