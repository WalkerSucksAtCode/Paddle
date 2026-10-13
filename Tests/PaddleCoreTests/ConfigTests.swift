import Foundation
@testable import PaddleCore
import Testing

struct ConfigTests {
    @Test func partialConfigKeepsDefaults() throws {
        let config = try PaddleConfig.decode(Data(#"{"maxAwakeTabs": 4, "searchTemplate": "https://kagi.com/search?q=%s"}"#.utf8))
        #expect(config.maxAwakeTabs == 4)
        #expect(config.searchTemplate == "https://kagi.com/search?q=%s")
        #expect(config.tabSleepAfterMinutes == PaddleConfig().tabSleepAfterMinutes)
        #expect(config.filterLists == PaddleConfig.defaultFilterLists)
        #expect(config.historyDays == 365)
        #expect(config.searchSuggestTemplate.contains("%s"))
    }

    @Test func roundTrips() throws {
        var config = PaddleConfig()
        config.shortcuts = ["newTab": "cmd+t"]
        config.siteUserAgents = ["example.com": "UA"]
        #expect(try PaddleConfig.decode(config.encoded()) == config)
    }

    @Test func wrongTypeFallsBackToTheDefaultAndIsReported() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"maxAwakeTabs": "four", "historyDays": 30}"#.utf8))
        #expect(config.maxAwakeTabs == PaddleConfig().maxAwakeTabs)
        #expect(config.historyDays == 30)
        #expect(issues.count == 1)
        #expect(issues.first?.path == ["maxAwakeTabs"])
        #expect(issues.first?.severity == .warning)
        #expect(issues.first?.message == "Expected a whole number. Paddle uses the default, 10, until this is fixed.")
        #expect(try PaddleConfig.decode(Data(#"{"maxAwakeTabs": "four"}"#.utf8)).maxAwakeTabs == 10)
    }

    @Test func nullAndMissingKeysAreTheDefaultWithNoIssue() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(
            Data(#"{"maxAwakeTabs": null, "sites": null, "filterLists": null, "unknownKey": [1]}"#.utf8)
        )
        #expect(config == PaddleConfig())
        #expect(issues.isEmpty)
    }

    @Test func sitesEntryOfTheWrongTypeIsSkippedAndTheOthersKept() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(
            Data(#"{"sites": {"a.com": {"zoom": "big"}, "b.com": {"zoom": 1.5}}}"#.utf8)
        )
        #expect(config.sites == ["b.com": SiteSettings(zoom: 1.5)])
        #expect(issues.map(\.path) == [["sites", "a.com"]])
        #expect(issues.first?.message == "Expected a number for zoom in this entry. Paddle ignores this entry until it is fixed.")
    }

    @Test func sitesUnknownAutoplayWordSkipsOnlyItsEntry() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(
            Data(#"{"sites": {"a.com": {"autoplay": "loud"}, "b.com": {"autoplay": "block"}}}"#.utf8)
        )
        #expect(config.sites == ["b.com": SiteSettings(autoplay: .block)])
        #expect(issues.map(\.path) == [["sites", "a.com"]])
    }

    @Test func objectKeyThatIsNotAnObjectFallsBackWhole() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"sites": []}"#.utf8))
        #expect(config.sites == [:])
        #expect(issues.map(\.path) == [["sites"]])
        #expect(issues.first?.message == "Expected an object. Paddle uses the default, {}, until this is fixed.")
    }

    @Test func sitePersonaWithAnUnknownWordIsSkipped() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"sitePersonas": {"a.com": "safari", "b.com": "chrome"}}"#.utf8))
        #expect(config.sitePersonas == ["b.com": .chrome])
        #expect(issues.map(\.path) == [["sitePersonas", "a.com"]])
    }

    @Test func extensionCompatFieldOfTheWrongTypeDropsItsEntry() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(
            Data(#"{"extensionCompat": {"x": {"private": "yes"}, "y": {"private": true}}}"#.utf8)
        )
        #expect(config.extensionCompat.keys.sorted() == ["y"])
        #expect(config.compat(forFolder: "y").inPrivate == true)
        #expect(issues.map(\.path) == [["extensionCompat", "x"]])
    }

    @Test func listItemOfTheWrongTypeIsSkippedWithItsIndex() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"filterLists": ["a", 3, "b"]}"#.utf8))
        #expect(config.filterLists == ["a", "b"])
        #expect(issues.map(\.path) == [["filterLists", "1"]])
        #expect(issues.first?.message == "Expected text for this item. Paddle ignores this item until it is fixed.")
    }

    @Test func listThatIsNotAListFallsBackWithItsDefaultCutShort() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"filterLists": "a"}"#.utf8))
        #expect(config.filterLists == PaddleConfig.defaultFilterLists)
        #expect(issues.map(\.path) == [["filterLists"]])
        #expect(issues.first?.message.hasPrefix("Expected a list. Paddle uses the default, [\"https://easylist.to") == true)
        #expect(issues.first?.message.contains("…, until this is fixed.") == true)
    }

    @Test func notJSONOrANonObjectTopLevelStillFailsWhole() {
        #expect(throws: DecodingError.self) { try PaddleConfig.decode(Data("{".utf8)) }
        #expect(throws: DecodingError.self) { try PaddleConfig.decodeReportingIssues(Data("[]".utf8)) }
    }

    @Test func syntaxErrorSaysWhere() {
        do {
            _ = try PaddleConfig.decode(Data("{\n  \"maxAwakeTabs\": 4\n  \"homepage\": \"x\"\n}".utf8))
            Issue.record("missing comma should not parse")
        } catch {
            let text = PaddleConfig.describe(error)
            #expect(text.contains("line"), "\(text)")
        }
    }

    @Test func siteUserAgentMatchesLongestHostSuffix() {
        let config = PaddleConfig(siteUserAgents: ["example.com": "A", "app.example.com": "B"])
        #expect(config.userAgent(forHost: "www.example.com") == "A")
        #expect(config.userAgent(forHost: "app.example.com") == "B")
        #expect(config.userAgent(forHost: "x.app.example.com") == "B")
        #expect(config.userAgent(forHost: "notexample.com") == nil)
    }

    @Test func extensionsDecodeAndDefaultToOn() throws {
        let config = try PaddleConfig.decode(Data(#"{"extensions": {"bitwarden": false, "ubolite": true}}"#.utf8))
        #expect(config.extensions == ["bitwarden": false, "ubolite": true])
        #expect(!config.isExtensionEnabled("bitwarden"))
        #expect(config.isExtensionEnabled("ubolite"))
        #expect(config.isExtensionEnabled("not-listed"))
    }

    @Test func missingExtensionsKeyIsEmpty() throws {
        let config = try PaddleConfig.decode(Data("{}".utf8))
        #expect(config.extensions == [:])
        #expect(config.isExtensionEnabled("anything"))
        #expect(try PaddleConfig.decode(PaddleConfig(extensions: ["x": false]).encoded()).extensions == ["x": false])
    }
}
