import Foundation
@testable import PaddleCore
import Testing

struct OnDemandExtensionTests {
    private func manifest(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func siteExtensionsQualify() throws {
        // Reddit Enhancement Suite's and Return YouTube Dislike's shapes.
        let res = try manifest(#"{"manifest_version": 2, "permissions": ["https://*.reddit.com/*", "cookies", "tabs", "storage", "scripting"], "optional_permissions": ["downloads", "https://*.redd.it/*"], "content_scripts": [{"matches": ["https://*.reddit.com/*"], "js": ["a.js"]}]}"#)
        #expect(OnDemandExtension.sitePatterns(manifest: res) == ["https://*.reddit.com/*"])
        let ryd = try manifest(#"{"permissions": ["activeTab", "*://*.youtube.com/*", "storage", "*://returnyoutubedislikeapi.com/*"], "content_scripts": [{"matches": ["*://*.youtube.com/*"]}]}"#)
        #expect(OnDemandExtension.sitePatterns(manifest: ryd) == ["*://*.youtube.com/*", "*://returnyoutubedislikeapi.com/*"])
        let v3 = try manifest(#"{"manifest_version": 3, "permissions": ["storage"], "host_permissions": ["https://example.com/*"], "content_scripts": [{"matches": ["https://example.com/*"]}]}"#)
        #expect(OnDemandExtension.sitePatterns(manifest: v3) == ["https://example.com/*"])
    }

    @Test(arguments: [
        // Every site, in its scripts or its permissions.
        #"{"content_scripts": [{"matches": ["<all_urls>"]}]}"#,
        #"{"content_scripts": [{"matches": ["https://*/*"]}]}"#,
        #"{"permissions": ["<all_urls>"], "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        #"{"host_permissions": ["http://*/*"], "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        #"{"content_scripts": [{"matches": ["file:///*"]}]}"#,
        // Work beyond its pages.
        #"{"permissions": ["webRequest", "https://a.com/*"], "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        #"{"permissions": ["contextMenus"], "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        #"{"permissions": ["alarms"], "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        #"{"chrome_url_overrides": {"newtab": "n.html"}, "content_scripts": [{"matches": ["https://a.com/*"]}]}"#,
        // No content scripts: nothing ties it to a site.
        #"{"permissions": ["storage"], "background": {"scripts": ["b.js"]}}"#,
    ])
    func othersStayLoaded(_ json: String) throws {
        #expect(OnDemandExtension.sitePatterns(manifest: try manifest(json)) == nil)
    }

    @Test func defaultsOnAndDecodes() throws {
        #expect(PaddleConfig().extensionsOnDemand)
        #expect(try PaddleConfig.decode(Data(#"{"extensionsOnDemand": false}"#.utf8)).extensionsOnDemand == false)
    }
}
