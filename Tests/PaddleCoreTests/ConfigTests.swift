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

    @Test func cpuSleepPercentDefaultsToThirtyAndWrongTypeFallsBack() throws {
        #expect(PaddleConfig().cpuSleepPercent == 30)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"cpuSleepPercent": "lots"}"#.utf8))
        #expect(config.cpuSleepPercent == 30)
        #expect(issues.count == 1)
        #expect(issues.first?.path == ["cpuSleepPercent"])
        #expect(issues.first?.message == "Expected a whole number. Paddle uses the default, 30, until this is fixed.")
        #expect(try PaddleConfig.decode(Data(#"{"cpuSleepPercent": 0}"#.utf8)).cpuSleepPercent == 0)
    }

    @Test func tabFreezeAfterMinutesDefaultsToFiveAndWrongTypeFallsBack() throws {
        #expect(PaddleConfig().tabFreezeAfterMinutes == 5)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"tabFreezeAfterMinutes": "soon"}"#.utf8))
        #expect(config.tabFreezeAfterMinutes == 5)
        #expect(issues.count == 1)
        #expect(issues.first?.path == ["tabFreezeAfterMinutes"])
        #expect(try PaddleConfig.decode(Data(#"{"tabFreezeAfterMinutes": 0}"#.utf8)).tabFreezeAfterMinutes == 0)
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

    @Test func extensionToolbarDecodesAndSkipsBadEntries() throws {
        let (config, issues) = try PaddleConfig.decodeReportingIssues(
            Data(#"{"extensionToolbar": {"a": "menu", "b": "hidden", "c": "sideways"}}"#.utf8))
        #expect(config.extensionToolbar == ["a": .menu, "b": .hidden])
        #expect(issues.map(\.path) == [["extensionToolbar", "c"]])
        #expect(config.toolbarPlacement(folder: "a") == .menu)
        #expect(config.toolbarPlacement(folder: "zzz") == .pinned)
    }

    @Test func tabLayoutDecodes() throws {
        #expect(PaddleConfig().tabLayout == .horizontal)
        #expect(try PaddleConfig.decode(Data(#"{"tabLayout": "vertical"}"#.utf8)).tabLayout == .vertical)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"tabLayout": "diagonal"}"#.utf8))
        #expect(config.tabLayout == .horizontal)
        #expect(issues.map(\.path) == [["tabLayout"]])
    }

    @Test func appearanceKeysDefaultAndDecode() throws {
        let d = PaddleConfig()
        #expect(d.appearance == .system && !d.highContrastTabs && d.interfaceTextSize == .default)
        #expect(d.defaultZoom == 1 && d.minimumFontSize == 0 && d.reduceMotion == .system && d.reduceTransparency == .system)
        let json = #"{"appearance": "dark", "highContrastTabs": true, "interfaceTextSize": "larger", "defaultZoom": 1.25, "minimumFontSize": 12, "reduceMotion": "always", "reduceTransparency": "always"}"#
        let (c, issues) = try PaddleConfig.decodeReportingIssues(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(c.appearance == .dark && c.highContrastTabs && c.interfaceTextSize == .larger)
        #expect(c.defaultZoom == 1.25 && c.minimumFontSize == 12 && c.reduceMotion == .always && c.reduceTransparency == .always)
        #expect(try PaddleConfig.decode(c.encoded()) == c)
        #expect(InterfaceTextSize.allCases.map(\.scale) == [0.9, 1.0, 1.15, 1.3])
    }

    @Test func appearanceKeysFallBackWhenInvalid() throws {
        let json = #"{"appearance": "sepia", "interfaceTextSize": "huge", "reduceMotion": "never", "reduceTransparency": 3, "highContrastTabs": "yes", "defaultZoom": "big", "minimumFontSize": -4}"#
        let (c, issues) = try PaddleConfig.decodeReportingIssues(Data(json.utf8))
        #expect(c.appearance == .system && c.interfaceTextSize == .default && c.reduceMotion == .system)
        #expect(c.reduceTransparency == .system && !c.highContrastTabs && c.defaultZoom == 1 && c.minimumFontSize == 0)
        #expect(Set(issues.map(\.path)) == [["appearance"], ["interfaceTextSize"], ["reduceMotion"], ["reduceTransparency"], ["highContrastTabs"], ["defaultZoom"], ["minimumFontSize"]])
    }

    @Test func defaultZoomAndMinimumFontSizeAreClamped() throws {
        #expect(try PaddleConfig.decode(Data(#"{"defaultZoom": 9}"#.utf8)).defaultZoom == 3)
        #expect(try PaddleConfig.decode(Data(#"{"defaultZoom": 0.1}"#.utf8)).defaultZoom == 0.3)
        let (small, smallIssues) = try PaddleConfig.decodeReportingIssues(Data(#"{"minimumFontSize": 4}"#.utf8))
        #expect(small.minimumFontSize == 9 && smallIssues.isEmpty)
        #expect(try PaddleConfig.decode(Data(#"{"minimumFontSize": 99}"#.utf8)).minimumFontSize == 24)
        #expect(try PaddleConfig.decode(Data(#"{"minimumFontSize": 0}"#.utf8)).minimumFontSize == 0)
    }

    @Test func sitesWithoutZoomGetTheDefaultZoom() {
        var config = PaddleConfig(defaultZoom: 1.25)
        config.sites = ["a.com": SiteSettings(zoom: 1), "b.com": SiteSettings(javaScript: false)]
        #expect(config.sitePolicy(forHost: "a.com").zoom == 1)
        #expect(config.sitePolicy(forHost: "b.com").zoom == 1.25)
        #expect(config.sitePolicy(forHost: "other.org").zoom == 1.25)
    }
}
