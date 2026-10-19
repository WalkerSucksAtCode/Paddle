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

    @Test func browsingBehaviourKeysDefaultToTodaysBehaviour() {
        let config = PaddleConfig()
        #expect(config.onLaunch == .restore)
        #expect(config.newTabPosition == .end)
        #expect(config.openLinksInBackground)
        #expect(config.afterClosingTab == .right)
        #expect(!config.askBeforeQuitting && !config.askBeforeClosingWindow)
        #expect(config.externalLinks == .newTab)
        #expect(config.fraudWarnings && config.swipeNavigation && config.pinchZoom)
        #expect(!config.tabKeyHighlightsLinks)
        #expect(!config.contactAutofill)
        #expect(config.newTabExtension.isEmpty)
        #expect(config.newTabFeeds.isEmpty && !config.newTabNotifications && config.newTabHiddenNotifications.isEmpty)
        #expect(config.mosaicMaxPanes == 4)
        #expect(PaddleConfig(mosaicMaxPanes: 99).mosaicMaxPanes == PaneLayout.maxPanes)
    }

    @Test func mosaicPaneAndStripKeysDecode() throws {
        let d = PaddleConfig()
        #expect(d.mosaicDarkMode == .site && d.mosaicZoom == .focused && !d.mosaicFocusFollowsPointer && d.mosaicSound == .all)
        #expect(d.mosaicCloseKey == .closeTab && d.mosaicStripIcon == .icon && d.mosaicStripName == .focused)
        let c = try PaddleConfig.decode(Data(#"{"mosaicDarkMode": "perPane", "mosaicZoom": "all", "mosaicFocusFollowsPointer": true, "mosaicSound": "focused", "mosaicCloseKey": "removePane", "mosaicStripIcon": "favicons", "mosaicStripName": "all"}"#.utf8))
        #expect(c.mosaicDarkMode == .perPane && c.mosaicZoom == .all && c.mosaicFocusFollowsPointer && c.mosaicSound == .focused)
        #expect(c.mosaicCloseKey == .removePane && c.mosaicStripIcon == .favicons && c.mosaicStripName == .all)
    }

    @Test func mosaicOpeningAndDraggingKeysDecode() throws {
        let d = PaddleConfig()
        #expect(d.mosaicPaneGrab == .icon && d.mosaicModifierDrag && d.mosaicWindowDrag)
        #expect(d.mosaicNewTab == .tab && d.mosaicLinks == .tab && d.mosaicNewPanePlacement == .largest)
        #expect(d.mosaicDefaultLayout == .asDropped && !d.mosaicAutoArrange)
        let c = try PaddleConfig.decode(Data(#"{"mosaicPaneGrab": "toolbar", "mosaicModifierDrag": false, "mosaicWindowDrag": false, "mosaicNewTab": "pane", "mosaicLinks": "pane", "mosaicNewPanePlacement": "focused", "mosaicDefaultLayout": "grid", "mosaicAutoArrange": true}"#.utf8))
        #expect(c.mosaicPaneGrab == .toolbar && !c.mosaicModifierDrag && !c.mosaicWindowDrag)
        #expect(c.mosaicNewTab == .pane && c.mosaicLinks == .pane && c.mosaicNewPanePlacement == .focused)
        #expect(c.mosaicDefaultLayout.arrangement == .grid && c.mosaicAutoArrange)
    }

    @Test func mosaicMotionAndLookKeysDecode() throws {
        let d = PaddleConfig()
        #expect(d.mosaicAnimation == .system && d.mosaicAnimationSpeed == .smooth && d.mosaicLiveDragPreview)
        #expect(d.mosaicDividerGrips == .always && !d.mosaicDividerSnapping && d.mosaicDividerDoubleClick == .divider)
        #expect(d.mosaicPaneCorners == .rounded && d.mosaicFocusMarker == .ring && d.mosaicDimAmount == 0.25)
        #expect(d.mosaicToolbarSize == .regular && d.mosaicToolbarButtons == MosaicToolbarButton.allCases)
        let json = #"""
        {"mosaicAnimation": "reduced", "mosaicAnimationSpeed": "snappy", "mosaicLiveDragPreview": false,
         "mosaicDividerGrips": "hover", "mosaicDividerSnapping": true, "mosaicDividerDoubleClick": "all",
         "mosaicPaneCorners": "square", "mosaicFocusMarker": "dim", "mosaicDimAmount": 2,
         "mosaicToolbarSize": "compact", "mosaicToolbarButtons": ["close", "back", "close", "teleport"]}
        """#
        let c = try PaddleConfig.decode(Data(json.utf8))
        #expect(c.mosaicAnimation == .reduced && c.mosaicAnimationSpeed == .snappy && !c.mosaicLiveDragPreview)
        #expect(c.mosaicDividerGrips == .hover && c.mosaicDividerSnapping && c.mosaicDividerDoubleClick == .all)
        #expect(c.mosaicPaneCorners == .square && c.mosaicFocusMarker == .dim && c.mosaicDimAmount == 0.7)
        #expect(c.mosaicToolbarSize == .compact && c.mosaicToolbarButtons == [.back, .close])
    }

    @Test func mosaicLookKeysDecodeAndAreKeptInRange() throws {
        let d = PaddleConfig()
        #expect(d.mosaicPaneBars == .always && d.mosaicGap == 6 && d.mosaicMinimumPaneWidth == 260 && d.mosaicMinimumPaneHeight == 160)
        let c = try PaddleConfig.decode(Data(#"{"mosaicPaneBars": "hover", "mosaicGap": 40, "mosaicMinimumPaneWidth": 10.4, "mosaicMinimumPaneHeight": 300}"#.utf8))
        #expect(c.mosaicPaneBars == .hover && c.mosaicGap == 16 && c.mosaicMinimumPaneWidth == 100 && c.mosaicMinimumPaneHeight == 300)
        let odd = try PaddleConfig.decode(Data(#"{"mosaicPaneBars": "sometimes"}"#.utf8))
        #expect(odd.mosaicPaneBars == .always)
    }

    @Test func mosaicReadsTheOldMultiViewKeyAndActionNames() throws {
        let old = try PaddleConfig.decode(Data(#"{"multiViewMaxPanes": 3, "shortcuts": {"toggleSplitView": "cmd+k", "removeFromView": "cmd+j"}}"#.utf8))
        #expect(old.mosaicMaxPanes == 3)
        #expect(old.shortcuts == ["toggleMosaic": "cmd+k", "removeFromMosaic": "cmd+j"])
        let both = try PaddleConfig.decode(Data(#"{"multiViewMaxPanes": 3, "mosaicMaxPanes": 5, "shortcuts": {"toggleSplitView": "cmd+k", "toggleMosaic": "cmd+m"}}"#.utf8))
        #expect(both.mosaicMaxPanes == 5)
        #expect(both.shortcuts == ["toggleMosaic": "cmd+m"])
        #expect(try ConfigFile.unknownKeys(in: Data(#"{"multiViewMaxPanes": 3, "mosaicMaxPanes": 5}"#.utf8)).isEmpty)
    }

    @Test func browsingBehaviourKeysDecodeAndUnknownWordsFallBack() throws {
        let json = #"{"onLaunch": "newWindow", "newTabPosition": "afterCurrent", "openLinksInBackground": false, "afterClosingTab": "lastUsed", "askBeforeQuitting": true, "askBeforeClosingWindow": true, "externalLinks": "currentTab", "fraudWarnings": false, "swipeNavigation": false, "pinchZoom": false, "tabKeyHighlightsLinks": true}"#
        let config = try PaddleConfig.decode(Data(json.utf8))
        #expect(config.onLaunch == .newWindow)
        #expect(config.newTabPosition == .afterCurrent)
        #expect(!config.openLinksInBackground)
        #expect(config.afterClosingTab == .lastUsed)
        #expect(config.askBeforeQuitting && config.askBeforeClosingWindow)
        #expect(config.externalLinks == .currentTab)
        #expect(!config.fraudWarnings && !config.swipeNavigation && !config.pinchZoom)
        #expect(config.tabKeyHighlightsLinks)
        #expect(try PaddleConfig.decode(config.encoded()) == config)

        let (fallback, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"onLaunch": "sometimes", "externalLinks": 3}"#.utf8))
        #expect(fallback.onLaunch == .restore && fallback.externalLinks == .newTab)
        #expect(Set(issues.map(\.path)) == [["onLaunch"], ["externalLinks"]])
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
        #expect(issues.first?.message == "Expected a whole number. Paddle uses the default, 8, until this is fixed.")
        #expect(try PaddleConfig.decode(Data(#"{"maxAwakeTabs": "four"}"#.utf8)).maxAwakeTabs == 8)
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

    @Test func tabFreezeAfterMinutesDefaultsToTwoAndWrongTypeFallsBack() throws {
        #expect(PaddleConfig().tabFreezeAfterMinutes == 2)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"tabFreezeAfterMinutes": "soon"}"#.utf8))
        #expect(config.tabFreezeAfterMinutes == 2)
        #expect(issues.count == 1)
        #expect(issues.first?.path == ["tabFreezeAfterMinutes"])
        #expect(try PaddleConfig.decode(Data(#"{"tabFreezeAfterMinutes": 0}"#.utf8)).tabFreezeAfterMinutes == 0)
    }

    @Test func speculativeLoadingDefaultsToOn() throws {
        #expect(PaddleConfig().speculativeLoading)
        #expect(try PaddleConfig.decode(Data(#"{"speculativeLoading": false}"#.utf8)).speculativeLoading == false)
    }

    @Test func resumeMediaOnSelectDefaultsToOff() throws {
        #expect(PaddleConfig().resumeMediaOnSelect == false)
        #expect(try PaddleConfig.decode(Data(#"{"resumeMediaOnSelect": true}"#.utf8)).resumeMediaOnSelect)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"resumeMediaOnSelect": "yes"}"#.utf8))
        #expect(config.resumeMediaOnSelect == false)
        #expect(issues.first?.path == ["resumeMediaOnSelect"])
    }

    @Test func linkPreviewDefaultsToOnAndWrongTypeFallsBack() throws {
        #expect(PaddleConfig().linkPreview)
        #expect(try PaddleConfig.decode(Data(#"{"linkPreview": false}"#.utf8)).linkPreview == false)
        let (config, issues) = try PaddleConfig.decodeReportingIssues(Data(#"{"linkPreview": "no"}"#.utf8))
        #expect(config.linkPreview)
        #expect(issues.count == 1)
        #expect(issues.first?.path == ["linkPreview"])
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
