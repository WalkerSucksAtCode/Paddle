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
