import Foundation
@testable import PaddleCore
import Testing

struct ExtensionManifestTests {
    private let mv3 = Data(#"""
    {
      "manifest_version": 3, "name": "Sample", "version": "1.0",
      "permissions": ["storage", "tabs", "declarativeNetRequest", "futureThing"],
      "optional_permissions": ["cookies"],
      "host_permissions": ["http://127.0.0.1/*"],
      "optional_host_permissions": ["https://example.com/*"],
      "background": {"service_worker": "background.js"},
      "content_scripts": [
        {"matches": ["http://127.0.0.1/*"], "js": ["content.js", "lib/x.js"], "css": ["content.css"]},
        {"matches": ["<all_urls>"], "js": ["content.js"]}
      ],
      "action": {"default_popup": "popup.html?mode=1"},
      "options_ui": {"page": "options.html", "open_in_tab": true},
      "declarative_net_request": {"rule_resources": [{"id": "r", "enabled": true, "path": "rules.json"}]}
    }
    """#.utf8)

    private let mv2 = Data(#"""
    {
      "manifest_version": 2, "name": "Old", "version": "2",
      "permissions": ["tabs", "http://*/*", "https://*.example.com/*", "<all_urls>", "*://*/*", "webRequest"],
      "background": {"scripts": ["a.js", "b.js"], "persistent": false},
      "browser_action": {"default_popup": "p.html"},
      "options_page": "opts.html"
    }
    """#.utf8)

    @Test func mv3Summary() throws {
        let m = try ExtensionManifest(data: mv3)
        #expect(m.permissions == ["cookies", "declarativeNetRequest", "futureThing", "storage", "tabs"])
        #expect(m.backgroundFiles == ["background.js"])
        #expect(m.referencedFiles == ["content.js", "lib/x.js", "content.css", "popup.html", "options.html", "rules.json"])
    }

    @Test func mv2SummaryExcludesHostPatterns() throws {
        let m = try ExtensionManifest(data: mv2)
        #expect(m.permissions == ["tabs", "webRequest"])
        #expect(m.backgroundFiles == ["a.js", "b.js"])
        #expect(m.referencedFiles == ["p.html", "opts.html"])
    }

    @Test func backgroundPageIsABackgroundFile() throws {
        let m = try ExtensionManifest(data: Data(#"{"background": {"page": "bg.html"}}"#.utf8))
        #expect(m.backgroundFiles == ["bg.html"])
    }

    @Test func missingFilesSeparatesBackgroundAndStripsSlash() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PaddleExtManifestTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for file in ["content.js", "popup.html"] { try Data().write(to: dir.appendingPathComponent(file)) }

        let manifest = try ExtensionManifest(data: Data(#"""
        {"background": {"service_worker": "/sw.js"},
         "content_scripts": [{"js": ["/content.js", "lib/missing.js", "../outside.js"], "css": ["lib"]}],
         "action": {"default_popup": "popup.html"}, "options_page": "options.html"}
        """#.utf8))
        let missing = manifest.missingFiles(in: dir)
        #expect(missing.background == ["sw.js"])
        #expect(missing.other == ["lib/missing.js", "../outside.js", "lib", "options.html"])
    }

    @Test func slashPrefixedFilesAreFoundWithoutTheSlash() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PaddleExtManifestTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("sw.js"))
        let manifest = try ExtensionManifest(data: Data(#"{"background": {"service_worker": "/sw.js"}}"#.utf8))
        #expect(manifest.missingFiles(in: dir).background.isEmpty)
        try fm.removeItem(at: dir.appendingPathComponent("sw.js"))
        #expect(manifest.missingFiles(in: dir).background == ["sw.js"])
    }

    @Test func unsupportedPermissionsAreSorted() throws {
        let m = try ExtensionManifest(data: mv3)
        #expect(m.unsupportedPermissions(supported: ["storage", "tabs"]) == ["cookies", "declarativeNetRequest", "futureThing"])
        #expect(m.unsupportedPermissions(supported: Set(m.permissions)).isEmpty)
    }

    @Test func invalidDataThrows() {
        #expect(throws: (any Error).self) { try ExtensionManifest(data: Data("not json".utf8)) }
        #expect(throws: ExtensionManifest.ParseError.notAnObject) { try ExtensionManifest(data: Data("[1,2]".utf8)) }
    }

    @Test func emptyObjectIsEmptySummary() throws {
        let m = try ExtensionManifest(data: Data("{}".utf8))
        #expect(m.permissions.isEmpty && m.backgroundFiles.isEmpty && m.referencedFiles.isEmpty)
    }
}
