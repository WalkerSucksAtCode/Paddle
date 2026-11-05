import Foundation
@testable import PaddleCore
import Testing
import WebKit

struct SitePolicyTests {
    @Test func defaultsFillUnsetFields() {
        let policy = PaddleConfig().sitePolicy(forHost: "example.com")
        #expect(policy == SitePolicy.defaults)
        #expect(policy.zoom == 1 && policy.javaScript && policy.autoplay == .muted && policy.contentBlocking && policy.location == .ask)
    }

    /// Location and notification answers belong to their own host: a parent's answer doesn't cover a subdomain.
    @Test func permissionAnswersCoverOnlyTheirOwnHost() {
        #expect(SitePolicy.defaults.notifications == .ask)
        var config = PaddleConfig()
        config.sites = ["example.com": SiteSettings(notifications: .allow), "docs.example.com": SiteSettings(location: .deny)]
        let docs = config.sitePolicy(forHost: "docs.example.com")
        #expect(docs.notifications == .ask && docs.location == .deny)
        #expect(config.sitePolicy(forHost: "Example.COM.").notifications == .allow)
        #expect(config.sitePolicy(forHost: "a.docs.example.com").location == .ask)
        #expect(config.notificationPermissions == ["https://example.com": true, "http://example.com": true])
        #expect(config.sitePolicy(forHost: "other.test").notifications == .ask)
        #expect(SiteSettings.entry(nil, setting: .notifications, to: "allow") == ["notifications": "allow"])
        #expect(SiteSettings.entry(nil, setting: .notifications, to: "ask") == nil)
    }

    /// Notification answers are kept apart from location answers for the same origin.
    @Test func notificationSessionAnswersAreTheirOwnKind() {
        var answers = SessionPermissions()
        answers.record(true, site: "https://push.test:443", kinds: [.notifications])
        #expect(answers.answer(site: "https://push.test:443", kind: .notifications) == true)
        #expect(answers.answer(site: "https://push.test:443", kind: .location) == nil)
        #expect(answers.all.map(\.kind) == [.notifications])
        #expect(SessionPermissions.Kind.allCases.firstIndex(of: .notifications)! < SessionPermissions.Kind.allCases.firstIndex(of: .downloads)!)
    }

    @Test func longestSuffixWinsPerField() {
        var config = PaddleConfig()
        config.sites = [
            "example.com": SiteSettings(zoom: 1.5, javaScript: false, autoplay: .block),
            "docs.example.com": SiteSettings(javaScript: true, location: .allow),
            "other.com": SiteSettings(contentBlocking: false),
        ]
        let docs = config.sitePolicy(forHost: "a.docs.example.com")
        #expect(docs.zoom == 1.5)
        #expect(docs.javaScript)
        #expect(docs.autoplay == .block)
        #expect(docs.location == .ask)
        #expect(config.sitePolicy(forHost: "docs.example.com").location == .allow)
        #expect(docs.contentBlocking)
        let www = config.sitePolicy(forHost: "WWW.Example.com.")
        #expect(!www.javaScript && www.location == .ask)
        #expect(config.sitePolicy(forHost: "notexample.com") == .defaults)
        #expect(config.blockingOffHosts == ["other.com"])
    }

    @Test func zoomIsClampedAndRounded() {
        #expect(SitePolicy.normalizedZoom(1 + 0.1) == 1.1)
        #expect(SitePolicy.normalizedZoom(0.1) == 0.3)
        #expect(SitePolicy.normalizedZoom(9) == 3)
        #expect(SitePolicy.normalizedZoom(1.234) == 1.23)
    }

    @Test func zoomKeyPrefersTheEntryThatSetsZoom() {
        var config = PaddleConfig()
        #expect(config.zoomKey(forHost: "www.example.com") == "example.com")
        #expect(config.zoomKey(forHost: "www.co") == "www.co")
        #expect(config.zoomKey(forHost: "Mail.Example.com") == "mail.example.com")
        config.sites = ["Example.com": SiteSettings(zoom: 1.2), "mail.example.com": SiteSettings(javaScript: false)]
        // The domain's zoom covers the subdomain, so that is the one changed; the key keeps its spelling.
        #expect(config.zoomKey(forHost: "mail.example.com") == "Example.com")
        config.sites = ["example.com": SiteSettings(javaScript: false), "www.example.com": SiteSettings(autoplay: .allow)]
        // No zoom anywhere: the host's own entry.
        #expect(config.zoomKey(forHost: "www.example.com") == "www.example.com")
        #expect(config.zoomKey(forHost: "news.example.com") == "news.example.com")
        #expect(config.siteKey(forHost: "WWW.example.com") == "www.example.com")
        #expect(config.siteKey(forHost: "maps.example.com") == "maps.example.com")
        config.sites = ["Maps.Example.com": SiteSettings(javaScript: false)]
        #expect(config.siteKey(forHost: "maps.example.com") == "Maps.Example.com")
    }

    @Test func zoomKeyPicksTheUnicodeChildOverItsPunycodeParent() {
        var config = PaddleConfig()
        config.sites = ["xn--bcher-kva.de": SiteSettings(zoom: 1.2), "shop.bücher.de": SiteSettings(zoom: 1.5)]
        #expect(config.zoomKey(forHost: "shop.xn--bcher-kva.de") == "shop.bücher.de")
        #expect(config.sitePolicy(forHost: "shop.xn--bcher-kva.de").zoom == 1.5)
        #expect(config.zoomKey(forHost: "www.xn--bcher-kva.de") == "xn--bcher-kva.de")
    }

    @Test func entryEditKeepsOtherMembersAndDropsDefaults() {
        let existing: JSONValue = ["javaScript": false, "note": "mine"]
        #expect(SiteSettings.entry(existing, setting: .zoom, to: 1.25) == ["javaScript": false, "note": "mine", "zoom": 1.25])
        #expect(SiteSettings.entry(["zoom": 1.5], setting: .zoom, to: 1) == ["zoom": 1])
        #expect(SiteSettings.entry(["zoom": 1.5, "location": "deny"], setting: .zoom, to: nil) == ["location": "deny"])
        #expect(SiteSettings.entry(nil, setting: .location, to: "allow") == ["location": "allow"])
        #expect(SiteSettings.entry(nil, setting: .location, to: "ask") == nil)
        #expect(SiteSettings.entry(nil, setting: .autoplay, to: "muted") == nil)
    }

    @Test func entryEditGoesThroughTheConfigWritePath() throws {
        let base = Data(#"{"sites": {"example.com": {"javaScript": false}}}"#.utf8)
        let entry = SiteSettings.entry(.object(["javaScript": false]), setting: .zoom, to: 1.1)
        let written = try ConfigFile.apply(changes: [ConfigChange("sites", "example.com", entry)], base: base, disk: base).get()
        let config = try PaddleConfig.decode(written)
        #expect(config.sites["example.com"] == SiteSettings(zoom: 1.1, javaScript: false))
        #expect(String(decoding: written, as: UTF8.self).contains("1.1") && !String(decoding: written, as: UTF8.self).contains("1.100"))
    }

    @Test func dataRecordsCoverSubdomains() {
        #expect(SitePolicy.dataRecord("example.com", covers: "www.example.com"))
        #expect(SitePolicy.dataRecord("example.com", covers: "Example.COM"))
        #expect(!SitePolicy.dataRecord("example.com", covers: "notexample.com"))
        #expect(!SitePolicy.dataRecord("www.example.com", covers: "example.com"))
        #expect(!SitePolicy.dataRecord("", covers: "example.com"))
    }

    @Test func sessionAnswersListAndForget() {
        var answers = SessionPermissions()
        #expect(answers.isEmpty)
        answers.record(true, site: "https://meet.test:443", kinds: [.camera, .microphone])
        answers.record(false, site: "https://maps.test:443", kinds: [.location])
        answers.record(true, site: "files.test", kinds: [.downloads])
        #expect(answers.allows(site: "https://meet.test:443", kinds: [.microphone]))
        #expect(!answers.allows(site: "https://meet.test:443", kinds: []))
        #expect(answers.answer(site: "https://maps.test:443", kind: .location) == false)
        #expect(answers.answer(site: "https://maps.test:443", kind: .camera) == nil)
        #expect(answers.all.map(\.host) == ["files.test", "maps.test", "meet.test", "meet.test"])
        #expect(answers.all.filter { $0.host == "meet.test" }.map(\.kind) == [.camera, .microphone])
        answers.forget(host: "MEET.test")
        #expect(answers.answers(forHost: "meet.test").isEmpty)
        #expect(answers.all.count == 2)
        answers.forget(SessionPermissions.Answer(site: "files.test", kind: .downloads, allowed: true))
        #expect(answers.all.map(\.site) == ["https://maps.test:443"])
    }

    @Test func freezeIsPerSiteWithAutoDefault() throws {
        #expect(SitePolicy.defaults.freeze == .auto)
        let config = try PaddleConfig.decode(Data(#"{"sites": {"slack.com": {"freeze": "never"}, "app.slack.com": {"freeze": "always"}}}"#.utf8))
        #expect(config.sitePolicy(forHost: "slack.com").freeze == .never)
        #expect(config.sitePolicy(forHost: "x.slack.com").freeze == .never)
        #expect(config.sitePolicy(forHost: "app.slack.com").freeze == .always)
        #expect(config.sitePolicy(forHost: "example.com").freeze == .auto)
        #expect(SiteSettings.entry(nil, setting: .freeze, to: .string("auto")) == nil)
        #expect(SiteSettings.entry(nil, setting: .freeze, to: .string("never")) == ["freeze": "never"])
    }

    @Test func darkModePolicyAndScriptTests() throws {
        var config = PaddleConfig()
        #expect(!config.sitePolicy(forHost: "example.com").darkMode)
        #expect(config.sitePolicy(forHost: "example.com").pageDarkEngine == .off)

        let alwaysDecoded = try PaddleConfig.decode(Data(#"{"darkMode": "always"}"#.utf8))
        #expect(alwaysDecoded.darkMode == .smart)

        config.darkMode = .smart
        #expect(config.sitePolicy(forHost: "example.com").darkMode)
        #expect(config.sitePolicy(forHost: "example.com").pageDarkEngine == .smart)

        config.darkMode = .native
        #expect(config.sitePolicy(forHost: "example.com").pageDarkEngine == .native)

        config.darkMode = .system
        #expect(config.sitePolicy(forHost: "example.com", systemIsDark: false).pageDarkEngine == .off)
        #expect(config.sitePolicy(forHost: "example.com", systemIsDark: true).pageDarkEngine == .smart)

        config.darkMode = .smart
        config.sites = [
            "light.com": SiteSettings(darkMode: .light),
            "dark.com": SiteSettings(darkMode: .dark),
            "native.com": SiteSettings(darkMode: .native),
        ]
        #expect(config.sitePolicy(forHost: "dark.com", systemIsDark: false).pageDarkEngine == .smart)
        #expect(config.sitePolicy(forHost: "light.com", systemIsDark: true).pageDarkEngine == .off)
        #expect(config.sitePolicy(forHost: "native.com").pageDarkEngine == .native)

        config.darkMode = .native
        #expect(config.sitePolicy(forHost: "dark.com").pageDarkEngine == .native)

        let boolSite = try PaddleConfig.decode(Data(#"{"sites": {"legacy.com": {"darkMode": true}, "off.com": {"darkMode": false}}}"#.utf8))
        #expect(boolSite.sites["legacy.com"]?.darkMode == .dark)
        #expect(boolSite.sites["off.com"]?.darkMode == .light)

        let autoSite = try PaddleConfig.decode(Data(#"{"sites": {"auto.com": {"darkMode": "auto"}}}"#.utf8))
        #expect(autoSite.sites["auto.com"]?.darkMode == nil)

        #expect(SiteSettings.entry(nil, setting: .darkMode, to: .string("auto")) == nil)
        #expect(SiteSettings.entry(nil, setting: .darkMode, to: .string("light")) == ["darkMode": "light"])

        let script = DarkModeScript.source(
            for: config.sites,
            defaultEngine: config.pageDarkEngine(systemIsDark: true),
            globalDarkMode: config.darkMode
        )
        #expect(script.contains("setPolicy"))
        #expect(script.contains("color-scheme: dark"))
        #expect(script.contains("data-paddle-dark-mode"))
        #expect(script.contains("setKeepLight"))
        #expect(script.contains("dark.com"))
        #expect(script.contains("'native'"))
        #expect(script.contains("'smart'"))
        #expect(script.contains(".gm-style"))
        #expect(script.contains(".monaco-editor"))
        #expect(script.contains("#docs-editor"))
        #expect(script.contains("colorScheme"))
        #expect(script.contains("1600"))
        #expect(script.contains("attributeFilter"))
        #expect(script.contains("meta[name=\"color-scheme\"]"))
        #expect(DarkModePreference.allCases == [.off, .system, .smart, .native])
    }

    @MainActor
    @Test func darkModeScriptExecutesInWebKit() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = DarkModeScript.source(
            for: ["example.com": SiteSettings(darkMode: .dark)],
            defaultEngine: .smart,
            globalDarkMode: .smart
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><head><title>Test</title></head><body><h1>Hello</h1></body></html>", baseURL: URL(string: "https://example.com/"))
        let deadline = ContinuousClock.now + .seconds(10)
        var check: String?
        while ContinuousClock.now < deadline {
            check = try? await withCheckedThrowingContinuation { cont in
                webView.callAsyncJavaScript("return typeof window.__paddleDarkMode", arguments: [:], in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let val): cont.resume(returning: val as? String)
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
            if check == "object" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(check == "object")
    }

    @MainActor
    @Test func textImageInversionTogglesInWebKit() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = DarkModeScript.source(
            for: ["example.com": SiteSettings(darkMode: .dark)],
            defaultEngine: .off,
            globalDarkMode: .smart,
            invertTextImages: true
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let html = "<html><body><img id='testimg' src='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7' /></body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        let deadline = ContinuousClock.now + .seconds(10)
        var toggled: Bool?
        while ContinuousClock.now < deadline {
            toggled = try? await withCheckedThrowingContinuation { cont in
                let js = """
                if (!window.__paddleDarkMode) return null;
                const img = document.getElementById('testimg');
                if (!img) return null;
                window.__paddleDarkMode.toggleLastClickedImage(img.src);
                return img.getAttribute('data-paddle-inverted-text');
                """
                webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let val): cont.resume(returning: (val as? String) == "true")
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
            if toggled == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(toggled == true)
    }

    /// An embedded frame's own `allow` needs the embedding page to allow too; a deny on either side denies.
    @Test func locationNeedsTheEmbeddingPageToAllowToo() {
        #expect(SitePermissionDecision.location(site: .allow, embeddingPage: nil) == .grant)
        #expect(SitePermissionDecision.location(site: .allow, embeddingPage: .allow) == .grant)
        #expect(SitePermissionDecision.location(site: .allow, embeddingPage: .ask) == .ask)
        #expect(SitePermissionDecision.location(site: .allow, embeddingPage: .deny) == .deny)
        #expect(SitePermissionDecision.location(site: .deny, embeddingPage: .allow) == .deny)
        #expect(SitePermissionDecision.location(site: .ask, embeddingPage: nil) == .ask)
    }

    @Test func notificationsAreGrantedOnlyForHTTPS() {
        #expect(SitePermissionDecision.notifications(scheme: "http", site: .allow, embeddingPage: nil) == .deny)
        #expect(SitePermissionDecision.notifications(scheme: "https", site: .allow, embeddingPage: nil) == .grant)
        #expect(SitePermissionDecision.notifications(scheme: "HTTPS", site: .ask, embeddingPage: nil) == .ask)
        #expect(SitePermissionDecision.notifications(scheme: "https", site: .allow, embeddingPage: .ask) == .ask)
    }
}

