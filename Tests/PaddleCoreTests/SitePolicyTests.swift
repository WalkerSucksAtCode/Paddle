import Foundation
@testable import PaddleCore
import Testing

struct SitePolicyTests {
    @Test func defaultsFillUnsetFields() {
        let policy = PaddleConfig().sitePolicy(forHost: "example.com")
        #expect(policy == SitePolicy.defaults)
        #expect(policy.zoom == 1 && policy.javaScript && policy.autoplay == .muted && policy.contentBlocking && policy.location == .ask)
    }

    @Test func notificationsDefaultToAskAndMergePerField() {
        #expect(SitePolicy.defaults.notifications == .ask)
        var config = PaddleConfig()
        config.sites = ["example.com": SiteSettings(notifications: .allow), "docs.example.com": SiteSettings(location: .deny)]
        let docs = config.sitePolicy(forHost: "docs.example.com")
        #expect(docs.notifications == .allow && docs.location == .deny)
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
        #expect(docs.location == .allow)
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
}
