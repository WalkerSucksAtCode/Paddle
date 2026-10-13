import Foundation
@testable import PaddleCore
import Testing

struct ExtensionBlockingTests {
    /// uBlock Origin's MV2 build: blocks through webRequestBlocking listeners, with no rule files.
    private let uboMV2 = Data(#"""
    {
      "manifest_version": 2, "name": "uBlock Origin", "version": "1.60.0",
      "permissions": ["alarms", "contextMenus", "menus", "privacy", "storage", "tabs", "unlimitedStorage",
                      "webNavigation", "webRequest", "webRequestBlocking", "<all_urls>", "http://*/*", "https://*/*"],
      "background": {"scripts": ["background.js"], "persistent": true},
      "browser_action": {"default_popup": "popup.html"},
      "content_scripts": [{"matches": ["<all_urls>"], "js": ["js/contentscript.js"]}],
      "options_page": "options.html"
    }
    """#.utf8)

    /// uBlock Origin Lite, MV3: blocks with declarativeNetRequest rule files.
    private let uboLite = Data(#"""
    {
      "manifest_version": 3, "name": "uBlock Origin Lite", "version": "2025.1",
      "permissions": ["declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess",
                      "scripting", "storage", "tabs", "alarms", "contextMenus", "menus", "unlimitedStorage", "webNavigation"],
      "host_permissions": ["<all_urls>"],
      "background": {"service_worker": "js/background.js"},
      "declarative_net_request": {"rule_resources": [
        {"id": "ublock-filters", "enabled": true, "path": "rulesets/ublock-filters.json"},
        {"id": "easylist", "enabled": false, "path": "rulesets/easylist.json"}
      ]},
      "action": {"default_popup": "popup.html"}
    }
    """#.utf8)

    /// An extension that neither blocks nor asks to.
    private let plain = Data(#"""
    {"manifest_version": 3, "name": "Plain", "version": "1.0", "permissions": ["storage", "tabs"],
     "background": {"service_worker": "bg.js"}}
    """#.utf8)

    private func blocking(_ json: String) throws -> ExtensionBlocking {
        ExtensionBlocking(manifest: try ExtensionManifest(data: Data(json.utf8)))
    }

    @Test func webRequestBlockingExtensionIsNamedAsUnable() throws {
        let manifest = try ExtensionManifest(data: uboMV2)
        let blocking = ExtensionBlocking(manifest: manifest)
        #expect(blocking == .webRequestBlockingOnly)
        #expect(blocking.notice == "Asks to block or change requests (webRequestBlocking), which WebKit doesn't allow: anything it would block or change still loads. Paddle's own content blocking still runs.")
    }

    @Test func declarativeNetRequestExtensionIsNotNamedAsUnable() throws {
        let manifest = try ExtensionManifest(data: uboLite)
        #expect(manifest.ruleResources == ["rulesets/ublock-filters.json", "rulesets/easylist.json"])
        #expect(ExtensionBlocking(manifest: manifest) == .declarativeNetRequest)
        #expect(ExtensionBlocking(manifest: manifest).notice == nil)
    }

    @Test func plainExtensionBlocksNothingAndSaysNothing() throws {
        let blocking = ExtensionBlocking(manifest: try ExtensionManifest(data: plain))
        #expect(blocking == .none)
        #expect(blocking.notice == nil)
    }

    /// Asking for webRequestBlocking only as an optional permission still means it can't block.
    @Test func optionalWebRequestBlockingCounts() throws {
        #expect(try blocking(#"{"manifest_version": 2, "optional_permissions": ["webRequestBlocking"]}"#) == .webRequestBlockingOnly)
    }

    /// The declarativeNetRequest permission without rule files doesn't count as enforcing rules, so it is not claimed.
    @Test func declarativeNetRequestWithoutRuleFilesIsNotClaimed() throws {
        #expect(try blocking(#"{"manifest_version": 3, "permissions": ["declarativeNetRequest"]}"#) == .none)
        // Asking for webRequestBlocking too: no rule files, so the webRequestBlocking line applies.
        #expect(try blocking(#"{"manifest_version": 3, "permissions": ["declarativeNetRequest", "webRequestBlocking"]}"#)
            == .webRequestBlockingOnly)
    }

    /// The host-access variant is a declarativeNetRequest permission too.
    @Test func declarativeNetRequestWithHostAccessWithRulesCounts() throws {
        let json = #"""
        {"manifest_version": 3, "permissions": ["declarativeNetRequestWithHostAccess"],
         "declarative_net_request": {"rule_resources": [{"id": "r", "enabled": true, "path": "rules.json"}]}}
        """#
        #expect(try blocking(json) == .declarativeNetRequest)
    }

    /// Rule files without the permission are not enforced, so they don't make an extension a blocker.
    @Test func ruleFilesWithoutThePermissionDoNotCount() throws {
        let json = #"""
        {"manifest_version": 3, "permissions": ["storage"],
         "declarative_net_request": {"rule_resources": [{"id": "r", "enabled": true, "path": "rules.json"}]}}
        """#
        #expect(try blocking(json) == .none)
    }

    /// With rule files and webRequestBlocking both, WebKit applies the rules, so the extension does block.
    @Test func rulesBeatWebRequestBlocking() throws {
        let json = #"""
        {"manifest_version": 3, "permissions": ["declarativeNetRequest", "webRequestBlocking"],
         "declarative_net_request": {"rule_resources": [{"id": "r", "enabled": true, "path": "rules.json"}]}}
        """#
        #expect(try blocking(json) == .declarativeNetRequest)
    }
}
