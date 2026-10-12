import Foundation
@testable import PaddleCore
import Testing

struct RegexTranslatorTests {
    func filters(_ source: String) -> [String]? {
        if case .success(let filters) = RegexTranslator.translate(source) { return filters }
        return nil
    }

    func refusal(_ source: String) -> RegexTranslator.Refusal? {
        if case .failure(let refusal) = RegexTranslator.translate(source) { return refusal }
        return nil
    }

    @Test func shorthandClassesBecomeExplicit() {
        #expect(filters(#"ads\d+\.js"#) == [#"ads[0-9]+\.js"#])
        #expect(filters(#"id=\w"#) == ["id=[A-Za-z0-9_]"])
        #expect(filters(#"x\D\W"#) == ["x[^0-9][^A-Za-z0-9_]"])
        #expect(filters(#"[\d.]+"#) == ["[0-9.]+"])
        #expect(filters(#"[^\d]"#) == ["[^0-9]"])
        #expect(filters(#"^https?:\/\/a\.test\/"#) == [#"^https?://a\.test/"#])
    }

    @Test func boundedRepetitionIsWrittenOut() {
        #expect(filters(#"ads\d{2,4}\.js"#) == [#"ads[0-9][0-9][0-9]?[0-9]?\.js"#])
        #expect(filters("a{3}") == ["aaa"])
        #expect(filters("a{2,}") == ["aa+"])
        #expect(filters("a{0,}b") == ["a*b"])
        #expect(filters(#"(\d){1,3}x"#) == ["[0-9][0-9]?[0-9]?x"])
        #expect(filters("(?:ab){2}") == ["abab"])
        #expect(filters("(?:ab)+c") == ["(ab)+c"])
        #expect(filters("a*?b+?") == ["a*b+"])  // lazy matches the same URLs
    }

    @Test func repetitionCapIs32() {
        #expect(filters("a{32}") == [String(repeating: "a", count: 32)])
        #expect(filters("a{1,32}")?.first?.count == 1 + 31 * 2)
        #expect(refusal("a{33}") == .tooManyRepetitions)
        #expect(refusal("a{1,33}") == .tooManyRepetitions)
        #expect(refusal("a{33,}") == .tooManyRepetitions)
        #expect(refusal(".{100,}") == .tooManyRepetitions)
    }

    @Test func alternationBecomesSeparateFilters() {
        #expect(filters("(ad|banner)s\\.js") == [#"ads\.js"#, #"banners\.js"#])
        #expect(filters("^https?:\\/\\/(x|y)\\.test\\/$") == [#"^https?://x\.test/$"#, #"^https?://y\.test/$"#])
        #expect(filters("(^|/)ads") == ["^ads", "/ads"])
        #expect(filters("ad(s)?x") == ["ads?x"])
        #expect(filters("ad(s|z)?x") == ["adx", "adsx", "adzx"])
        #expect(filters("(a|b|c)+x") == ["[abc]+x"])  // single characters repeat as a set
        #expect(filters("(club|club)") == ["club"])  // duplicates collapse
        #expect(refusal("(abc|de)*") == .repeatedAlternation)
    }

    @Test func alternativeCapIs32() {
        let words = (0..<32).map { "w\($0)x" }
        #expect(filters("(" + words.joined(separator: "|") + ")")?.count == 32)
        #expect(refusal("(" + (words + ["w32x"]).joined(separator: "|") + ")") == .tooManyAlternatives)
        #expect(refusal("(a|b)(c|d)(e|f)(g|h)(i|j)(k|l)") == .tooManyAlternatives)  // 64 combinations
    }

    @Test func unsupportedConstructsAreRefused() {
        #expect(refusal("ads(?=x)") == .lookaround)
        #expect(refusal("ads(?!x)") == .lookaround)
        #expect(refusal("(?<=x)ads") == .lookaround)
        #expect(refusal("(?<name>ads)") == .lookaround)
        #expect(refusal(#"\bads"#) == .wordBoundary)
        #expect(refusal(#"(a)\1"#) == .backreference)
        #expect(refusal(#"a\sb"#) == .unsupportedEscape("s"))
        #expect(refusal(#"a\x41"#) == .unsupportedEscape("x"))
        #expect(refusal(#"a\nb"#) == .unsupportedEscape("n"))
        #expect(refusal(#"[\D]"#) == .unsupportedEscape("D"))
        #expect(refusal("a^b") == .misplacedAnchor)
        #expect(refusal("a$b") == .misplacedAnchor)
        #expect(refusal("ä") == .nonASCII)
        #expect(refusal("a|") == .matchesEverything)
        #expect(refusal("(a") == .malformed)
        #expect(refusal("a{2") == .malformed)
        #expect(refusal("[]") == .malformed)
        #expect(refusal("+a") == .malformed)
    }

    @Test func longFiltersAreRefused() {
        #expect(filters("[a-z]{30}")?.first?.count == 150)
        #expect(refusal(#"\/[0-9a-f]{32}\/invoke\.js"#) == .tooLong)
    }

    /// The point of translating instead of approximating: the original and the url-filters agree on every URL.
    @Test func translationMatchesTheSameURLs() throws {
        let patterns = [
            #"^https?:\/\/(35|104)\.(\d){1,3}\.(\d){1,3}\.(\d){1,3}\/"#,
            #"\.gsmarena\.com\/[0-9]+\.[a-z]+\?s?Search="#,
            #"^https?:\/\/.*\.(club|xyz|top|casa)\/"#,
            #"ads\d{2,4}\.js$"#,
            "(^|/)ad(s|z)?/",
        ]
        let urls = [
            "https://35.1.22.133/x", "http://104.255.0.1/", "https://36.1.2.3/", "https://35.1234.1.1/",
            "https://a.gsmarena.com/12.php?Search=x", "https://a.gsmarena.com/12.php?sSearch=x", "https://gsmarena.com/x.php?Search=",
            "https://a.b.club/", "https://a.b.clubs/", "https://top/", "https://x.casa/y",
            "https://x.test/ads12.js", "https://x.test/ads12345.js", "https://x.test/ads1.js", "https://x.test/ads123.js?x",
            "https://x.test/ad/", "https://x.test/adz/", "ads/", "https://x.test/adx/",
        ]
        for pattern in patterns {
            let original = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let translated = try #require(filters(pattern)).map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
            for url in urls {
                let range = NSRange(url.startIndex..., in: url)
                let expected = original.firstMatch(in: url, range: range) != nil
                let actual = translated.contains { $0.firstMatch(in: url, range: range) != nil }
                #expect(actual == expected, "\(pattern) on \(url)")
            }
        }
    }
}
