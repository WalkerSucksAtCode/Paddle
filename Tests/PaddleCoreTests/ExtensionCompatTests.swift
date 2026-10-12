import Foundation
@testable import PaddleCore
import Testing

struct ExtensionCompatTests {
    /// The shape of Proton Pass's Firefox manifest: background scripts, three content scripts, a gecko id.
    static let firefox = """
    {
      "name": "Sample: \\"Pass\\"",
      "version": "1.41.1",
      "manifest_version": 3,
      "background": {
        "scripts": [
          "background.js"
        ]
      },
      "content_security_policy": {
        "extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
      },
      "content_scripts": [
        {
          "matches": [
            "https://*/*",
            "http://*/*"
          ],
          "js": [
            "orchestrator.js"
          ],
          "all_frames": true,
          "run_at": "document_end"
        },
        {
          "matches": ["https://*/*"],
          "js": ["webauthn.js"],
          "run_at": "document_start",
          "world": "MAIN"
        }
      ],
      "permissions": ["storage", "webRequest"],
      "action": {
        "default_popup": "popup.html",
        "default_icon": {"16": "/assets/icon-16.png"}
      },
      "web_accessible_resources": [{"resources": ["*.wasm", "tricky[{\\"}]"], "matches": ["<all_urls>"]}],
      "browser_specific_settings": {
        "gecko": {
          "id": "78272b6fa58f4a1abaac99321d503a20@proton.me",
          "strict_min_version": "109.0"
        }
      }
    }
    """

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func preludeGoesFirstInBackgroundAndEachOwnContentScript() throws {
        let patch = try ExtensionCompat.patchManifest(Data(Self.firefox.utf8))
        #expect(patch.backgroundPatched)
        #expect(patch.contentScriptsPatched)
        #expect(patch.unpatchedBackground == nil)
        let root = try object(patch.data)
        let scripts = (root["background"] as? [String: Any])?["scripts"] as? [String]
        #expect(scripts == ["paddle-prelude.js", "background.js"])
        let entries = try #require(root["content_scripts"] as? [[String: Any]])
        #expect(entries.count == 2, "no entry is added")
        #expect(entries[0]["js"] as? [String] == ["paddle-prelude.js", "orchestrator.js"])
        #expect(entries[0]["run_at"] as? String == "document_end")
        #expect(entries[1]["js"] as? [String] == ["webauthn.js"], "a MAIN-world script runs in the page's world: left alone")
    }

    @Test func requestedHostsStayExactlyTheSame() throws {
        let narrow = """
        {"manifest_version": 3, "background": {"scripts": ["bg.js"]}, "host_permissions": ["https://example.com/*"],
         "content_scripts": [{"matches": ["https://example.com/*"], "exclude_matches": ["https://example.com/x/*"], "js": ["a.js", "b.js"]},
                             {"matches": ["https://example.org/*"], "css": ["only.css"]}]}
        """
        for source in [Self.firefox, narrow, #"{"manifest_version": 3, "permissions": ["storage"]}"#] {
            let before = try object(Data(source.utf8))
            let patch = try ExtensionCompat.patchManifest(Data(source.utf8))
            let after = try object(patch.data)
            #expect(ExtensionCompat.contentScriptPatterns(manifest: after) == ExtensionCompat.contentScriptPatterns(manifest: before))
            #expect((after["content_scripts"] as? [Any])?.count == (before["content_scripts"] as? [Any])?.count)
            #expect(after["host_permissions"] as? [String] == before["host_permissions"] as? [String])
        }
        let entries = try #require(try object(ExtensionCompat.patchManifest(Data(narrow.utf8)).data)["content_scripts"] as? [[String: Any]])
        #expect(entries[0]["js"] as? [String] == ["paddle-prelude.js", "a.js", "b.js"])
        #expect(entries[1]["js"] == nil, "a CSS-only entry gets no script world")
    }

    @Test func everyOtherByteIsPreserved() throws {
        let patched = try ExtensionCompat.patchManifest(Data(Self.firefox.utf8)).data
        var text = try #require(String(data: patched, encoding: .utf8))
        #expect(text.components(separatedBy: "\"paddle-prelude.js\"").count == 3)
        text = text.replacingOccurrences(of: "\n      \"paddle-prelude.js\",", with: "")
        text = text.replacingOccurrences(of: "\n        \"paddle-prelude.js\",", with: "")
        #expect(text == Self.firefox)
        let root = try object(patched)
        #expect(root["name"] as? String == "Sample: \"Pass\"")
        let resources = ((root["web_accessible_resources"] as? [[String: Any]])?.first?["resources"] as? [String]) ?? []
        #expect(resources == ["*.wasm", "tricky[{\"}]"])
    }

    @Test func idempotent() throws {
        let once = try ExtensionCompat.patchManifest(Data(Self.firefox.utf8))
        let twice = try ExtensionCompat.patchManifest(once.data)
        #expect(twice.data == once.data)
        #expect(twice.backgroundPatched && twice.contentScriptsPatched)
        let scripts = (try object(twice.data)["background"] as? [String: Any])?["scripts"] as? [String]
        #expect(scripts?.filter { $0 == "paddle-prelude.js" }.count == 1)
    }

    @Test func serviceWorkerIsLeftAlone() throws {
        let source = """
        {"manifest_version": 3, "background": {"service_worker": "sw.js"}, "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"]}]}
        """
        let patch = try ExtensionCompat.patchManifest(Data(source.utf8))
        #expect(!patch.backgroundPatched)
        #expect(patch.unpatchedBackground == .serviceWorker)
        #expect(patch.contentScriptsPatched)
        let text = try #require(String(data: patch.data, encoding: .utf8))
        #expect(text.contains(#""background": {"service_worker": "sw.js"}"#))
        let entries = try #require(try object(patch.data)["content_scripts"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["js"] as? [String] == ["paddle-prelude.js", "c.js"])
    }

    @Test func emptyScriptsNextToAWorkerOrPageStayEmpty() throws {
        // WebKit prefers a non-empty `scripts` over `service_worker`; filling an empty one would replace the worker.
        let worker = try ExtensionCompat.patchManifest(Data(#"{"background": {"service_worker": "sw.js", "scripts": []}}"#.utf8))
        #expect(!worker.backgroundPatched && worker.unpatchedBackground == .serviceWorker && !worker.preludeApplied)
        #expect(((try object(worker.data)["background"] as? [String: Any])?["scripts"] as? [Any])?.isEmpty == true)

        let page = try ExtensionCompat.patchManifest(Data(#"{"manifest_version": 2, "background": {"page": "bg.html", "scripts": []}}"#.utf8))
        #expect(!page.backgroundPatched && page.unpatchedBackground == .page)

        let empty = try ExtensionCompat.patchManifest(Data(#"{"manifest_version": 2, "background": {"scripts": []}}"#.utf8))
        #expect(!empty.backgroundPatched && empty.unpatchedBackground == nil && !empty.preludeApplied)
    }

    @Test func noContentScriptsMeansNoneAdded() throws {
        let source = """
        {
          "manifest_version": 2,
          "background": {"scripts": ["bg.js"]}
        }
        """
        let patch = try ExtensionCompat.patchManifest(Data(source.utf8))
        #expect(patch.backgroundPatched && !patch.contentScriptsPatched)
        let root = try object(patch.data)
        #expect((root["background"] as? [String: Any])?["scripts"] as? [String] == ["paddle-prelude.js", "bg.js"])
        #expect(root["content_scripts"] == nil)

        let none = try ExtensionCompat.patchManifest(Data(#"{"manifest_version": 3, "content_scripts": []}"#.utf8))
        #expect(!none.preludeApplied && none.unpatchedBackground == nil)
        #expect((try object(none.data)["content_scripts"] as? [Any])?.isEmpty == true)
    }

    @Test func rejectsNonObjects() {
        #expect(throws: ExtensionCompat.PatchError.notAnObject) { try ExtensionCompat.patchManifest(Data("[1, 2]".utf8)) }
        #expect(throws: ExtensionCompat.PatchError.notAnObject) { try ExtensionCompat.patchManifest(Data("nope".utf8)) }
        // A malformed background or content_scripts is left for WebKit to report.
        let odd = try? ExtensionCompat.patchManifest(Data(#"{"background": {"scripts": "x"}, "content_scripts": {"js": ["a.js"]}}"#.utf8))
        #expect(odd?.preludeApplied == false && odd?.unpatchedBackground == nil)
    }

    @Test func safariBuildsNeedNoPrelude() {
        #expect(ExtensionCompat.needsPrelude(manifest: ["browser_specific_settings": ["safari": ["strict_min_version": "17"]]]) == false)
        #expect(ExtensionCompat.needsPrelude(manifest: ["browser_specific_settings": ["gecko": ["id": "x@y"]]]) == true)
        #expect(ExtensionCompat.needsPrelude(manifest: ["name": "plain"]) == true)
        #expect(ExtensionCompat.geckoID(manifest: ["browser_specific_settings": ["gecko": ["id": "x@y"]]]) == "x@y")
        #expect(ExtensionCompat.geckoID(manifest: [:]) == nil)
    }

    @Test func popupCSSOnlyForProtonPass() {
        #expect(ExtensionCompat.popupCSS(forGeckoID: ExtensionCompat.protonPassGeckoID) == ":root{--popup-width:600px!important;--popup-height:430px!important}html,body{width:600px!important;height:430px!important}")
        #expect(ExtensionCompat.popupCSS(forGeckoID: "other@example.com") == nil)
        #expect(ExtensionCompat.popupCSS(forGeckoID: nil) == nil)
        #expect(ExtensionCompat.popupPath(manifest: ["action": ["default_popup": "/popup.html?x"]]) == "popup.html")
        #expect(ExtensionCompat.popupPath(manifest: ["browser_action": ["default_popup": "p.html"]]) == "p.html")
        #expect(ExtensionCompat.popupPath(manifest: [:]) == nil)
        #expect(ExtensionCompat.popupPath(manifest: ["action": ["default_popup": "./ui//popup.html"]]) == "ui/popup.html")
        #expect(ExtensionCompat.popupPath(manifest: ["action": ["default_popup": "../../config.json"]]) == nil)
        #expect(ExtensionCompat.popupPath(manifest: ["action": ["default_popup": "ui/../../x.html"]]) == nil)
    }

    @Test func styleGoesBeforeHeadEndOnce() throws {
        let html = Data("<!doctype html>\n<html><HEAD><title>x</title></HEAD><body></body></html>".utf8)
        let once = ExtensionCompat.insertStyle("html{min-width:600px}", into: html)
        let text = try #require(String(data: once, encoding: .utf8))
        #expect(text == "<!doctype html>\n<html><HEAD><title>x</title><style data-paddle-compat>html{min-width:600px}</style></HEAD><body></body></html>")
        #expect(ExtensionCompat.insertStyle("html{min-width:600px}", into: once) == once)

        let headless = ExtensionCompat.insertStyle("a{}", into: Data("<html><body>hi</body></html>".utf8))
        #expect(String(data: headless, encoding: .utf8) == "<html><style data-paddle-compat>a{}</style><body>hi</body></html>")

        let binary = Data([0xFF, 0xFE, 0x00, 0xC0])
        #expect(ExtensionCompat.insertStyle("a{}", into: binary) == binary)
    }

    @Test func readonlyAssignmentErrorsAreHarmless() {
        #expect(ExtensionCompat.isHarmlessError("TypeError: Attempted to assign to readonly property."))
        #expect(!ExtensionCompat.isHarmlessError("TypeError: undefined is not an object (evaluating 'rm.runtime.onUpdateAvailable.addListener')"))
    }

    @Test func preludeMatchesTheProbe() {
        // The one that worked in the wave 4b probe host; a change here needs a new probe run.
        #expect(ExtensionCompat.prelude.contains("Object.defineProperty(globalThis, k, {get: () => v, set: () => {}, enumerable: true, configurable: false})"))
        #expect(ExtensionCompat.prelude.contains("ns.runtime.onUpdateAvailable = {addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; }}"))
        #expect(ExtensionCompat.prelude.hasPrefix("// Paddle compat prelude"))
    }

    // MARK: - v2 (personas)

    @Test func classicWorkerGetsAWrapperInItsOwnDirectory() throws {
        let manifest = #"{"manifest_version": 3, "background": {"service_worker": "/js/bg worker.js"}, "content_scripts": [{"matches": ["https://*/*"], "js": ["cs.js"]}, {"matches": ["https://*/*"], "js": ["main.js"], "world": "MAIN"}]}"#
        let patch = try ExtensionCompat.patchManifest(Data(manifest.utf8), persona: .chrome)
        let root = try object(patch.data)
        #expect((root["background"] as? [String: Any])?["service_worker"] as? String == "js/paddle-sw.js")
        #expect(patch.serviceWorkerWrapper?.path == "js/paddle-sw.js")
        #expect(patch.serviceWorkerWrapper?.contents.contains(#"importScripts("/paddle-prelude.js", "bg%20worker.js");"#) == true)
        #expect(patch.backgroundPatched && patch.unpatchedBackground == nil && patch.persona == .chrome)
        let scripts = (root["content_scripts"] as? [[String: Any]])?.map { $0["js"] as? [String] ?? [] }
        #expect(scripts == [["paddle-content.js", "cs.js"], ["main.js"]])
        // Everything outside the edits is byte-for-byte the same.
        let text = try #require(String(data: patch.data, encoding: .utf8))
        #expect(text == manifest.replacingOccurrences(of: #""/js/bg worker.js""#, with: #""js/paddle-sw.js""#).replacingOccurrences(of: #""js": ["cs.js"]"#, with: #""js": ["paddle-content.js","cs.js"]"#))
    }

    @Test func moduleWorkerImportsThePreludeFirst() throws {
        let manifest = #"{"manifest_version": 3, "background": {"service_worker": "sw.js", "type": "module"}}"#
        let patch = try ExtensionCompat.patchManifest(Data(manifest.utf8), persona: .firefox)
        #expect(patch.serviceWorkerWrapper?.path == "paddle-sw.js")
        let lines = patch.serviceWorkerWrapper?.contents.split(separator: "\n").filter { !$0.hasPrefix("//") }
        #expect(lines == [#"import "/paddle-prelude.js";"#, #"import "./sw.js";"#])
    }

    @Test func v2PatchIsIdempotent() throws {
        let manifest = #"{"manifest_version": 3, "background": {"service_worker": "sw.js", "scripts": ["bg.js"]}, "content_scripts": [{"matches": ["https://*/*"], "js": ["cs.js"]}]}"#
        let once = try ExtensionCompat.patchManifest(Data(manifest.utf8), persona: .firefox)
        let twice = try ExtensionCompat.patchManifest(once.data, persona: .firefox)
        #expect(twice.data == once.data)
        #expect(twice.serviceWorkerWrapper == nil && twice.backgroundPatched)
        #expect(((try object(once.data))["background"] as? [String: Any])?["scripts"] as? [String] == ["paddle-prelude.js", "bg.js"])
    }

    @Test func backgroundPageIsReportedForTheTag() throws {
        let manifest = #"{"manifest_version": 2, "background": {"page": "./bg/page.html"}}"#
        let v2 = try ExtensionCompat.patchManifest(Data(manifest.utf8), persona: .chrome)
        #expect(v2.backgroundPage == "bg/page.html" && v2.backgroundPatched && v2.unpatchedBackground == nil)
        #expect(v2.data == Data(manifest.utf8))
        let none = try ExtensionCompat.patchManifest(Data(manifest.utf8))
        #expect(none.backgroundPage == nil && !none.backgroundPatched && none.unpatchedBackground == .page)
    }

    @Test func personaNoneKeepsThe4bPatch() throws {
        let none = try ExtensionCompat.patchManifest(Data(Self.firefox.utf8), persona: .none)
        #expect(none == (try ExtensionCompat.patchManifest(Data(Self.firefox.utf8))))
        #expect(none.serviceWorkerWrapper == nil && none.persona == .none)
        #expect(String(data: none.data, encoding: .utf8)?.contains("paddle-content.js") == false)
        let worker = try ExtensionCompat.patchManifest(Data(#"{"background": {"service_worker": "sw.js"}}"#.utf8), persona: .none)
        #expect(worker.unpatchedBackground == .serviceWorker && worker.serviceWorkerWrapper == nil)
    }

    @Test func climbingWorkerPathIsLeftAlone() throws {
        let patch = try ExtensionCompat.patchManifest(Data(#"{"background": {"service_worker": "../sw.js"}}"#.utf8), persona: .chrome)
        #expect(patch.serviceWorkerWrapper == nil && patch.unpatchedBackground == .serviceWorker)
    }

    @Test(arguments: [
        ("<!doctype html><html><head><meta charset=utf-8><script src=a.js></script></head></html>",
         "<!doctype html><html><head><script src=\"/paddle-prelude.js\"></script><meta charset=utf-8><script src=a.js></script></head></html>"),
        ("<html><script src=early.js></script><head lang=en></head></html>",
         "<html><script src=\"/paddle-prelude.js\"></script><script src=early.js></script><head lang=en></head></html>"),
        ("<header>x</header>", "<script src=\"/paddle-prelude.js\"></script><header>x</header>"),
        ("<!DOCTYPE html><body>x</body>", "<!DOCTYPE html><script src=\"/paddle-prelude.js\"></script><body>x</body>"),
        ("<HTML lang=en><BODY>", "<HTML lang=en><script src=\"/paddle-prelude.js\"></script><BODY>"),
        ("plain", "<script src=\"/paddle-prelude.js\"></script>plain"),
    ])
    func scriptTagGoesBeforeThePagesOwnScripts(html: String, expected: String) {
        let once = ExtensionCompat.insertScriptTag(into: Data(html.utf8), src: "/paddle-prelude.js")
        #expect(String(data: once, encoding: .utf8) == expected)
        #expect(ExtensionCompat.insertScriptTag(into: once, src: "/paddle-prelude.js") == once)
    }
}

