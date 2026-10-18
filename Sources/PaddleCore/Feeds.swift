import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One story from a news feed, for the New Tab page.
public struct FeedItem: Codable, Equatable, Sendable, Identifiable {
    public var title: String
    public var link: URL
    public var published: Date?
    /// The feed's own title (the site's name), or its host when it has none.
    public var source: String
    /// The story's picture: the feed's thumbnail or image enclosure, else the first image in its text. https only
    /// (an http address is upgraded).
    public var image: URL?

    public var id: String { link.absoluteString }

    public init(title: String, link: URL, published: Date?, source: String, image: URL? = nil) {
        self.title = title
        self.link = link
        self.published = published
        self.source = source
        self.image = image
    }
}

/// RSS 2.0, RSS 1.0 (RDF) and Atom feeds, read with `XMLParser`: each entry's title, its http(s) link and its date.
/// Entries without a title or a usable link are skipped; titles are plain text (tags and entities resolved, space
/// collapsed). Also finds a page's feed through `<link rel="alternate">`, so a site's address can be added as a feed.
public enum FeedParser {
    /// The feed's title and its items, newest first when they carry dates (undated ones keep feed order, after them).
    /// Nil when `data` isn't a feed (HTML, or XML of another kind).
    public static func parse(_ data: Data, base: URL) -> (title: String, items: [FeedItem])? {
        let delegate = Reader(base: base)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        guard delegate.isFeed else { return nil }
        let source = delegate.feedTitle.isEmpty ? (base.host() ?? base.absoluteString) : delegate.feedTitle
        let items = delegate.entries.compactMap { entry -> FeedItem? in
            guard !entry.title.isEmpty, let link = entry.link else { return nil }
            return FeedItem(title: entry.title, link: link, published: entry.date, source: source, image: entry.image ?? entry.inlineImage)
        }
        return (source, sortedNewestFirst(items))
    }

    /// Newest first; undated items after the dated ones, in their own order.
    public static func sortedNewestFirst(_ items: [FeedItem]) -> [FeedItem] {
        let dated = items.filter { $0.published != nil }.sorted { $0.published! > $1.published! }
        return dated + items.filter { $0.published == nil }
    }

    /// The first RSS or Atom feed an HTML page links to (`<link rel="alternate" type="application/rss+xml" href>`),
    /// resolved against `base`; nil when it links none.
    public static func discover(html: String, base: URL) -> URL? {
        let tagPattern = #"<link\b[^>]*>"#
        guard let tags = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        for match in tags.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard rel.split(separator: " ").contains("alternate"),
                  ["application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/feed+xml"].contains(type),
                  let href = attribute("href", in: tag),
                  let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let r = Range(match.range(at: group), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    /// The first `<img src>` in an entry's HTML, resolved against `base` (https only).
    static func firstImage(inHTML html: String, base: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(match.range, in: html), let src = attribute("src", in: String(html[r])) else { continue }
            if let url = imageURL(decodeEntities(src), base: base) { return url }
        }
        return nil
    }

    /// `raw` as an image address Paddle may fetch: absolute, https (http is upgraded), not a data: URL.
    static func imageURL(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: true) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": components.scheme = "https"
        default: return nil
        }
        return components.url
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Plain text from an RSS title, which may carry escaped HTML: tags dropped, the common entities resolved,
    /// whitespace collapsed.
    static func plainText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text).replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// RFC 822 (RSS), ISO 8601 (Atom, Dublin Core), with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: text) { return d }
        }
        return nil
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Entry {
            var title = ""
            var link: URL?
            var date: Date?
            /// From `media:thumbnail`, `media:content`, an image enclosure or `itunes:image`.
            var image: URL?
            /// The first image in the entry's description or content, used when it has no `image`.
            var inlineImage: URL?
        }

        let base: URL
        var isFeed = false
        var feedTitle = ""
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""
        private var path: [String] = []

        init(base: URL) { self.base = base }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = name.lowercased()
            if path.isEmpty, ["rss", "feed", "rdf:rdf", "rdf"].contains(element) { isFeed = true }
            path.append(element)
            text = ""
            if element == "item" || element == "entry" { current = Entry() }
            if current != nil, current?.image == nil, let src = Self.imageAttribute(element, attributes) {
                current?.image = FeedParser.imageURL(src, base: base)
            }
            // Atom: <link href> (rel absent or "alternate").
            if element == "link", current != nil, let href = attributes["href"] {
                let rel = attributes["rel"]?.lowercased() ?? "alternate"
                if rel == "alternate", current?.link == nil { current?.link = resolve(href) }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            defer {
                if !path.isEmpty { path.removeLast() }
                text = ""
            }
            if current != nil {
                switch element {
                case "title": if current?.title.isEmpty == true { current?.title = FeedParser.plainText(text) }
                case "link": if current?.link == nil { current?.link = resolve(text) }
                case "guid": if current?.link == nil, let url = resolve(text) { current?.link = url }
                case "pubdate", "published", "updated", "dc:date", "date":
                    if current?.date == nil { current?.date = FeedParser.date(text) }
                case "description", "content:encoded", "content", "summary":
                    if current?.inlineImage == nil { current?.inlineImage = FeedParser.firstImage(inHTML: text, base: base) }
                case "item", "entry":
                    if let entry = current { entries.append(entry) }
                    current = nil
                default: break
                }
            } else if element == "title", feedTitle.isEmpty, path.count <= 3 {
                feedTitle = FeedParser.plainText(text)
            }
        }

        /// The picture an element names: `media:thumbnail url`, `media:content url` of an image, an image
        /// `enclosure` (RSS `url`, Atom `link rel="enclosure" href`) or `itunes:image href`.
        static func imageAttribute(_ element: String, _ attributes: [String: String]) -> String? {
            let type = attributes["type"]?.lowercased() ?? ""
            switch element {
            case "media:thumbnail": return attributes["url"]
            case "media:content":
                let medium = attributes["medium"]?.lowercased() ?? ""
                let looksLikeImage = medium == "image" || type.hasPrefix("image/")
                    || (medium.isEmpty && type.isEmpty && attributes["url"].map(isImagePath) == true)
                return looksLikeImage ? attributes["url"] : nil
            case "enclosure": return type.hasPrefix("image/") ? attributes["url"] : nil
            case "link": return attributes["rel"]?.lowercased() == "enclosure" && type.hasPrefix("image/") ? attributes["href"] : nil
            case "itunes:image": return attributes["href"]
            default: return nil
            }
        }

        private static func isImagePath(_ url: String) -> Bool {
            let path = (URL(string: url)?.path() ?? url).lowercased()
            return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"].contains { path.hasSuffix($0) }
        }

        private func resolve(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
    }
}
