import Foundation
@testable import PaddleCore
import Testing

struct SuggestionsTests {
    func page(_ kind: SuggestionSource.Kind, _ title: String, _ url: String, score: Double = 0) -> SuggestionSource {
        SuggestionSource(kind: kind, title: title, url: url, score: score)
    }

    /// A history page.
    func page(_ title: String, _ url: String, score: Double = 0) -> SuggestionSource {
        page(.history, title, url, score: score)
    }

    func rank(_ text: String, _ pages: [SuggestionSource], search: [String] = [], limit: Int = 8, maxSearch: Int = 4) -> [Suggestion] {
        SuggestionRanker.suggestions(for: text, pages: pages, searchPhrases: search, limit: limit, maxSearch: maxSearch)
    }

    @Test func everyWordMustMatchTitleOrURL() {
        let a = page("Swift Evolution", "https://github.com/apple/swift-evolution")
        let b = page("Swift Blog", "https://swift.org/blog")
        let result = rank("swift github", [a, b])
        #expect(result.map(\.url) == [a.url])
        #expect(rank("swift blog", [a, b]).map(\.url) == [b.url])
        #expect(rank("swift zebra", [a, b]).isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        let a = page("Apple Developer", "https://Developer.Apple.com/")
        #expect(rank("APPLE dev", [a]).count == 1)
    }

    @Test func hostPrefixBeatsTitleWordBeatsSubstring() {
        let substring = page("Digital things", "https://example.com/digit-al")
        let titleWord = page("A git tutorial", "https://example.org/tutorial")
        let host = page("Code hosting", "https://github.com/")
        let result = rank("git", [substring, titleWord, host])
        #expect(result.map(\.url) == [host.url, titleWord.url, substring.url])
    }

    @Test func tiesBreakByScoreThenShorterURL() {
        let low = page("Docs", "https://docs.a.com/x", score: 1)
        let high = page("Docs", "https://docs.b.com/xyz", score: 5)
        let shortA = page("Docs", "https://docs.c.com", score: 1)
        #expect(rank("docs", [low, high, shortA]).map(\.url) == [high.url, shortA.url, low.url])
    }

    @Test func kindsGroupTabsThenBookmarksThenHistory() {
        let id = UUID()
        let history = page(.history, "Swift", "https://swift.org/", score: 99)
        let bookmark = page(.bookmark, "Swift Package", "https://swiftpackageindex.com/")
        let tab = page(.openTab(id), "Swift Forums", "https://forums.swift.org/")
        let result = rank("swift", [history, bookmark, tab])
        #expect(result.map(\.kind) == [.openTab(id), .bookmark, .history])
    }

    @Test func dedupeKeepsBestKind() {
        let id = UUID()
        let history = page(.history, "GitHub", "https://www.github.com/", score: 9)
        let bookmark = page(.bookmark, "GitHub", "https://github.com")
        let tab = page(.openTab(id), "GitHub", "https://github.com/")
        #expect(rank("github", [history, bookmark, tab]).map(\.kind) == [.openTab(id)])
        #expect(rank("github", [history, bookmark]).map(\.kind) == [.bookmark])
    }

    @Test func rowsCarryDisplayFieldsAndStableIDs() throws {
        let row = try #require(rank("github", [page("GitHub", "https://www.github.com/anthropics")]).first)
        #expect(row.title == "GitHub")
        #expect(row.detail == "github.com/anthropics")
        #expect(row.url == "https://www.github.com/anthropics")
        #expect(row.id == "history:https://www.github.com/anthropics")
        let untitled = try #require(rank("example", [page("  ", "https://example.com/")]).first)
        #expect(untitled.title == "example.com")
    }

    @Test func limitAndMaxSearchApply() {
        let pages = (0..<10).map { page("Item \($0)", "https://site\($0).com/item") }
        #expect(rank("item", pages, limit: 5).count == 5)
        let phrases = ["item a", "item b", "item c", "item d", "item e", "item f"]
        let result = rank("item", [], search: phrases, maxSearch: 3)
        #expect(result.map(\.title) == ["item a", "item b", "item c"])
        #expect(rank("item", pages, search: phrases, limit: 8, maxSearch: 4).count == 8)
    }

    @Test func searchRowsFollowPagesAndSkipTypedText() throws {
        let p = page("Swift", "https://swift.org/")
        let result = rank("Swift", [p], search: ["swift", "SWIFT ", "swift ui", "Swift UI", "", "swift concurrency"])
        #expect(result.map(\.title) == ["Swift", "swift ui", "swift concurrency"])
        let search = try #require(result.last)
        #expect(search.kind == .search)
        #expect(search.query == "swift concurrency")
        #expect(search.detail == "Search")
        #expect(search.url == nil)
        #expect(search.id == "search:swift concurrency")
    }

    @Test func emptyOrWhitespaceTextReturnsNothing() {
        let p = page("Swift", "https://swift.org/")
        #expect(rank("", [p], search: ["a"]).isEmpty)
        #expect(rank("   \t", [p], search: ["a"]).isEmpty)
    }

    @Test func inlineCompletionPrefersShortestHost() {
        let long = page("", "https://github.community/forum")
        let short = page("", "https://github.com/anthropics")
        #expect(SuggestionRanker.inlineCompletion(for: "git", pages: [long, short]) == "github.com/")
        #expect(SuggestionRanker.inlineCompletion(for: "GIT", pages: [long, short]) == "github.com/")
    }

    @Test func inlineCompletionIgnoresSchemeAndWWW() {
        let apple = page("", "https://www.apple.com/mac")
        #expect(SuggestionRanker.inlineCompletion(for: "app", pages: [apple]) == "apple.com/")
        #expect(SuggestionRanker.inlineCompletion(for: "www.app", pages: [apple]) == "www.apple.com/")
        #expect(SuggestionRanker.inlineCompletion(for: "w", pages: [apple]) == nil)
    }

    @Test func inlineCompletionCompletesPaths() {
        let p = page("", "https://github.com/anthropics/claude")
        #expect(SuggestionRanker.inlineCompletion(for: "github.com/an", pages: [p]) == "github.com/anthropics/claude")
        #expect(SuggestionRanker.inlineCompletion(for: "github.com/zz", pages: [p]) == nil)
        #expect(SuggestionRanker.inlineCompletion(for: "anthropics", pages: [p]) == nil)
    }

    @Test func inlineCompletionNeedsASingleWordAndAMatch() {
        let p = page("", "https://github.com/")
        #expect(SuggestionRanker.inlineCompletion(for: "git hub", pages: [p]) == nil)
        #expect(SuggestionRanker.inlineCompletion(for: "", pages: [p]) == nil)
        #expect(SuggestionRanker.inlineCompletion(for: "zzz", pages: [p]) == nil)
        #expect(SuggestionRanker.inlineCompletion(for: "github.com/", pages: [p]) == nil)
    }

    @Test func displayURLStripsSchemeWWWAndBareSlash() {
        #expect(SuggestionRanker.displayURL("https://www.example.com/") == "example.com")
        #expect(SuggestionRanker.displayURL("http://example.com") == "example.com")
        #expect(SuggestionRanker.displayURL("https://example.com/a/b?q=1") == "example.com/a/b?q=1")
        #expect(SuggestionRanker.displayURL("https://example.com/a/") == "example.com/a/")
        #expect(SuggestionRanker.displayURL("https://wwwx.example.com/") == "wwwx.example.com")
    }

    @Test func requestURLEncodesQueryValue() {
        let template = "https://suggest.example.com/complete?q=%s&format=json"
        #expect(SearchSuggestions.requestURL(template: template, query: "a b")?.absoluteString == "https://suggest.example.com/complete?q=a%20b&format=json")
        #expect(SearchSuggestions.requestURL(template: template, query: "a&b+c#d")?.absoluteString == "https://suggest.example.com/complete?q=a%26b%2Bc%23d&format=json")
        #expect(SearchSuggestions.requestURL(template: template, query: "café")?.absoluteString == "https://suggest.example.com/complete?q=caf%C3%A9&format=json")
    }

    @Test func requestURLNeedsPlaceholder() {
        #expect(SearchSuggestions.requestURL(template: "https://example.com/complete?q=", query: "x") == nil)
        #expect(SearchSuggestions.requestURL(template: "", query: "x") == nil)
    }

    @Test func parsesOpenSearch() {
        let data = Data(#"["swift", ["swift ui", "", "swift org", 3], [], {}]"#.utf8)
        #expect(SearchSuggestions.parse(data) == ["swift ui", "swift org"])
    }

    @Test func parsesDuckDuckGo() {
        let data = Data(#"[{"phrase":"swift"},{"phrase":""},{"other":1},{"phrase":"swift ui"}]"#.utf8)
        #expect(SearchSuggestions.parse(data) == ["swift", "swift ui"])
    }

    @Test func parseRejectsGarbage() {
        #expect(SearchSuggestions.parse(Data("not json".utf8)).isEmpty)
        #expect(SearchSuggestions.parse(Data("{\"phrase\":\"a\"}".utf8)).isEmpty)
        #expect(SearchSuggestions.parse(Data("[]".utf8)).isEmpty)
        #expect(SearchSuggestions.parse(Data(#"["a","b"]"#.utf8)).isEmpty)
        #expect(SearchSuggestions.parse(Data()).isEmpty)
    }
}
