import Foundation
@testable import PaddleCore
import Testing

struct ExtensionPersonaTests {
    private func manifest(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test(arguments: [
        (#"{"manifest_version":3,"background":{"service_worker":"sw.js"}}"#, nil, nil, Persona.chrome),
        (#"{"manifest_version":2,"background":{"scripts":["bg.js"]}}"#, nil, nil, .chrome),
        (#"{"browser_specific_settings":{"gecko":{"id":"a@b"}},"background":{"scripts":["bg.js"]}}"#, nil, nil, .firefox),
        (#"{"applications":{"gecko":{"id":"a@b"}},"background":{"page":"bg.html"}}"#, nil, nil, .firefox),
        (#"{"browser_specific_settings":{"gecko":{"id":"a@b"}}}"#, nil, nil, .firefox),
        (#"{"browser_specific_settings":{"gecko":{"id":"a@b"}},"background":{"service_worker":"sw.js"}}"#, nil, nil, .chrome),
        (#"{"browser_specific_settings":{"gecko":{"id":"a@b"}},"background":{"service_worker":"sw.js","scripts":["bg.js"]}}"#, nil, nil, .firefox),
        (#"{"browser_specific_settings":{"safari":{"strict_min_version":"17"}}}"#, nil, nil, .native),
        (#"{"browser_specific_settings":{"safari":{},"gecko":{"id":"a@b"}},"background":{"scripts":["b.js"]}}"#, nil, nil, .firefox),
        (#"{"browser_specific_settings":{"gecko":{"id":"a@b"}},"background":{"scripts":["bg.js"]}}"#, Persona.Source.chromeWebStore, nil, .chrome),
        (#"{"background":{"service_worker":"sw.js"}}"#, .mozillaAddons, nil, .firefox),
        (#"{"background":{"service_worker":"sw.js"}}"#, .appex, nil, .native),
        (#"{"background":{"service_worker":"sw.js"}}"#, .folder, nil, .chrome),
        (#"{"background":{"service_worker":"sw.js"}}"#, .appex, Persona.none, .none),
        (#"{"browser_specific_settings":{"safari":{}}}"#, nil, .firefox, .firefox),
    ] as [(String, Persona.Source?, Persona?, Persona)])
    func detection(json: String, source: Persona.Source?, override: Persona?, expected: Persona) throws {
        #expect(Persona.detect(manifest: try manifest(json), source: source, override: override) == expected)
    }

    @Test func userAgentsAndVendors() {
        let v = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0.8078.12", firefoxVersion: "157.0")
        #expect(Persona.chrome.userAgent(v) == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36")
        #expect(Persona.firefox.userAgent(v) == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) Gecko/20100101 Firefox/157.0")
        #expect(Persona.native.userAgent(v) == nil && Persona.none.userAgent(v) == nil)
        #expect(Persona.chrome.vendor == "Google Inc." && Persona.firefox.vendor == "")
        #expect(UserAgentPreset.chrome.value == Persona.chrome.userAgent(.current))
        #expect(UserAgentPreset.firefox.value == Persona.firefox.userAgent(.current))
    }

    /// Chrome's own brand lists for known versions (seen in real Chrome's `navigator.userAgentData.brands`).
    @Test func chromeBrandsMatchChromiumsGreaseOrder() {
        func brands(_ major: Int) -> [String] {
            Persona.chrome.brands(BrowserVersions(chromeMajor: major, chromeFullVersion: "\(major).0.1.2", firefoxVersion: "1.0"))
                .map { "\($0.brand)/\($0.version)" }
        }
        #expect(brands(120) == ["Not_A Brand/8", "Chromium/120", "Google Chrome/120"])
        #expect(brands(124) == ["Chromium/124", "Google Chrome/124", "Not-A.Brand/99"])
        #expect(brands(138) == ["Not)A;Brand/8", "Chromium/138", "Google Chrome/138"])
        let full = Persona.chrome.brands(BrowserVersions(chromeMajor: 124, chromeFullVersion: "124.0.6367.60", firefoxVersion: "1.0"), full: true)
        #expect(full.map(\.version) == ["124.0.6367.60", "124.0.6367.60", "99.0.0.0"])
        #expect(Persona.firefox.brands().isEmpty)
    }

    @Test func versionsRiseToTheManifestsMinimumOnly() throws {
        let base = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0.8078.12", firefoxVersion: "157.0")
        #expect(base.raised(for: try manifest(#"{"minimum_chrome_version":"120"}"#)) == base)
        let chrome = base.raised(for: try manifest(#"{"minimum_chrome_version":"158"}"#))
        #expect(chrome.chromeMajor == 158 && chrome.chromeFullVersion == "158.0.0.0")
        #expect(base.raised(for: try manifest(#"{"minimum_chrome_version":"160.0.7000.1"}"#)).chromeFullVersion == "160.0.7000.1")
        #expect(base.raised(for: try manifest(#"{"browser_specific_settings":{"gecko":{"strict_min_version":"159.0a1"}}}"#)).firefoxVersion == "159.0")
        #expect(base.raised(for: try manifest(#"{"applications":{"gecko":{"strict_min_version":"109.0"}}}"#)).firefoxVersion == "157.0")
        #expect(base.raised(for: try manifest(#"{"browser_specific_settings":{"gecko":{"strict_min_version":"*"}}}"#)) == base)
    }

    @Test func compatConfigDecodesWithDefaults() throws {
        let config = try PaddleConfig.decode(Data(#"{"extensionCompat": {"protonpass": {"persona": "firefox"}, "x": {"shims": false, "publicID": true}}}"#.utf8))
        #expect(config.compat(forFolder: "protonpass").persona == .firefox)
        #expect(config.compat(forFolder: "protonpass").shimsEnabled)
        #expect(!config.compat(forFolder: "protonpass").wantsPublicID)
        #expect(!config.compat(forFolder: "x").shimsEnabled && config.compat(forFolder: "x").wantsPublicID)
        #expect(config.compat(forFolder: "absent") == ExtensionCompatConfig())
        #expect(config.extensionUpdates)
        let unknownPersona = try PaddleConfig.decodeReportingIssues(Data(#"{"extensionCompat": {"a": {"persona": "edge"}}}"#.utf8))
        #expect(unknownPersona.config.extensionCompat.isEmpty)
        #expect(unknownPersona.issues.map(\.path) == [["extensionCompat", "a"]])
    }

    @Test func newKeysDefaultAndRoundTrip() throws {
        let empty = try PaddleConfig.decode(Data("{}".utf8))
        #expect(empty.extensionCompat.isEmpty && empty.extensionUpdates && empty.sitePersonas.isEmpty)
        let config = PaddleConfig(extensionCompat: ["a": ExtensionCompatConfig(persona: .chrome)], extensionUpdates: false, sitePersonas: ["example.com": .chrome])
        #expect(try PaddleConfig.decode(config.encoded()) == config)
    }

    @Test func inPrivateOverridesTheGlobalSwitchPerFolder() throws {
        let json = #"{"extensionCompat": {"a": {"private": true}, "b": {"private": false}}}"#
        let on = try PaddleConfig.decode(Data(#"{"extensionsInPrivate": true, "extensionCompat": {"a": {"private": true}, "b": {"private": false}}}"#.utf8))
        #expect(on.extensionAllowedInPrivate(folder: "a"))
        #expect(!on.extensionAllowedInPrivate(folder: "b"))
        #expect(on.extensionAllowedInPrivate(folder: "c"))
        let off = try PaddleConfig.decode(Data(json.utf8))
        #expect(off.extensionAllowedInPrivate(folder: "a"))
        #expect(!off.extensionAllowedInPrivate(folder: "b"))
        #expect(!off.extensionAllowedInPrivate(folder: "c"))
    }

    @Test func anyExtensionInPrivateCountsGlobalAndOverrides() {
        #expect(!PaddleConfig(extensionsInPrivate: false).anyExtensionInPrivate)
        #expect(PaddleConfig(extensionsInPrivate: false, extensionCompat: ["a": ExtensionCompatConfig(inPrivate: true)]).anyExtensionInPrivate)
        #expect(PaddleConfig(extensionsInPrivate: true, extensionCompat: ["a": ExtensionCompatConfig(inPrivate: false)]).anyExtensionInPrivate)
    }

    @Test func inPrivateEncodesAsPrivateAndRoundTrips() throws {
        let entry = ExtensionCompatConfig(inPrivate: true)
        let data = try JSONEncoder().encode(entry)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["private"] as? Bool == true)
        #expect(object["inPrivate"] == nil)
        #expect(try JSONDecoder().decode(ExtensionCompatConfig.self, from: data) == entry)
    }

    @Test func inPrivateCountsAsAnEntryButNotForReloads() {
        #expect(ExtensionCompatConfig().isEmpty)
        #expect(!ExtensionCompatConfig(inPrivate: true).isEmpty)
        #expect(ExtensionCompatConfig(persona: .chrome, inPrivate: true).reloadKey == ExtensionCompatConfig(persona: .chrome, inPrivate: false).reloadKey)
        #expect(ExtensionCompatConfig(persona: .chrome, inPrivate: true).reloadKey != ExtensionCompatConfig(persona: .firefox, inPrivate: true).reloadKey)
    }

    @Test func sitePersonaMatchesLongestHostSuffix() {
        let config = PaddleConfig(sitePersonas: ["google.com": .chrome, "mail.google.com": .none, "mozilla.org": .firefox, "x.org": .native])
        #expect(config.sitePersona(forHost: "docs.google.com") == .chrome)
        #expect(config.sitePersona(forHost: "GOOGLE.COM.") == .chrome)
        #expect(config.sitePersona(forHost: "mail.google.com") == nil)
        #expect(config.sitePersona(forHost: "www.mozilla.org") == .firefox)
        #expect(config.sitePersona(forHost: "x.org") == nil)
        #expect(config.sitePersona(forHost: "notgoogle.com") == nil)
    }

    @Test func pageUserAgentFollowsThePersonaUnlessSiteUserAgentWins() {
        let config = PaddleConfig(
            siteUserAgents: ["ua.example": "Custom", "empty.example": ""],
            sitePersonas: ["example.com": .chrome, "ua.example": .firefox, "quiet.example.com": .none, "empty.example": .chrome, "mozilla.org": .firefox]
        )
        #expect(config.pageUserAgent(forHost: "docs.example.com") == Persona.chrome.userAgent())
        #expect(config.pageUserAgent(forHost: "ua.example") == "Custom")
        #expect(config.pageUserAgent(forHost: "empty.example") == Persona.chrome.userAgent())
        #expect(config.pageUserAgent(forHost: "www.mozilla.org") == Persona.firefox.userAgent())
        #expect(config.pageUserAgent(forHost: "quiet.example.com") == nil)
        #expect(config.pageUserAgent(forHost: "other.org") == nil)
    }

    @Test func builtInSiteFixAppliesOnlyWhereConfigIsSilent() {
        let firefox = Persona.firefox.userAgent(.current)
        let empty = PaddleConfig()
        #expect(empty.pageUserAgent(forHost: "account.proton.me") == firefox)
        #expect(empty.pageUserAgent(forHost: "pass.proton.me") == firefox)
        #expect(empty.pageUserAgent(forHost: "proton.me") == nil)
        #expect(empty.pageUserAgent(forHost: "mail.proton.me") == nil)
        #expect(PaddleConfig(siteUserAgents: ["pass.proton.me": "Custom"]).pageUserAgent(forHost: "pass.proton.me") == "Custom")
        #expect(PaddleConfig(siteUserAgents: ["proton.me": ""]).pageUserAgent(forHost: "pass.proton.me") == nil)
        #expect(PaddleConfig(sitePersonas: ["proton.me": .none]).pageUserAgent(forHost: "account.proton.me") == nil)
        #expect(PaddleConfig(sitePersonas: ["account.proton.me": .chrome]).pageUserAgent(forHost: "account.proton.me") == Persona.chrome.userAgent(.current))
        #expect(PaddleConfig(siteUserAgents: ["example.com": "Custom"]).pageUserAgent(forHost: "account.proton.me") == firefox)
    }

    @Test func builtInSiteFixesAreWellFormed() {
        for (host, entry) in SiteCompat.defaults {
            #expect(PaddleConfig.normalizedHost(host) == host)
            #expect(entry.persona == .chrome || entry.persona == .firefox)
            #expect(!entry.reason.isEmpty)
        }
    }

    @Test func validatorFlagsBadPersonaEntries() {
        let config = PaddleConfig(
            extensionCompat: ["a/b": ExtensionCompatConfig(), "ff": ExtensionCompatConfig(persona: .firefox, publicID: true), "ok": ExtensionCompatConfig(persona: .chrome, publicID: true)],
            sitePersonas: ["https://x.com": .chrome, "y.com": .native, "z.com": .firefox]
        )
        let paths = ConfigValidator.issues(config, actionNames: []).filter { $0.severity == .warning }.map { $0.path.joined(separator: ".") }
        #expect(paths == ["sitePersonas.https://x.com", "sitePersonas.y.com", "extensionCompat.a/b", "extensionCompat.ff.publicID"])
    }
}
