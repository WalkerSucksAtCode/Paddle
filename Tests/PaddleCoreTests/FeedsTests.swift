import Foundation
@testable import PaddleCore
import Testing

struct FeedsTests {
    private let base = URL(string: "https://example.com/feed")!

    @Test func readsRSS2NewestFirst() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Example News</title>
        <item><title>Older &amp; wiser</title><link>https://example.com/a</link><pubDate>Mon, 12 Oct 2026 09:00:00 +0000</pubDate></item>
        <item><title><![CDATA[Newer <b>story</b>]]></title><link>/b</link><pubDate>Tue, 13 Oct 2026 09:00:00 GMT</pubDate></item>
        <item><title>No link</title></item>
        <item><title>Script link</title><link>javascript:alert(1)</link></item>
        </channel></rss>
        """
        let feed = try #require(FeedParser.parse(Data(xml.utf8), base: base))
        #expect(feed.title == "Example News")
        #expect(feed.items.map(\.title) == ["Newer story", "Older & wiser"])
        #expect(feed.items.first?.link.absoluteString == "https://example.com/b")
        #expect(feed.items.allSatisfy { $0.source == "Example News" })
    }

    @Test func readsAtomAlternateLinks() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
        <entry><title>Post</title><link rel="self" href="https://example.com/self"/><link href="https://example.com/post"/>
        <updated>2026-10-14T10:30:00.123Z</updated></entry></feed>
        """
        let feed = try #require(FeedParser.parse(Data(xml.utf8), base: base))
        #expect(feed.items.count == 1)
        #expect(feed.items[0].link.absoluteString == "https://example.com/post")
        #expect(feed.items[0].published != nil)
    }

    @Test func readsRDFWithDublinCoreDates() throws {
        let xml = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel><title>RDF</title></channel>
        <item><title>One</title><link>https://example.com/1</link><dc:date>2026-10-10T08:00:00Z</dc:date></item></rdf:RDF>
        """
        let feed = try #require(FeedParser.parse(Data(xml.utf8), base: base))
        #expect(feed.title == "RDF")
        #expect(feed.items.map(\.title) == ["One"])
        #expect(feed.items[0].published != nil)
    }

    @Test func htmlIsNotAFeedButItsAlternateLinkIsFound() {
        let html = #"<html><head><link rel="stylesheet" href="/s.css"><link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml?x=1&amp;y=2"></head></html>"#
        #expect(FeedParser.parse(Data(html.utf8), base: base) == nil)
        #expect(FeedParser.discover(html: html, base: URL(string: "https://news.example.org/")!)?.absoluteString == "https://news.example.org/rss.xml?x=1&y=2")
        #expect(FeedParser.discover(html: "<link rel='alternate' type='text/html' href='/x'>", base: base) == nil)
    }

    @Test func undatedItemsComeAfterDatedOnes() {
        let a = FeedItem(title: "a", link: base, published: nil, source: "s")
        let b = FeedItem(title: "b", link: base, published: Date(timeIntervalSince1970: 10), source: "s")
        let c = FeedItem(title: "c", link: base, published: Date(timeIntervalSince1970: 20), source: "s")
        #expect(FeedParser.sortedNewestFirst([a, b, c]).map(\.title) == ["c", "b", "a"])
    }
}

struct FeedImageTests {
    private let base = URL(string: "https://example.com/feed")!

    @Test func thumbnailsEnclosuresAndInlineImages() throws {
        let xml = """
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>T</title>
        <item><title>Thumb</title><link>https://example.com/1</link><media:thumbnail url="http://cdn.example.com/1.jpg"/></item>
        <item><title>Video, then image</title><link>https://example.com/2</link><media:content url="https://cdn.example.com/2.mp4" type="video/mp4"/><media:content url="https://cdn.example.com/2.png" medium="image"/></item>
        <item><title>Enclosure</title><link>https://example.com/3</link><enclosure url="https://cdn.example.com/3.webp" type="image/webp" length="1"/></item>
        <item><title>Inline</title><link>https://example.com/4</link><content:encoded><![CDATA[<p>Hi</p><img src="data:image/png;base64,AA"><img alt="x" src="/img/4.jpg?w=600&amp;h=400">]]></content:encoded></item>
        <item><title>None</title><link>https://example.com/5</link><description>Plain text</description></item>
        </channel></rss>
        """
        let items = try #require(FeedParser.parse(Data(xml.utf8), base: base)).items
        let images = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.image?.absoluteString) })
        #expect(images["Thumb"] == "https://cdn.example.com/1.jpg")
        #expect(images["Video, then image"] == "https://cdn.example.com/2.png")
        #expect(images["Enclosure"] == "https://cdn.example.com/3.webp")
        #expect(images["Inline"] == "https://example.com/img/4.jpg?w=600&h=400")
        #expect(images["None"] == .some(nil))
    }

    @Test func youTubeStyleAtomThumbnail() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/"><title>Channel</title>
        <entry><title>Video</title><link rel="alternate" href="https://www.youtube.com/watch?v=x"/>
        <media:group><media:thumbnail url="https://i.ytimg.com/vi/x/hqdefault.jpg" width="480" height="360"/></media:group></entry></feed>
        """
        let items = try #require(FeedParser.parse(Data(xml.utf8), base: base)).items
        #expect(items.first?.image?.absoluteString == "https://i.ytimg.com/vi/x/hqdefault.jpg")
    }

    @Test func cachedItemsWithoutImagesStillDecode() throws {
        let json = #"[{"title":"t","link":"https://example.com","source":"s"}]"#
        let items = try JSONDecoder().decode([FeedItem].self, from: Data(json.utf8))
        #expect(items.first?.image == nil)
    }
}
