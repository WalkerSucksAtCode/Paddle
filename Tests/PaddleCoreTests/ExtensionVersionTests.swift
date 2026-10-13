import Foundation
@testable import PaddleCore
import Testing

struct ExtensionVersionTests {
    @Test func chromeOrdersNumerically() {
        #expect(ExtensionVersion.compareChrome("1.10", "1.9") == .orderedDescending)
        #expect(ExtensionVersion.compareChrome("1.0", "1") == .orderedSame)
        #expect(ExtensionVersion.compareChrome("5.9.1", "5.9.1.0") == .orderedSame)
        #expect(ExtensionVersion.compareChrome("1.2.3.4", "1.2.3.10") == .orderedAscending)
        #expect(ExtensionVersion.compareChrome("2", "1.9.9.9") == .orderedDescending)
        #expect(ExtensionVersion.compareChrome("1.0.0.1", "1.0") == .orderedDescending)
        #expect(ExtensionVersion.compareChrome("01.2", "1.2") == .orderedSame)
    }

    @Test func chromeRefusesWhatIsNotAChromeVersion() {
        let bad = ["", "1.2.3.4.5", "1..2", "1.2.", ".1", "1.a", "1.2b", "+1.2", "-1", "1 .2", "1,2", "99999999999999999999999"]
        for version in bad {
            #expect(ExtensionVersion.compareChrome(version, "1") == nil, "\(version)")
            #expect(ExtensionVersion.compareChrome("1", version) == nil, "\(version)")
        }
    }

    @Test func toolkitOrdersPartByPart() {
        #expect(ExtensionVersion.compareToolkit("1.10", "1.9") == .orderedDescending)
        #expect(ExtensionVersion.compareToolkit("1.0", "1") == .orderedSame)
        #expect(ExtensionVersion.compareToolkit("1.0", "1.0.0") == .orderedSame)
        #expect(ExtensionVersion.compareToolkit("1.0.0", "1.0") == .orderedSame)
        #expect(ExtensionVersion.compareToolkit("1.2.3", "1.2") == .orderedDescending)
        #expect(ExtensionVersion.compareToolkit("2.0a1", "1.9") == .orderedDescending)
    }

    @Test func toolkitLetterSuffixSortsBeforeNoSuffix() {
        #expect(ExtensionVersion.compareToolkit("2.0a1", "2.0") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("1.2.3b4", "1.2.3") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("2.0.1a1", "2.0.1") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("2.0", "2.0a1") == .orderedDescending)
    }

    /// The number after the letters may be left out: it counts as 0, so `1.0a` is `1.0a0`.
    @Test func toolkitLetterWithoutANumberCountsAsZero() {
        #expect(ExtensionVersion.compareToolkit("1.0a", "1.0a0") == .orderedSame)
        #expect(ExtensionVersion.compareToolkit("1.0a", "1.0a1") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("2.1b", "2.1a9") == .orderedDescending)
        #expect(ExtensionVersion.compareToolkit("2.1b", "2.1b1") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("2.1b", "2.1") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("1.0a", "1.0") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("1.2.3b", "1.2.3b0") == .orderedSame)
    }

    @Test func toolkitNumbersAfterLettersCompareAsNumbers() {
        #expect(ExtensionVersion.compareToolkit("3.0b2", "3.0b10") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("1.0a2", "1.0a1") == .orderedDescending)
        #expect(ExtensionVersion.compareToolkit("2.0a1", "2.0a1") == .orderedSame)
    }

    @Test func toolkitLetterRanks() {
        #expect(ExtensionVersion.compareToolkit("2.0a1", "2.0b1") == .orderedAscending)
        #expect(ExtensionVersion.compareToolkit("2.0rc1", "2.0b9") == .orderedDescending)
        #expect(ExtensionVersion.compareToolkit("2.0pre1", "2.0a1") == .orderedAscending)
    }

    @Test func toolkitRefusesWhatIsNotAToolkitVersion() {
        let bad = ["", "1.", ".1", "1.a", "a1", "1.2b4c5", "1.0A1", "1.0-beta", "1,0", "1..0", "99999999999999999999.0"]
        for version in bad {
            #expect(ExtensionVersion.compareToolkit(version, "1.0") == nil, "\(version)")
            #expect(ExtensionVersion.compareToolkit("1.0", version) == nil, "\(version)")
        }
    }

    @Test func sortsAStoreList() {
        let chrome = ["1.10", "1.9", "1.0", "1.9.1", "2"].sorted { ExtensionVersion.compareChrome($0, $1) == .orderedAscending }
        #expect(chrome == ["1.0", "1.9", "1.9.1", "1.10", "2"])
        let toolkit = ["2.0", "2.0a1", "1.10", "2.0b2", "2.0b10"].sorted {
            ExtensionVersion.compareToolkit($0, $1) == .orderedAscending
        }
        #expect(toolkit == ["1.10", "2.0a1", "2.0b2", "2.0b10", "2.0"])
    }
}
