import Foundation

/// A news feed Settings > General > New Tab offers to switch on with one click (`newTabFeeds`).
public struct SuggestedFeed: Sendable, Hashable, Identifiable {
    public let name: String
    /// A few words on what it covers.
    public let topic: String
    public let url: String
    public var id: String { url }
}

/// Feeds Paddle suggests for New Tab's News section. Each one was checked to serve RSS with story pictures
/// (2026-10-18); switching one on only adds its address to `newTabFeeds`.
public enum SuggestedFeeds {
    public static let all: [SuggestedFeed] = [
        SuggestedFeed(name: "BBC News", topic: "World and UK news", url: "https://feeds.bbci.co.uk/news/rss.xml"),
        SuggestedFeed(name: "NPR", topic: "US news", url: "https://feeds.npr.org/1001/rss.xml"),
        SuggestedFeed(name: "The Guardian", topic: "World news", url: "https://www.theguardian.com/world/rss"),
        SuggestedFeed(name: "The New York Times", topic: "Top stories", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
        SuggestedFeed(name: "Ars Technica", topic: "Technology and science", url: "https://feeds.arstechnica.com/arstechnica/index"),
        SuggestedFeed(name: "The Verge", topic: "Technology", url: "https://www.theverge.com/rss/index.xml"),
        SuggestedFeed(name: "Wired", topic: "Technology and culture", url: "https://www.wired.com/feed/rss"),
        SuggestedFeed(name: "NASA", topic: "Space", url: "https://www.nasa.gov/news-release/feed/"),
    ]

    public static let urls: Set<String> = Set(all.map(\.url))
}
