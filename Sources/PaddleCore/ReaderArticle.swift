import Foundation

/// Extracted article content for distraction-free Reader Mode.
public struct ReaderArticle: Codable, Equatable, Sendable {
    public let title: String
    public let byline: String?
    public let publishedTime: String?
    public let siteName: String?
    public let excerpt: String?
    public let contentHTML: String
    public let textContent: String
    public let readingTimeMinutes: Int

    public init(
        title: String,
        byline: String? = nil,
        publishedTime: String? = nil,
        siteName: String? = nil,
        excerpt: String? = nil,
        contentHTML: String,
        textContent: String,
        readingTimeMinutes: Int? = nil
    ) {
        self.title = title
        self.byline = byline
        self.publishedTime = publishedTime
        self.siteName = siteName
        self.excerpt = excerpt
        self.contentHTML = contentHTML
        self.textContent = textContent
        let words = textContent.split { $0.isWhitespace || $0.isPunctuation }.count
        self.readingTimeMinutes = readingTimeMinutes ?? max(1, Int((Double(words) / 200.0).rounded()))
    }
}
