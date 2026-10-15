import Foundation
@testable import PaddleCore
import Testing

struct BrowserSiteSettingsImportTests {
    private func chromeSource(_ fixture: ImportFixture, preferences: String) throws -> ImportSource {
        let file = try fixture.write(preferences, to: "Library/Application Support/Google/Chrome/Default/Preferences")
        return ImportSource(
            browser: .chrome, profileName: "Default", directory: file.deletingLastPathComponent(),
            historyFile: file.deletingLastPathComponent().appending(path: "History"), settingsFile: file,
            hasHistory: false, hasSettings: true, hasSiteSettings: true)
    }

    private func firefoxSource(_ fixture: ImportFixture, directory: URL) -> ImportSource {
        ImportSource(
            browser: .firefox, profileName: "default", directory: directory,
            historyFile: directory.appending(path: "places.sqlite"), settingsFile: directory.appending(path: "prefs.js"),
            hasHistory: false, hasSettings: false, hasSiteSettings: true)
    }

    private static let chromePreferences = """
        {
          "partition": {"per_host_zoom_levels": {
            "0": {
              "example.com": {"zoom_level": 1.0, "last_modified": "13300000000000000"},
              "zero.com": {"zoom_level": 0.0},
              "small.com": {"zoom_level": -2.0},
              "legacy.com": 2.0,
              "www.Www-Host.com": {"zoom_level": 1.0}
            },
            "abc123": {"huge.org": {"zoom_level": 100}}
          }},
          "profile": {"content_settings": {"exceptions": {
            "notifications": {
              "https://[*.]example.com:443,*": {"setting": 1},
              "https://www.shop.com:443,*": {"setting": 2},
              "https://a.com,https://b.com": {"setting": 1},
              "https://ex*mple.com,*": {"setting": 1},
              "file:///tmp/x,*": {"setting": 1},
              "chrome-extension://abcdef/,*": {"setting": 1},
              "https://example.net:8443,*": {"setting": 1},
              "https://ignored.com,*": {"setting": 3},
              "https://zero.com,*": {"setting": 0}
            },
            "geolocation": {
              "[*.]bare.com": {"setting": 2},
              "http://192.168.1.5:80,*": {"setting": 1},
              "*,*": {"setting": 1},
              "about:blank,*": {"setting": 1}
            },
            "javascript": {
              "https://nojs.com,*": {"setting": 2},
              "https://js.com,*": {"setting": 1}
            },
            "cookies": {"https://cookie.com,*": {"setting": 2}}
          }}}
        }
        """

    @Test func readsChromiumZoomAndPermissions() throws {
        let fixture = try ImportFixture()
        let imported = try BrowserSiteSettingsReader.read(chromeSource(fixture, preferences: Self.chromePreferences))
        let sites = imported.sites

        #expect(sites["example.com"] == SiteSettings(zoom: 1.2, notifications: .allow))
        #expect(sites["zero.com"] == nil)
        #expect(sites["small.com"]?.zoom == 0.69) // 1.2^-2 = 0.694
        #expect(sites["legacy.com"]?.zoom == 1.44) // older files: a bare number
        #expect(sites["huge.org"]?.zoom == SitePolicy.zoomRange.upperBound)
        #expect(sites["www-host.com"]?.zoom == 1.2)
        #expect(sites["shop.com"] == SiteSettings(notifications: .deny))
        #expect(sites["bare.com"] == SiteSettings(location: .deny))
        #expect(sites["192.168.1.5"] == SiteSettings(location: .allow))
        #expect(sites["nojs.com"] == SiteSettings(javaScript: false))
        #expect(sites["js.com"] == nil)
        #expect(sites["ignored.com"] == nil)
        #expect(sites["cookie.com"] == nil)
        #expect(sites.count == 9)
        // a,b pair; ex*mple; file; chrome-extension; port 8443; "*,*"; about:blank.
        #expect(imported.skippedPatterns == 7)
    }

    @Test func chromiumErrors() throws {
        let fixture = try ImportFixture()
        #expect(throws: BrowserImportError.unreadable("Google Chrome's Preferences file isn't JSON.")) {
            try BrowserSiteSettingsReader.read(chromeSource(fixture, preferences: "nope"))
        }
        var source = try chromeSource(fixture, preferences: "{}")
        source.settingsFile = source.directory.appending(path: "Gone")
        #expect(throws: BrowserImportError.missing("Google Chrome's Gone")) { try BrowserSiteSettingsReader.read(source) }
        #expect(try BrowserSiteSettingsReader.read(chromeSource(fixture, preferences: "{}")).sites.isEmpty)
    }

    @Test func patternsBecomeHosts() {
        let host = BrowserSiteSettingsReader.host(from:)
        #expect(host("https://[*.]Example.COM:443,*") == "example.com")
        #expect(host("[*.]example.com") == "example.com")
        #expect(host("*.example.com,") == "example.com")
        #expect(host("example.com") == "example.com")
        #expect(host("http://www.example.com:80") == "example.com")
        #expect(host("https://example.com/") == "example.com")
        #expect(host("https://[::1]:443,*") == "[::1]")
        #expect(host("http://example.com:443") == nil)
        #expect(host("https://example.com:80") == nil)
        #expect(host("https://example.com/path") == nil)
        #expect(host("https://example.com,https://other.com") == nil)
        #expect(host("https://*.com,*") == nil)
        #expect(host("*") == nil)
        #expect(host("") == nil)
        #expect(host("https://") == nil)
        #expect(host("ftp://example.com") == nil)
    }

    @Test func readsFirefoxPermissionsAndZoom() throws {
        let fixture = try ImportFixture()
        let directory = try fixture.path("Firefox/Profiles/abc.default/permissions.sqlite").deletingLastPathComponent()
        try fixture.database(directory.appending(path: "permissions.sqlite"), [
            "CREATE TABLE moz_perms (id INTEGER PRIMARY KEY, origin TEXT, type TEXT, permission INTEGER, expireType INTEGER, expireTime INTEGER, modificationTime INTEGER)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://example.com', 'desktop-notification', 1, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://www.shop.com', 'desktop-notification', 2, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://example.com', 'geo', 2, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://session.com', 'geo', 1, 1)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://time.com', 'geo', 1, 2)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://example.com', '3rdPartyStorage^https://x.com', 1, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://auto.com', 'autoplay-media', 1, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://block.com', 'autoplay-media', 5, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://muted.com', 'autoplay-media', 2, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://unk.com', 'desktop-notification', 3, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('https://cookie.com', 'cookie', 1, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('file:///x.html', 'geo', 1, 0)",
            "INSERT INTO moz_perms (origin, type, permission, expireType) VALUES ('http://localhost:3000', 'geo', 1, 0)",
        ])
        try fixture.database(directory.appending(path: "content-prefs.sqlite"), [
            "CREATE TABLE groups (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
            "CREATE TABLE settings (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
            "CREATE TABLE prefs (id INTEGER PRIMARY KEY, groupID INTEGER, settingID INTEGER NOT NULL, value BLOB, timestamp INTEGER)",
            "INSERT INTO groups (id, name) VALUES (1, 'example.com'), (2, 'flat.com'), (3, 'big.com'), (4, 'www.zoomed.com'), (5, 'other.com')",
            "INSERT INTO settings (id, name) VALUES (1, 'browser.content.full-zoom'), (2, 'other.pref')",
            "INSERT INTO prefs (groupID, settingID, value) VALUES (1, 1, 1.5), (2, 1, 1.0), (3, 1, 9.0), (4, 1, 0.8), (5, 2, 2.0)",
        ])

        let imported = try BrowserSiteSettingsReader.read(firefoxSource(fixture, directory: directory))
        let sites = imported.sites
        #expect(sites["example.com"] == SiteSettings(zoom: 1.5, location: .deny, notifications: .allow))
        #expect(sites["shop.com"] == SiteSettings(notifications: .deny))
        #expect(sites["auto.com"] == SiteSettings(autoplay: .allow))
        #expect(sites["block.com"] == SiteSettings(autoplay: .block))
        #expect(sites["big.com"]?.zoom == SitePolicy.zoomRange.upperBound)
        #expect(sites["zoomed.com"]?.zoom == 0.8)
        for absent in ["muted.com", "session.com", "time.com", "unk.com", "cookie.com", "flat.com", "other.com", "x.com"] {
            #expect(sites[absent] == nil, "\(absent)")
        }
        #expect(sites.count == 6)
        #expect(imported.skippedPatterns == 2) // file:// and localhost:3000
    }

    @Test func firefoxUsesWhichFileExists() throws {
        let fixture = try ImportFixture()
        let directory = try fixture.path("ff/permissions.sqlite").deletingLastPathComponent()
        let source = firefoxSource(fixture, directory: directory)
        #expect(throws: BrowserImportError.missing("Firefox's site settings")) { try BrowserSiteSettingsReader.read(source) }

        try fixture.database(directory.appending(path: "content-prefs.sqlite"), [
            "CREATE TABLE groups (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE settings (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE prefs (id INTEGER PRIMARY KEY, groupID INTEGER, settingID INTEGER, value BLOB)",
            "INSERT INTO groups VALUES (1, 'example.com')",
            "INSERT INTO settings VALUES (1, 'browser.content.full-zoom')",
            "INSERT INTO prefs (groupID, settingID, value) VALUES (1, 1, 1.25)",
        ])
        #expect(try BrowserSiteSettingsReader.read(source).sites == ["example.com": SiteSettings(zoom: 1.25)])
    }

    @Test func safariHasNothingToImport() throws {
        let fixture = try ImportFixture()
        let safari = BrowserImport.safari(home: fixture.home)
        #expect(throws: BrowserImportError.unreadable("Safari keeps no per-site zoom or permissions Paddle can import.")) {
            try BrowserSiteSettingsReader.read(safari)
        }
    }

    @Test func mapperFillsOnlyWhatIsMissingAndNotDefault() {
        let imported = ImportedSiteSettings(sites: [
            "b.com": SiteSettings(zoom: 1.25, javaScript: false, autoplay: .block, location: .allow, notifications: .deny),
            "a.com": SiteSettings(zoom: 1, javaScript: true, autoplay: .muted, location: .ask, notifications: .ask),
            "c.com": SiteSettings(zoom: 1.5, location: .deny),
            "d.com": SiteSettings(notifications: .allow),
        ])
        let existing: [String: SiteSettings] = [
            "c.com": SiteSettings(zoom: 2),
            "d.com": SiteSettings(contentBlocking: false),
            "www.b.com": SiteSettings(zoom: 3), // not the exact key
        ]
        let result = SiteSettingsMapper.map(imported, existing: existing)

        #expect(result.changes == [
            ConfigChange(path: ["sites", "b.com", "zoom"], value: .number(1.25)),
            ConfigChange(path: ["sites", "b.com", "javaScript"], value: .bool(false)),
            ConfigChange(path: ["sites", "b.com", "autoplay"], value: .string("block")),
            ConfigChange(path: ["sites", "b.com", "location"], value: .string("allow")),
            ConfigChange(path: ["sites", "b.com", "notifications"], value: .string("deny")),
            ConfigChange(path: ["sites", "c.com", "location"], value: .string("deny")),
            ConfigChange(path: ["sites", "d.com", "notifications"], value: .string("allow")),
        ])
        #expect(result.sitesAdded == 1) // b.com; c.com and d.com already have entries; a.com is all defaults
        #expect(result.keptExisting == 1) // c.com zoom
        #expect(result.fieldsSet == [.zoom: 1, .javaScript: 1, .autoplay: 1, .location: 2, .notifications: 2])
    }

    @Test func mapperOnNothingIsEmpty() {
        let result = SiteSettingsMapper.map(ImportedSiteSettings(), existing: ["a.com": SiteSettings(zoom: 2)])
        #expect(result.changes.isEmpty && result.sitesAdded == 0 && result.keptExisting == 0 && result.fieldsSet.isEmpty)
    }
}
