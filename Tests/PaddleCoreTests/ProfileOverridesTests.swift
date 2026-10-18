import Foundation
@testable import PaddleCore
import Testing

struct ProfileOverridesTests {
    private func effective(_ global: String, _ overrides: [String: JSONValue]) throws -> (config: PaddleConfig, issues: [ConfigIssue]) {
        try ProfileOverrides.effectiveConfig(globalData: Data(global.utf8), overrides: overrides)
    }

    @Test func everyOverridableKeyIsAConfigKey() {
        let configKeys = Set(PaddleConfig.CodingKeys.allCases.map(\.rawValue))
        #expect(ProfileOverrides.keys.isSubset(of: configKeys))
        #expect(!ProfileOverrides.keys.contains("sites"))
        // Shared by every profile: the content controller's inputs and the cross-window cap.
        for shared in ["contentBlocking", "filterLists", "sitePersonas", "siteUserAgents", "maxAwakeTabs", "appearance", "shortcuts", "extensions"] {
            #expect(!ProfileOverrides.keys.contains(shared))
        }
        #expect(ProfileOverrides.siteFields.isSubset(of: Set(ConfigFile.siteFieldDefaults.keys).union(["zoom"])))
        #expect(!ProfileOverrides.siteFields.contains("contentBlocking"))
        #expect(!ProfileOverrides.siteFields.contains("darkMode"))
    }

    @Test func unsetKeysInheritAndSetKeysReplace() throws {
        let result = try effective(#"{"tabSleepAfterMinutes": 45, "homepage": "https://a.example", "linkPreview": false}"#,
                                   ["tabSleepAfterMinutes": 5, "searchTemplate": "https://s.example/?q=%s"])
        #expect(result.config.tabSleepAfterMinutes == 5)
        #expect(result.config.searchTemplate == "https://s.example/?q=%s")
        #expect(result.config.homepage == "https://a.example")
        #expect(result.config.linkPreview == false)
        #expect(result.issues.isEmpty)
    }

    @Test func emptyGlobalFileReadsAsDefaults() throws {
        let result = try effective("", ["keepNotifyingSitesLive": false])
        #expect(result.config.keepNotifyingSitesLive == false)
        #expect(result.config.homepage == PaddleConfig().homepage)
    }

    @Test func sharedKeysAreIgnored() throws {
        let result = try effective(#"{"maxAwakeTabs": 7}"#, ["maxAwakeTabs": 2, "contentBlocking": false, "bogus": 1])
        #expect(result.config.maxAwakeTabs == 7)
        #expect(result.config.contentBlocking == PaddleConfig().contentBlocking)
        #expect(ProfileOverrides.sanitized(["maxAwakeTabs": 2, "bogus": 1, "linkPreview": true]).dropped == ["bogus", "maxAwakeTabs"])
    }

    @Test func sitesMergePerHostAndField() throws {
        let global = #"{"sites": {"a.example": {"zoom": 1.5, "javaScript": false}, "b.example": {"popups": true}}}"#
        let overrides: [String: JSONValue] = ["sites": ["a.example": ["zoom": 0.8, "contentBlocking": false], "c.example": ["freeze": "never"]]]
        let config = try effective(global, overrides).config
        #expect(config.sites["a.example"] == SiteSettings(zoom: 0.8, javaScript: false))
        #expect(config.sites["b.example"] == SiteSettings(popups: true))
        #expect(config.sites["c.example"] == SiteSettings(freeze: .never))
        #expect(ProfileOverrides.sanitized(overrides).dropped == ["sites.a.example.contentBlocking"])
    }

    @Test func wrongTypedOverrideIsReportedNotGlobalOnes() throws {
        let result = try effective(#"{"historyDays": "lots"}"#, ["linkPreview": "yes"])
        #expect(result.issues.map(\.path) == [["linkPreview"]])
        #expect(result.config.linkPreview == PaddleConfig().linkPreview)
    }

    @Test func invalidGlobalFileThrows() {
        #expect(throws: (any Error).self) { try effective("[1]", [:]) }
        #expect(throws: (any Error).self) { try effective("{", [:]) }
    }

    @Test func settingAndRemovingPaths() {
        var settings: [String: JSONValue] = [:]
        settings = ProfileOverrides.setting(settings, path: ["sites", "x.example", "zoom"], to: 1.25)!
        settings = ProfileOverrides.setting(settings, path: ["theme"], to: "ocean")!
        #expect(settings == ["theme": "ocean", "sites": ["x.example": ["zoom": 1.25]]])
        #expect(ProfileOverrides.entries(settings).map(\.path) == [["theme"], ["sites", "x.example", "zoom"]])
        settings = ProfileOverrides.setting(settings, path: ["sites", "x.example", "zoom"], to: nil)!
        #expect(settings == ["theme": "ocean"])
        #expect(ProfileOverrides.setting(settings, path: ["maxAwakeTabs"], to: 3) == nil)
        #expect(ProfileOverrides.setting(settings, path: ["sites", "x.example", "darkMode"], to: true) == nil)
    }

    @Test func profilesFileRoundTripsSettings() throws {
        var file = ProfilesFile()
        let work = file.add(name: "Work", symbol: .work)
        let set = [
            file.setOverride(["tabFreezeAfterMinutes"], to: 2, for: work.id),
            file.setOverride(["searchTemplate"], to: "https://s.example/?q=%s", for: ProfilesFile.defaultID),
            file.setOverride(["filterLists"], to: [], for: work.id),
            file.setOverride(["theme"], to: "ocean", for: "nope"),
        ]
        #expect(set == [true, true, false, false])
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"tabFreezeAfterMinutes\" : 2"))
        let decoded = try ProfilesFile.decode(data)
        #expect(decoded == file)
        #expect(decoded.profile(id: work.id)?.settings == ["tabFreezeAfterMinutes": 2])
    }

    @Test func profileWithoutSettingsWritesNoSettingsKey() throws {
        let text = String(decoding: try ProfilesFile().encoded(), as: UTF8.self)
        #expect(!text.contains("settings"))
    }

    @Test func badSettingsValueKeepsTheProfile() throws {
        let file = try ProfilesFile.decode(Data(#"{"profiles":[{"id":"default","name":"Me","settings":5}]}"#.utf8))
        #expect(file.profiles[0].name == "Me")
        #expect(file.profiles[0].settings.isEmpty)
    }

    @Test func everyProfileCanBeRenamedIncludingTheDefault() {
        var file = ProfilesFile()
        let work = file.add(name: "Work", symbol: .work)
        let renamed = [
            file.rename(id: ProfilesFile.defaultID, to: "Home"),
            file.rename(id: work.id, to: "Job"),
            file.rename(id: work.id, to: "home"),
        ]
        #expect(renamed == [true, true, false])
        #expect(file.profiles.map(\.name) == ["Home", "Job"])
    }

    @Test func globalValuesAndDescriptions() throws {
        let config = try PaddleConfig.decode(Data(#"{"tabSleepAfterMinutes": 0, "sites": {"x.example": {"javaScript": false}}, "defaultZoom": 1.1}"#.utf8))
        #expect(ProfileOverrides.value(at: ["tabSleepAfterMinutes"], in: config) == 0)
        #expect(ProfileOverrides.value(at: ["sites", "www.x.example", "javaScript"], in: config) == false)
        #expect(ProfileOverrides.value(at: ["sites", "y.example", "zoom"], in: config) == 1.1)
        let sleep = ProfileOverrides.setting(key: "tabSleepAfterMinutes")!.kind
        #expect(ProfileOverrides.describe(0, as: sleep) == "Off")
        #expect(ProfileOverrides.describe(30, as: sleep) == "30 min")
        #expect(ProfileOverrides.describe(true, as: .toggle) == "On")
        #expect(ProfileOverrides.describe("none", as: .color(automatic: "none")) == "Automatic")
        let search = ProfileOverrides.setting(key: "searchTemplate")!.kind
        #expect(ProfileOverrides.describe(.string(SearchEngine.presets[0].searchTemplate), as: search) == SearchEngine.presets[0].name)
    }
}
