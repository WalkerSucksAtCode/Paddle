import Foundation
import PaddleCore
import Testing

struct ReaderArticleTests {
    @Test func readingTimeEstimatesBasedOnWordCount() {
        let short = ReaderArticle(
            title: "Quick Note",
            contentHTML: "<p>Short article text.</p>",
            textContent: "Short article text."
        )
        #expect(short.readingTimeMinutes == 1)

        // 400 words should be ~2 minutes
        let words400 = (1...400).map { "word\($0)" }.joined(separator: " ")
        let longer = ReaderArticle(
            title: "Longer Piece",
            contentHTML: "<p>\(words400)</p>",
            textContent: words400
        )
        #expect(longer.readingTimeMinutes == 2)
    }

    @Test func codableRoundTrip() throws {
        let article = ReaderArticle(
            title: "Exploring WebKit",
            byline: "Walker",
            publishedTime: "2026-10-15",
            siteName: "Paddle News",
            excerpt: "A deep dive into browser architecture.",
            contentHTML: "<p>Paddle is fast.</p>",
            textContent: "Paddle is fast."
        )
        let data = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(ReaderArticle.self, from: data)
        #expect(decoded == article)
        #expect(decoded.byline == "Walker")
        #expect(decoded.siteName == "Paddle News")
    }

    @Test func probeScriptIsNonEmpty() {
        #expect(ReaderExtractor.availabilityProbeScript.contains("document"))
        #expect(ReaderExtractor.extractionScript.contains("contentHTML"))
    }
}
