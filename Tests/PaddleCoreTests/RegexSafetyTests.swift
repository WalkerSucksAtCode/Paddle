import Foundation
@testable import PaddleCore
import Testing

struct RegexSafetyTests {
    @Test func refusesNestedRepeats() {
        for pattern in ["(a+)+", "(a*)*", "(a+)*", "(a*)+", "((ab)+c)+", "(a?)*", "(a{2,})+"] {
            #expect(RegexSafety.refusalReason(pattern) != nil, "\(pattern) should be refused")
        }
    }

    /// `@match` produces `([^/]*\.)?` and `(:[0-9]+)?`, so optional groups with repeats inside must stay allowed.
    @Test func keepsOptionalGroupsAndSafeAlternatives() {
        for pattern in ["([^/]*\\.)?example\\.com(:[0-9]+)?", "^https://x\\.test/(a+)?$", "(ab|cd)+", "(a|b)*", "(a|ab)x", "\\(a+\\)+", "[(]+a+"] {
            #expect(RegexSafety.refusalReason(pattern) == nil, "\(pattern) should be allowed")
        }
    }

    @Test func refusesRepeatedAlternativesThatCanOverlap() {
        for pattern in ["(a|a)+", "(a|ab)*", "(https|http)+", "(\\d|x)+", "(a|)+", "(.|x)*"] {
            #expect(RegexSafety.refusalReason(pattern) != nil, "\(pattern) should be refused")
        }
    }

    @Test func refusesBackreferencesLookaroundsAndOtherGroupSyntax() {
        for pattern in ["(a)\\1", "(?<n>a)\\k<n>", "a(?=b)", "a(?!b)", "(?<=a)b", "(?<!a)b", "(?i)abc", "(?>a)"] {
            #expect(RegexSafety.refusalReason(pattern) != nil, "\(pattern) should be refused")
        }
        #expect(RegexSafety.refusalReason("(?<n>a)b") == nil)
    }

    @Test func refusesPatternsOver200Characters() {
        #expect(RegexSafety.refusalReason(String(repeating: "a", count: 200)) == nil)
        #expect(RegexSafety.refusalReason(String(repeating: "a", count: 201)) != nil)
    }

    @Test func unbalancedOrInvalidPatternsAreNotUsable() {
        #expect(RegexSafety.refusalReason("a)") != nil)
        #expect(RegexSafety.refusalReason("(a") != nil)
        #expect(!RegexSafety.isUsable("("))
        #expect(!RegexSafety.isUsable("a)"))
        #expect(RegexSafety.isUsable("a+b"))
    }

    @Test func matchesCapURLLengthAndNeverRunRefusedPatterns() {
        #expect(RegexSafety.matches("^https://x\\.test/\\d+$", url: "https://x.test/42"))
        #expect(!RegexSafety.matches("(a+)+$", url: String(repeating: "a", count: 50) + "!"))
        #expect(!RegexSafety.matches("(", url: "("))
        let prefix = "https://a.test/"
        let atLimit = prefix + String(repeating: "x", count: RegexSafety.maxURLLength - prefix.utf16.count)
        #expect(atLimit.utf16.count == RegexSafety.maxURLLength)
        #expect(RegexSafety.matches(".*", url: atLimit))
        #expect(!RegexSafety.matches(".*", url: atLimit + "x"))
    }

    @Test func compiledPatternsAreCached() {
        #expect(RegexSafety.compiled("a+b") != nil)
        #expect(RegexSafety.compiled("a+b") === RegexSafety.compiled("a+b"))
    }
}
