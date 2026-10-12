import Foundation
@testable import PaddleCore
import Testing
import WebKit

struct ExtensionOverlayTests {
    private let fm = FileManager.default

    /// A fresh work folder with `extensions/<name>/` holding a small extension and an empty `overlays/`.
    private func fixture(manifest: String, name: String = "sample") throws -> (source: URL, overlays: URL, work: URL) {
        let work = fm.temporaryDirectory.appendingPathComponent("paddle-overlay-\(UUID().uuidString)", isDirectory: true)
        let source = work.appendingPathComponent("extensions/\(name)", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("console.log('bg')".utf8).write(to: source.appendingPathComponent("background.js"))
        try Data("<!doctype html><html><head><title>p</title></head><body>popup</body></html>".utf8).write(to: source.appendingPathComponent("popup.html"))
        try Data("export const x = 1".utf8).write(to: source.appendingPathComponent("sub/x.js"))
        return (source, work.appendingPathComponent("overlays", isDirectory: true), work)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func makesAPatchedClone() throws {
        let (source, overlays, work) = try fixture(manifest: ExtensionCompatTests.firefox)
        defer { try? fm.removeItem(at: work) }
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(result.root == overlays.appendingPathComponent("sample", isDirectory: true).standardizedFileURL)
        #expect(result.backgroundPatched && result.contentScriptsPatched && result.unpatchedBackground == nil && result.popupPatched)
        #expect(result.copiedBytes == nil, "same APFS volume: a clone")
        #expect(!result.reused)
        #expect(result.statusText == "compat prelude applied")

        #expect(try contents(result.root.appendingPathComponent("paddle-prelude.js")) == ExtensionCompat.prelude)
        #expect(try contents(result.root.appendingPathComponent("sub/x.js")) == "export const x = 1")
        #expect(try contents(result.root.appendingPathComponent("background.js")) == "console.log('bg')")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.root.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect((manifest["background"] as? [String: Any])?["scripts"] as? [String] == ["paddle-prelude.js", "background.js"])
        let popup = try contents(result.root.appendingPathComponent("popup.html"))
        #expect(popup.contains("<style data-paddle-compat>:root{--popup-width:600px!important;--popup-height:430px!important}html,body{width:600px!important;height:430px!important}</style></head>"))

        // The user's folder is untouched.
        #expect(try contents(source.appendingPathComponent("manifest.json")) == ExtensionCompatTests.firefox)
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("paddle-prelude.js").path))
        #expect(try contents(source.appendingPathComponent("popup.html")).contains("data-paddle-compat") == false)
    }

    @Test func otherExtensionsKeepTheirPopup() throws {
        let manifest = #"{"manifest_version": 3, "background": {"service_worker": "background.js"}, "content_scripts": [{"matches": ["https://example.com/*"], "js": ["sub/x.js"]}], "action": {"default_popup": "popup.html"}, "browser_specific_settings": {"gecko": {"id": "x@example.com"}}}"#
        let (source, overlays, work) = try fixture(manifest: manifest)
        defer { try? fm.removeItem(at: work) }
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(!result.popupPatched)
        #expect(!result.backgroundPatched && result.unpatchedBackground == .serviceWorker)
        #expect(result.statusText == "compat prelude applied (content scripts only; background.service_worker left unpatched)")
        #expect(try contents(result.root.appendingPathComponent("popup.html")) == contents(source.appendingPathComponent("popup.html")))
    }

    @Test func nothingToPatchMeansNoOverlay() throws {
        for manifest in [
            #"{"manifest_version": 3, "background": {"service_worker": "background.js"}, "permissions": ["storage"]}"#,
            #"{"manifest_version": 2, "background": {"page": "popup.html"}}"#
        ] {
            let (source, overlays, work) = try fixture(manifest: manifest)
            defer { try? fm.removeItem(at: work) }
            try fm.createDirectory(at: overlays.appendingPathComponent("sample"), withIntermediateDirectories: true)
            #expect(try ExtensionOverlay.make(from: source, name: "sample", in: overlays) == nil)
            #expect(!fm.fileExists(atPath: overlays.appendingPathComponent("sample").path))
        }
    }

    @Test func statusLineNamesTheBackgroundKindAndACopy() {
        func result(_ bg: Bool, _ cs: Bool, _ kind: ExtensionCompat.UnpatchedBackground?, copied: Int64? = nil) -> ExtensionOverlayResult {
            ExtensionOverlayResult(
                root: URL(fileURLWithPath: "/x"), backgroundPatched: bg, contentScriptsPatched: cs, unpatchedBackground: kind,
                popupPatched: false, copiedBytes: copied, reused: false
            )
        }
        #expect(result(false, true, .page).statusText == "compat prelude applied (content scripts only; background.page left unpatched)")
        #expect(result(true, false, nil).statusText == "compat prelude applied (background only)")
        #expect(result(true, true, nil, copied: 21_536_000).statusText == "compat prelude applied (copied, 22 MB)")
        #expect(result(false, false, .serviceWorker, copied: 400).statusText == "compat popup style applied (background.service_worker left unpatched; copied, 1 KB)")
        #expect(!result(false, false, nil).runsPrelude && result(false, true, nil).runsPrelude)
    }

    @Test func safariBuildGetsNoOverlayAndAStaleOneGoes() throws {
        let manifest = #"{"manifest_version": 3, "browser_specific_settings": {"safari": {"strict_min_version": "17"}}}"#
        let (source, overlays, work) = try fixture(manifest: manifest)
        defer { try? fm.removeItem(at: work) }
        let stale = overlays.appendingPathComponent("sample", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appendingPathComponent("manifest.json"))
        #expect(try ExtensionOverlay.make(from: source, name: "sample", in: overlays) == nil)
        #expect(!fm.fileExists(atPath: stale.path))
    }

    @Test func rebuildStartsFromTheSourceAgain() throws {
        let (source, overlays, work) = try fixture(manifest: ExtensionCompatTests.firefox)
        defer { try? fm.removeItem(at: work) }
        let first = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        try Data("junk".utf8).write(to: first.root.appendingPathComponent("leftover.txt"))
        try Data("console.log('edited')".utf8).write(to: source.appendingPathComponent("background.js"))
        let second = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(second.root == first.root)
        #expect(!second.reused)
        #expect(!fm.fileExists(atPath: second.root.appendingPathComponent("leftover.txt").path))
        #expect(try contents(second.root.appendingPathComponent("background.js")) == "console.log('edited')")
        // A clone of a clone's edits never reaches the source.
        #expect(try contents(source.appendingPathComponent("background.js")) == "console.log('edited')")
    }

    @Test func unchangedSourceKeepsTheOverlay() throws {
        let (source, overlays, work) = try fixture(manifest: ExtensionCompatTests.firefox)
        defer { try? fm.removeItem(at: work) }
        let first = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        try Data("marker".utf8).write(to: first.root.appendingPathComponent("kept.txt"))
        let second = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(second.reused && second.popupPatched && second.backgroundPatched)
        #expect(fm.fileExists(atPath: second.root.appendingPathComponent("kept.txt").path))
        // A new file in the source counts as a change.
        try Data("x".utf8).write(to: source.appendingPathComponent("sub/new.js"))
        let third = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(!third.reused)
        #expect(!fm.fileExists(atPath: third.root.appendingPathComponent("kept.txt").path))
        #expect(fm.fileExists(atPath: third.root.appendingPathComponent("sub/new.js").path))
    }

    /// A Proton-id manifest whose popup is `default_popup`, plus a file outside the extension that must not change.
    private func escapeFixture(popup: String) throws -> (source: URL, overlays: URL, work: URL, victim: URL) {
        let manifest = """
        {"manifest_version": 3, "background": {"scripts": ["background.js"]}, "action": {"default_popup": "\(popup)"},
         "browser_specific_settings": {"gecko": {"id": "\(ExtensionCompat.protonPassGeckoID)"}}}
        """
        let (source, overlays, work) = try fixture(manifest: manifest)
        let outside = work.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("popup.html")
        try Data("<html><head></head>victim</html>".utf8).write(to: victim)
        return (source, overlays, work, victim)
    }

    @Test func popupPathCannotClimbOut() throws {
        let (source, overlays, work, victim) = try escapeFixture(popup: "../../../outside/popup.html")
        defer { try? fm.removeItem(at: work) }
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(!result.popupPatched)
        #expect(try contents(victim) == "<html><head></head>victim</html>")
    }

    @Test func popupThroughASymlinkedFolderIsLeftAlone() throws {
        let (source, overlays, work, victim) = try escapeFixture(popup: "ui/popup.html")
        defer { try? fm.removeItem(at: work) }
        try fm.createSymbolicLink(at: source.appendingPathComponent("ui"), withDestinationURL: victim.deletingLastPathComponent())
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(!result.popupPatched)
        #expect(try contents(victim) == "<html><head></head>victim</html>")
        // A popup file that is itself a symlink is left alone too.
        let link = work.appendingPathComponent("extensions/linked", isDirectory: true)
        try fm.createDirectory(at: link, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("manifest.json"), to: link.appendingPathComponent("manifest.json"))
        try fm.copyItem(at: source.appendingPathComponent("background.js"), to: link.appendingPathComponent("background.js"))
        try fm.createDirectory(at: link.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link.appendingPathComponent("ui/popup.html"), withDestinationURL: victim)
        let linked = try #require(try ExtensionOverlay.make(from: link, name: "linked", in: overlays))
        #expect(!linked.popupPatched)
        #expect(try contents(victim) == "<html><head></head>victim</html>")
    }

    @Test func symlinkedManifestIsReplacedNotWrittenThrough() throws {
        let (source, overlays, work) = try fixture(manifest: "{}")
        defer { try? fm.removeItem(at: work) }
        let real = work.appendingPathComponent("real-manifest.json")
        try Data(ExtensionCompatTests.firefox.utf8).write(to: real)
        try fm.removeItem(at: source.appendingPathComponent("manifest.json"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("manifest.json"), withDestinationURL: real)
        try fm.createSymbolicLink(at: source.appendingPathComponent("paddle-prelude.js"), withDestinationURL: work.appendingPathComponent("prelude-victim.js"))
        try Data("victim".utf8).write(to: work.appendingPathComponent("prelude-victim.js"))
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
        #expect(try contents(real) == ExtensionCompatTests.firefox)
        #expect(try contents(work.appendingPathComponent("prelude-victim.js")) == "victim")
        let manifest = result.root.appendingPathComponent("manifest.json")
        #expect((try fm.attributesOfItem(atPath: manifest.path)[.type] as? FileAttributeType) == .typeRegular)
        #expect(try contents(manifest).contains("paddle-prelude.js"))
    }

    /// WebKit counts content-script matches as requested hosts; the overlay must not add any.
    @MainActor @Test func webKitSeesTheSameRequestedHosts() async throws {
        let manifests = [
            #"{"manifest_version": 3, "name": "n", "version": "1", "background": {"scripts": ["background.js"]}, "permissions": ["storage"]}"#,
            #"{"manifest_version": 3, "name": "n", "version": "1", "background": {"scripts": ["background.js"]}, "host_permissions": ["https://example.com/*"], "content_scripts": [{"matches": ["https://example.com/*"], "js": ["sub/x.js"]}]}"#,
            #"{"manifest_version": 3, "name": "n", "version": "1", "background": {"service_worker": "background.js"}, "content_scripts": [{"matches": ["https://example.org/*"], "js": ["sub/x.js"], "all_frames": true}]}"#
        ]
        for manifest in manifests {
            let (source, overlays, work) = try fixture(manifest: manifest)
            defer { try? fm.removeItem(at: work) }
            let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays))
            let original = try await WKWebExtension(resourceBaseURL: source)
            let patched = try await WKWebExtension(resourceBaseURL: result.root)
            #expect(Set(patched.allRequestedMatchPatterns.map(\.string)) == Set(original.allRequestedMatchPatterns.map(\.string)))
            #expect(patched.requestedPermissionMatchPatterns == original.requestedPermissionMatchPatterns)
        }
    }

    @Test func pruneRemovesOverlaysOfFoldersThatAreGone() throws {
        let (_, overlays, work) = try fixture(manifest: ExtensionCompatTests.firefox)
        defer { try? fm.removeItem(at: work) }
        for name in ["a", "b", "c"] {
            try fm.createDirectory(at: overlays.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        ExtensionOverlay.prune(in: overlays, keeping: ["a", "c", "never-made"])
        #expect(Set(try fm.contentsOfDirectory(atPath: overlays.path)) == ["a", "c"])
        ExtensionOverlay.remove(name: "a", in: overlays)
        ExtensionOverlay.remove(name: "missing", in: overlays)
        #expect(Set(try fm.contentsOfDirectory(atPath: overlays.path)) == ["c"])
        ExtensionOverlay.prune(in: work.appendingPathComponent("no-such-dir"), keeping: [])  // nothing to do, no throw
    }

    @Test func refusesBadNamesAndMissingManifests() throws {
        let (source, overlays, work) = try fixture(manifest: ExtensionCompatTests.firefox)
        defer { try? fm.removeItem(at: work) }
        #expect(throws: ExtensionOverlay.MakeError.badName("a/b")) { try ExtensionOverlay.make(from: source, name: "a/b", in: overlays) }
        #expect(throws: ExtensionOverlay.MakeError.badName("..")) { try ExtensionOverlay.make(from: source, name: "..", in: overlays) }
        #expect(throws: (any Error).self) { try ExtensionOverlay.make(from: work.appendingPathComponent("nowhere"), name: "x", in: overlays) }
        try Data("[]".utf8).write(to: source.appendingPathComponent("manifest.json"))
        #expect(throws: ExtensionCompat.PatchError.notAnObject) { try ExtensionOverlay.make(from: source, name: "sample", in: overlays) }
        #expect(!fm.fileExists(atPath: overlays.appendingPathComponent("sample").path))
    }

    // MARK: - v2

    @Test func personaOverlayWrapsTheWorkerTagsPagesAndRewritesThePreludeEachLoad() throws {
        let manifest = #"{"manifest_version": 3, "name": "S", "background": {"service_worker": "sub/x.js", "type": "module"}, "content_scripts": [{"matches": ["https://example.com/*"], "js": ["background.js"]}], "action": {"default_popup": "popup.html"}}"#
        let (source, overlays, work) = try fixture(manifest: manifest)
        defer { try? fm.removeItem(at: work) }
        try Data("<p>no head</p>".utf8).write(to: source.appendingPathComponent("sub/page.htm"))
        var plan = try CompatPlan.make(manifestData: Data(manifest.utf8), persona: .chrome, runtimeID: "abcd")
        let result = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays, plan: plan))
        #expect(result.persona == .chrome && result.serviceWorkerWrapped && result.pagesTagged == 2 && result.contentScriptsPatched)
        #expect(result.statusText == "chrome persona (service worker; 2 pages; content scripts)")
        #expect(try contents(result.root.appendingPathComponent("sub/paddle-sw.js")).contains(#"import "./x.js";"#))
        #expect(try contents(result.root.appendingPathComponent("paddle-prelude.js")) == CompatPrelude.source(for: plan, kind: .full))
        #expect(try contents(result.root.appendingPathComponent("paddle-content.js")) == CompatPrelude.source(for: plan, kind: .content))
        #expect(try contents(result.root.appendingPathComponent("popup.html")).contains("<head><script src=\"/paddle-prelude.js\"></script><title>"))
        #expect(try contents(result.root.appendingPathComponent("sub/page.htm")).hasPrefix("<script src=\"/paddle-prelude.js\"></script>"))
        #expect(try contents(source.appendingPathComponent("popup.html")).contains("paddle") == false)

        // Kept while the folder is unchanged, but the generated prelude follows the plan.
        plan.installReason = "install"
        let again = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays, plan: plan))
        #expect(again.reused && again.pagesTagged == 2)
        #expect(try contents(again.root.appendingPathComponent("paddle-prelude.js")).contains(#""installReason":"install""#))

        // Switching persona remakes it; native removes it.
        let none = try #require(try ExtensionOverlay.make(from: source, name: "sample", in: overlays, plan: CompatPlan(persona: .none, runtimeID: "abcd")))
        #expect(!none.reused && none.persona == .none && none.pagesTagged == 0)
        #expect(!fm.fileExists(atPath: none.root.appendingPathComponent("paddle-content.js").path))
        #expect(try ExtensionOverlay.make(from: source, name: "sample", in: overlays, plan: CompatPlan(persona: .native, runtimeID: "abcd")) == nil)
        #expect(!fm.fileExists(atPath: overlays.appendingPathComponent("sample").path))
    }
}

