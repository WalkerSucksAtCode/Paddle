import Foundation
@testable import PaddleCore
import Testing

struct SettingsLinkTests {
    @Test(arguments: [
        ("paddle://settings", SettingsLink(pane: nil)),
        ("paddle:settings", SettingsLink(pane: nil)),
        ("PADDLE://Settings", SettingsLink(pane: nil)),
        ("  paddle://settings \n", SettingsLink(pane: nil)),
        ("paddle://settings/", SettingsLink(pane: nil)),
        ("paddle://settings?x=1", SettingsLink(pane: nil)),
        ("paddle://settings#privacy", SettingsLink(pane: nil)),
        ("paddle://settings/unknown", SettingsLink(pane: nil)),
        ("paddle://settings/privacy/extra", SettingsLink(pane: nil)),
        ("about:settings", SettingsLink(pane: nil)),
        ("about:settings/", SettingsLink(pane: nil)),
        ("about:preferences", SettingsLink(pane: nil)),
        ("about:preferences#other", SettingsLink(pane: nil)),
        ("chrome://settings", SettingsLink(pane: nil)),
        ("chrome://settings/", SettingsLink(pane: nil)),
        ("chrome://settings/advanced", SettingsLink(pane: nil)),
    ])
    func opensSettingsAtLastPane(input: String, expected: SettingsLink) {
        #expect(SettingsLink.parse(input) == expected)
    }

    @Test(arguments: [
        ("paddle://settings/general", SettingsLink(pane: .general)),
        ("paddle://settings/tabsMemory", SettingsLink(pane: .tabsMemory)),
        ("paddle://settings/tabs", SettingsLink(pane: .tabsMemory)),
        ("paddle://settings/memory", SettingsLink(pane: .tabsMemory)),
        ("paddle://settings/mosaic", SettingsLink(pane: .mosaic)),
        ("paddle://settings/privacy", SettingsLink(pane: .privacy)),
        ("paddle://settings/blocking", SettingsLink(pane: .privacy)),
        ("paddle://settings/contentblocking", SettingsLink(pane: .privacy)),
        ("paddle://settings/adblock", SettingsLink(pane: .privacy)),
        ("paddle://settings/sites", SettingsLink(pane: .sites)),
        ("paddle://settings/site/", SettingsLink(pane: .sites)),
        ("paddle://settings/extensions", SettingsLink(pane: .extensions)),
        ("paddle://settings/addons", SettingsLink(pane: .extensions)),
        ("paddle://settings/shortcuts", SettingsLink(pane: .shortcuts)),
        ("paddle://settings/keyboard", SettingsLink(pane: .shortcuts)),
        ("paddle://settings/keys", SettingsLink(pane: .shortcuts)),
        ("paddle://settings/advanced", SettingsLink(pane: .advanced)),
        ("paddle://general", SettingsLink(pane: .general)),
        ("paddle://tabs", SettingsLink(pane: .tabsMemory)),
        ("paddle://adblock", SettingsLink(pane: .privacy)),
        ("paddle://EXTENSIONS/", SettingsLink(pane: .extensions)),
        ("paddle://keys", SettingsLink(pane: .shortcuts)),
        ("paddle://advanced", SettingsLink(pane: .advanced)),
    ])
    func opensPaddlePane(input: String, expected: SettingsLink) {
        #expect(SettingsLink.parse(input) == expected)
    }

    @Test(arguments: [
        ("about:preferences#privacy", SettingsLink(pane: .privacy)),
        ("about:preferences#general", SettingsLink(pane: .general)),
        ("about:preferences#search", SettingsLink(pane: .general)),
        ("ABOUT:PREFERENCES#Privacy", SettingsLink(pane: .privacy)),
        ("about:preferences#nonsense", SettingsLink(pane: nil)),
        ("chrome://settings/privacy", SettingsLink(pane: .privacy)),
        ("chrome://settings/privacy/?x=1#top", SettingsLink(pane: .privacy)),
        ("chrome://settings/search", SettingsLink(pane: .general)),
        ("about:addons", SettingsLink(pane: .extensions)),
        ("chrome://extensions", SettingsLink(pane: .extensions)),
        ("chrome://extensions/", SettingsLink(pane: .extensions)),
        ("chrome://extensions/shortcuts", SettingsLink(pane: .extensions)),
    ])
    func opensOtherBrowsersPages(input: String, expected: SettingsLink) {
        #expect(SettingsLink.parse(input) == expected)
    }

    @Test(arguments: [
        "",
        "   ",
        "settings",
        "Settings",
        "paddle://",
        "paddle:",
        "paddle://foo",
        "paddle:privacy",
        "paddle://settings.example",
        "paddle://unknown/settings",
        "chrome://flags",
        "chrome://extensionsx",
        "about:blank",
        "about:config",
        "about:settings.html",
        "https://example.com/settings",
        "http://paddle://settings",
        "example.com/settings",
        "file:///settings",
    ])
    func ignoresEverythingElse(input: String) {
        #expect(SettingsLink.parse(input) == nil)
    }
}
