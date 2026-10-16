import Foundation
import Testing
@testable import PaddleCore

struct ExtensionWebAccessTests {
    @Test func manifestV2StarExposesOnlyTheMatchedTree() {
        let manifest: [String: Any] = ["web_accessible_resources": ["resources/*"]]
        #expect(ExtensionWebAccess.isReachable(path: "resources/youtube-main-start.js", manifest: manifest, pageURL: nil))
        #expect(ExtensionWebAccess.isReachable(path: "/resources/vendor/themes/a.css", manifest: manifest, pageURL: nil))
        #expect(!ExtensionWebAccess.isReachable(path: "js/background.js", manifest: manifest, pageURL: nil))
        #expect(!ExtensionWebAccess.isReachable(path: "manifest.json", manifest: manifest, pageURL: nil))
        #expect(!ExtensionWebAccess.isReachable(path: "resources/../manifest.json", manifest: manifest, pageURL: nil))
    }

    @Test func manifestV3RequiresThePageToMatch() throws {
        let manifest: [String: Any] = [
            "web_accessible_resources": [
                ["resources": ["injected.js"], "matches": ["*://www.youtube.com/*"]],
            ],
        ]
        let youtube = try #require(URL(string: "https://www.youtube.com/watch?v=1"))
        let other = try #require(URL(string: "https://example.com/"))
        #expect(ExtensionWebAccess.isReachable(path: "injected.js", manifest: manifest, pageURL: youtube))
        #expect(!ExtensionWebAccess.isReachable(path: "injected.js", manifest: manifest, pageURL: other))
        #expect(!ExtensionWebAccess.isReachable(path: "injected.js", manifest: manifest, pageURL: nil))
        #expect(!ExtensionWebAccess.isReachable(path: "other.js", manifest: manifest, pageURL: youtube))
    }

    @Test func scriptPathKeepsExtensionJavaScriptOnly() throws {
        let script = try #require(URL(string: "moz-extension://82c09bd7-d175-14c6-53f7-f536bdd19334/resources/youtube-main-start.js"))
        #expect(ExtensionWebAccess.scriptPath(of: script) == "resources/youtube-main-start.js")
        let css = try #require(URL(string: "moz-extension://82c09bd7-d175-14c6-53f7-f536bdd19334/resources/youtube.css"))
        #expect(ExtensionWebAccess.scriptPath(of: css) == nil)
        let page = try #require(URL(string: "https://www.youtube.com/s.js"))
        #expect(ExtensionWebAccess.scriptPath(of: page) == nil)
        let escaped = try #require(URL(string: "webkit-extension://abc/resources/%2e%2e/manifest.js"))
        #expect(ExtensionWebAccess.scriptPath(of: escaped) == nil)
    }
}
