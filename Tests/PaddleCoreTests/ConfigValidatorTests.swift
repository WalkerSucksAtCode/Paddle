import Foundation
@testable import PaddleCore
import Testing

struct ConfigValidatorTests {
    let actions: Set<String> = ["newTab", "nextTab", "previousTab", "closeTab"]

    func issues(_ config: PaddleConfig) -> [ConfigIssue] { ConfigValidator.issues(config, actionNames: actions) }

    func paths(_ config: PaddleConfig, _ severity: ConfigIssue.Severity) -> [String] {
        issues(config).filter { $0.severity == severity }.map { $0.path.joined(separator: ".") }
    }

    @Test func defaultsAreClean() {
        #expect(issues(PaddleConfig()).isEmpty)
    }

    @Test func searchTemplateWithoutPlaceholderIsAnError() {
        var config = PaddleConfig()
        config.searchTemplate = "https://duckduckgo.com/?q="
        #expect(paths(config, .error) == ["searchTemplate"])
        #expect(ConfigValidator.blocks(.searchTemplate, in: issues(config)))
        #expect(issues(config).first?.message.contains("%s") == true)
    }

    @Test func suggestTemplateWithoutPlaceholderIsAnErrorButEmptyIsOff() {
        var config = PaddleConfig()
        config.searchSuggestTemplate = "https://duckduckgo.com/ac/"
        #expect(paths(config, .error) == ["searchSuggestTemplate"])
        #expect(SearchSuggestions.requestURL(template: config.searchSuggestTemplate, query: "a") == nil)
        config.searchSuggestTemplate = ""
        #expect(issues(config).isEmpty)
    }

    @Test func nonWebSearchTemplateWarns() {
        var config = PaddleConfig()
        config.searchTemplate = "ftp://example.com/?q=%s"
        #expect(paths(config, .warning) == ["searchTemplate"])
        #expect(!ConfigValidator.blocks(.searchTemplate, in: issues(config)))
    }

    @Test func pagesMustBeURLs() {
        var config = PaddleConfig()
        config.homepage = "not a url"
        config.newTabPage = "gopher://example.com/"
        #expect(paths(config, .error) == ["homepage"])
        #expect(paths(config, .warning) == ["newTabPage"])
        config.homepage = "file:///Users/me/start.html"
        config.newTabPage = "about:blank"
        #expect(issues(config).isEmpty)
    }

    @Test func negativeNumbersAreErrors() {
        var config = PaddleConfig()
        config.historyDays = -1
        config.tabSleepAfterMinutes = -0.5
        config.maxAwakeTabs = -3
        config.filterUpdateDays = -7
        #expect(paths(config, .error) == ["historyDays", "tabSleepAfterMinutes", "maxAwakeTabs", "filterUpdateDays"])
        config = PaddleConfig()
        config.historyDays = 0
        config.tabSleepAfterMinutes = 0
        #expect(issues(config).isEmpty)
    }

    @Test func cpuSleepPercentIsZeroToEightHundred() {
        var config = PaddleConfig()
        config.cpuSleepPercent = -1
        #expect(paths(config, .error) == ["cpuSleepPercent"])
        config.cpuSleepPercent = 801
        #expect(paths(config, .error) == ["cpuSleepPercent"])
        config.cpuSleepPercent = 800
        #expect(issues(config).isEmpty)
        config.cpuSleepPercent = 0
        #expect(issues(config).isEmpty)
    }

    @Test func filterListsMustBeHTTPS() {
        var config = PaddleConfig()
        config.filterLists = ["https://easylist.to/easylist/easylist.txt", "http://example.com/list.txt", "easylist"]
        #expect(paths(config, .warning) == ["filterLists.1", "filterLists.2"])
        #expect(paths(config, .error).isEmpty)
    }

    @Test func emptySiteUserAgentWarns() {
        var config = PaddleConfig()
        config.siteUserAgents = ["example.com": "", "other.example": "UA"]
        #expect(paths(config, .warning) == ["siteUserAgents.example.com"])
    }

    @Test func aUserAgentAndAPersonaForOneHostWarn() {
        var config = PaddleConfig()
        config.siteUserAgents = ["Example.com": "UA", "empty.example": "", "fine.example": "UA"]
        config.sitePersonas = ["example.com.": .chrome, "empty.example": .firefox]
        // An empty user agent is no override, so only the non-empty one overlaps the persona.
        #expect(paths(config, .warning) == ["siteUserAgents.empty.example", "siteUserAgents.Example.com"])
        let message = issues(config).first { $0.path == ["siteUserAgents", "Example.com"] }?.message
        #expect(message == "\"Example.com\" has both a user agent (siteUserAgents) and a persona (sitePersonas): the site gets the user agent string but the persona's JavaScript identity. Remove one.")
        #expect(paths(config, .error).isEmpty)
    }

    @Test func siteZoomMustBePositive() {
        var config = PaddleConfig()
        config.sites = ["example.com": SiteSettings(zoom: 0), "fine.example": SiteSettings(zoom: 1.5), "": SiteSettings(javaScript: false)]
        #expect(paths(config, .error) == ["sites.example.com.zoom"])
        #expect(paths(config, .warning) == ["sites."])
        #expect(ConfigValidator.blocks(.sites, in: issues(config)))
    }

    @Test func twoSpellingsOfOneHostWarn() {
        var config = PaddleConfig()
        config.sites = ["Example.com": SiteSettings(javaScript: false), "example.com.": SiteSettings(zoom: 1.5), "other.example": SiteSettings()]
        config.siteUserAgents = ["bücher.de": "UA", "xn--bcher-kva.de": "UA2"]
        config.sitePersonas = ["a.example": .chrome, "A.example": .firefox]
        #expect(paths(config, .warning) == [
            "siteUserAgents.bücher.de", "siteUserAgents.xn--bcher-kva.de",
            "sites.Example.com", "sites.example.com.",
            "sitePersonas.A.example", "sitePersonas.a.example",
        ])
        let message = issues(config).first { $0.path == ["siteUserAgents", "bücher.de"] }?.message
        #expect(message == "\"bücher.de\" and \"xn--bcher-kva.de\" are the same site; only one applies.")
        #expect(paths(config, .error).isEmpty)
    }

    @Test func shortcutWithoutCommandOrControlWarns() {
        var config = PaddleConfig()
        config.shortcuts = ["closeTab": "x", "newTab": "f6", "nextTab": "shift+option+k"]
        #expect(paths(config, .warning) == ["shortcuts.closeTab", "shortcuts.nextTab"])
        #expect(paths(config, .error).isEmpty)
        let message = issues(config).first { $0.path == ["shortcuts", "closeTab"] }?.message
        #expect(message == "X has no ⌘ or ⌃, so it would take a typed character. Add cmd or ctrl (F keys may stand alone).")
    }

    @Test func shortcutsNeedKnownActionsAndParsableKeys() {
        var config = PaddleConfig()
        config.shortcuts = ["nextTab": "cmd+option+right", "typo": "cmd+k", "closeTab": "hyper+w", "newTab": "none"]
        #expect(paths(config, .error) == ["shortcuts.closeTab"])
        // An unknown name is skipped by the app (a renamed action leaves one behind), so it must not block the key.
        #expect(paths(config, .warning) == ["shortcuts.typo"])
        #expect(issues(config).map(\.key) == [.shortcuts, .shortcuts])
        #expect(ConfigValidator.blocks(.shortcuts, in: issues(config)))
    }

    @Test func blockingCanBeScopedToOneEntry() {
        var config = PaddleConfig()
        config.shortcuts = ["closeTab": "hyper+w"]
        config.sites = ["bad.example": SiteSettings(zoom: 0), "fine.example": SiteSettings(zoom: 1)]
        let found = issues(config)
        #expect(ConfigValidator.blocks(.shortcuts, path: ["shortcuts", "closeTab"], in: found))
        #expect(!ConfigValidator.blocks(.shortcuts, path: ["shortcuts", "newTab"], in: found))
        #expect(ConfigValidator.blocks(.sites, path: ["sites", "bad.example"], in: found))
        #expect(ConfigValidator.blocks(.sites, path: ["sites", "bad.example", "zoom"], in: found))
        #expect(!ConfigValidator.blocks(.sites, path: ["sites", "fine.example"], in: found))
        #expect(ConfigValidator.blocks(.sites, path: ["sites"], in: found))
        #expect(!ConfigValidator.blocks(.searchTemplate, path: ["searchTemplate"], in: found))
    }

    @Test func overrideTakingADefaultKeyWarns() {
        let defaults: [String: [Shortcut]] = [
            "newTab": [Shortcut.parse("cmd+t")!],
            "nextTab": [Shortcut.parse("ctrl+tab")!, Shortcut.parse("cmd+shift+]")!],
            "previousTab": [Shortcut.parse("ctrl+shift+tab")!, Shortcut.parse("cmd+shift+[")!],
        ]
        var config = PaddleConfig()
        config.shortcuts = ["closeTab": "cmd+t"]
        var found = ConfigValidator.issues(config, actionNames: actions, defaults: defaults)
        #expect(found.map { $0.path.joined(separator: ".") } == ["shortcuts.closeTab"])
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("closeTab, newTab") == true)

        // The shifted spelling of a hidden alias is the same key.
        config.shortcuts = ["closeTab": "cmd+shift+{"]
        found = ConfigValidator.issues(config, actionNames: actions, defaults: defaults)
        #expect(found.map { $0.path.joined(separator: ".") } == ["shortcuts.closeTab"])

        // Rebinding the action that owned the key, or clearing it, frees it.
        config.shortcuts = ["closeTab": "cmd+t", "newTab": "cmd+n"]
        #expect(ConfigValidator.issues(config, actionNames: actions, defaults: defaults).isEmpty)
        config.shortcuts = ["closeTab": "cmd+shift+[", "previousTab": "none"]
        #expect(ConfigValidator.issues(config, actionNames: actions, defaults: defaults).isEmpty)
    }

    @Test func hostKeysThatCanNeverMatchWarn() {
        var config = PaddleConfig()
        config.sites = ["https://example.com": SiteSettings(zoom: 1), "localhost:8080": SiteSettings(zoom: 1), "*.example.com": SiteSettings(zoom: 1), "ok.example": SiteSettings(zoom: 1)]
        config.siteUserAgents = ["example.com/app": "UA", "two words": "UA", "fine.example": "UA"]
        #expect(paths(config, .warning) == [
            "siteUserAgents.example.com/app", "siteUserAgents.two words",
            "sites.*.example.com", "sites.https://example.com", "sites.localhost:8080",
        ])
        #expect(paths(config, .error).isEmpty)
    }

    @Test func sameKeyTwiceWarnsOnBoth() {
        var config = PaddleConfig()
        config.shortcuts = ["nextTab": "cmd+shift+k", "previousTab": "shift+cmd+k", "newTab": "none", "closeTab": "none"]
        let warnings = issues(config).filter { $0.severity == .warning }
        #expect(warnings.map { $0.path.joined(separator: ".") } == ["shortcuts.nextTab", "shortcuts.previousTab"])
        #expect(warnings.first?.message.contains("⇧⌘K") == true)
        #expect(paths(config, .error).isEmpty)
    }
}
