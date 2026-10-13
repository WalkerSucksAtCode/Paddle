import Foundation
@testable import PaddleCore
import Testing

struct MozLZ4Tests {
    @Test func decodesALiteralOnlyBlock() throws {
        let text = Data("{\"hello\":\"world\"}".utf8)
        #expect(try MozLZ4.decompress(ImportFixture.mozLZ4(text)) == text)
    }

    @Test func decodesLongLiteralRuns() throws {
        // 15 + 255 + 40 literals: the length continues over two extra bytes.
        let text = Data(String(repeating: "x", count: 310).utf8)
        #expect(try MozLZ4.decompress(ImportFixture.mozLZ4(text)) == text)
    }

    @Test func decodesMatchesIncludingOverlappingOnes() throws {
        // "abc", then a 9-byte match 3 back ("abcabcabc"), then the literal "x".
        let block: [UInt8] = [0x35, 0x61, 0x62, 0x63, 0x03, 0x00, 0x10, 0x78]
        #expect(try MozLZ4.decompress(ImportFixture.mozLZ4(block: block, size: 13)) == Data("abcabcabcabcx".utf8))
        // "a", then an 8-byte match 1 back: offset 1 repeats the last byte.
        let run: [UInt8] = [0x14, 0x61, 0x01, 0x00]
        #expect(try MozLZ4.decompress(ImportFixture.mozLZ4(block: run, size: 9)) == Data("aaaaaaaaa".utf8))
    }

    @Test func decodesALongMatch() throws {
        // "a" then a match of 4 + 15 + 255 + 6 = 280 bytes at offset 1.
        let block: [UInt8] = [0x1F, 0x61, 0x01, 0x00, 0xFF, 0x06]
        let data = try MozLZ4.decompress(ImportFixture.mozLZ4(block: block, size: 281))
        #expect(data == Data(String(repeating: "a", count: 281).utf8))
    }

    @Test func refusesWhatIsNotMozLZ4() {
        #expect(throws: MozLZ4.Error.notMozLZ4) { try MozLZ4.decompress(Data()) }
        #expect(throws: MozLZ4.Error.notMozLZ4) { try MozLZ4.decompress(Data("mozLz40".utf8)) }
        var wrong = ImportFixture.mozLZ4(Data("hi".utf8))
        wrong[0] = 0x58
        #expect(throws: MozLZ4.Error.notMozLZ4) { try MozLZ4.decompress(wrong) }
    }

    @Test func capsTheOutputBeforeAllocatingIt() {
        let huge = ImportFixture.mozLZ4(block: [0x00], size: 0x7FFF_FFFF)
        #expect(throws: MozLZ4.Error.tooLarge(declared: 0x7FFF_FFFF)) { try MozLZ4.decompress(huge) }
        let atCap = ImportFixture.mozLZ4(block: [0x00], size: 17)
        #expect(throws: MozLZ4.Error.tooLarge(declared: 17)) { try MozLZ4.decompress(atCap, maxOutput: 16) }
        #expect(MozLZ4.defaultMaxOutput == 16 * 1024 * 1024)
    }

    @Test func refusesCorruptBlocksWithoutTrapping() {
        func corrupt(_ block: [UInt8], size: Int) {
            #expect(throws: MozLZ4.Error.self, "block \(block) size \(size)") {
                try MozLZ4.decompress(ImportFixture.mozLZ4(block: block, size: size))
            }
        }
        corrupt([0x50, 0x61], size: 5) // 5 literals promised, 1 present
        corrupt([0x1F], size: 100) // literal length extension missing
        corrupt([0xF0, 0xFF, 0xFF], size: 10) // extended literal length runs on past the end
        corrupt([0x10, 0x61, 0x01], size: 5) // match offset cut off
        corrupt([0x10, 0x61, 0x00, 0x00], size: 5) // offset 0
        corrupt([0x10, 0x61, 0x02, 0x00], size: 5) // offset before the start of the output
        corrupt([0x1F, 0x61, 0x01, 0x00, 0xFF], size: 281) // match length extension missing
        corrupt([0x1F, 0x61, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0x01], size: 50) // match longer than the declared size
        corrupt([0x20, 0x61, 0x62], size: 1) // more literals than the declared size
        corrupt([0x20, 0x61, 0x62], size: 5) // fewer bytes than declared
    }

    @Test func survivesRandomBytes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let block = (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? MozLZ4.decompress(ImportFixture.mozLZ4(block: block, size: Int.random(in: 0...200, using: &generator)))
        }
    }
}

struct SearchEngineRecognitionTests {
    @Test func namesAndIdentifiers() {
        #expect(SearchEngine.preset(named: "DuckDuckGo") == .duckDuckGo)
        #expect(SearchEngine.preset(named: "ddg@search.mozilla.org") == .duckDuckGo)
        #expect(SearchEngine.preset(named: "google@search.mozilla.org") == .google)
        #expect(SearchEngine.preset(named: "com.google.www") == .google)
        #expect(SearchEngine.preset(named: "Bing") == .bing)
        #expect(SearchEngine.preset(named: "Brave Search") == .brave)
        #expect(SearchEngine.preset(named: "Ecosia") == .ecosia)
        #expect(SearchEngine.preset(named: "Kagi") == .kagi)
        #expect(SearchEngine.preset(named: "Google Scholar") == nil)
        #expect(SearchEngine.preset(named: "Yahoo") == nil)
        #expect(SearchEngine.preset(named: "") == nil)
    }

    @Test func searchURLs() {
        #expect(SearchEngine.preset(forSearchURL: "{google:baseURL}search?q={searchTerms}") == nil)
        #expect(SearchEngine.preset(forSearchURL: "https://www.google.com/search?q={searchTerms}&sourceid=chrome") == .google)
        #expect(SearchEngine.preset(forSearchURL: "https://www.google.co.uk/search?q=%s") == .google)
        #expect(SearchEngine.preset(forSearchURL: "https://scholar.google.com/scholar?q={searchTerms}") == nil)
        #expect(SearchEngine.preset(forSearchURL: "https://google.evil.com/search?q={searchTerms}") == nil)
        #expect(SearchEngine.preset(forSearchURL: "https://duckduckgo.com/?q={searchTerms}") == .duckDuckGo)
        #expect(SearchEngine.preset(forSearchURL: "https://www.bing.com/search?q={searchTerms}&form=QBLH") == .bing)
        #expect(SearchEngine.preset(forSearchURL: "https://search.brave.com/search?q={searchTerms}") == .brave)
        #expect(SearchEngine.preset(forSearchURL: "https://kagi.com/search?q={searchTerms}") == .kagi)
        #expect(SearchEngine.preset(forSearchURL: "https://www.ecosia.org/search?q={searchTerms}") == .ecosia)
        #expect(SearchEngine.preset(forSearchURL: "https://search.yahoo.com/search?p={searchTerms}") == nil)
        #expect(SearchEngine.preset(forSearchURL: "javascript:alert(1)") == nil)
    }
}

struct BrowserDiscoveryTests {
    @Test func listsSafariEvenWithNoFilesAndNothingElseOnAnEmptyHome() throws {
        let fixture = try ImportFixture()
        let sources = BrowserImport.discoverSources(home: fixture.home)
        #expect(sources.map(\.browser) == [.safari])
        let safari = try #require(sources.first)
        #expect(safari.historyFile.path.hasSuffix("/Library/Safari/History.db"))
        #expect(safari.settingsFile.path.hasSuffix("/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"))
        #expect(safari.title == "Safari")
    }

    @Test func findsChromeProfilesWithTheirNames() throws {
        let fixture = try ImportFixture()
        _ = try fixture.chromeHistory(at: "Library/Application Support/Google/Chrome/Default/History")
        _ = try fixture.chromeHistory(at: "Library/Application Support/Google/Chrome/Profile 2/History")
        _ = try fixture.write("{}", to: "Library/Application Support/Google/Chrome/Profile 1/Preferences")
        // A folder with neither file, and an unrelated folder, are not profiles.
        try FileManager.default.createDirectory(
            at: fixture.path("Library/Application Support/Google/Chrome/Profile 9/Cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.path("Library/Application Support/Google/Chrome/Crashpad/x"), withIntermediateDirectories: true)
        _ = try fixture.write("""
            {"profile": {"info_cache": {"Default": {"name": "Walker", "user_name": "ignored@example.com"},
                                         "Profile 2": {"name": "Work"}}}}
            """, to: "Library/Application Support/Google/Chrome/Local State")

        let chrome = BrowserImport.discoverSources(home: fixture.home).filter { $0.browser == .chrome }
        #expect(chrome.map(\.profileName) == ["Walker", "Profile 1", "Work"])
        #expect(chrome.map(\.title) == ["Google Chrome – Walker", "Google Chrome – Profile 1", "Google Chrome – Work"])
        #expect(chrome.map(\.hasHistory) == [true, false, true])
        #expect(chrome.map(\.hasSettings) == [false, true, false])
        #expect(chrome[0].historyFile.lastPathComponent == "History")
        #expect(chrome[0].settingsFile.lastPathComponent == "Preferences")
    }

    @Test func findsTheOtherChromiumFamilyBrowsersByTheirOwnFolders() throws {
        let fixture = try ImportFixture()
        _ = try fixture.chromeHistory(at: "Library/Application Support/BraveSoftware/Brave-Browser/Default/History")
        _ = try fixture.chromeHistory(at: "Library/Application Support/Microsoft Edge/Default/History")
        _ = try fixture.chromeHistory(at: "Library/Application Support/Arc/User Data/Default/History")
        _ = try fixture.chromeHistory(at: "Library/Application Support/Chromium/Default/History")
        #expect(BrowserImport.discoverSources(home: fixture.home).map(\.browser) == [.safari, .brave, .edge, .arc, .chromium])
    }

    @Test func findsFirefoxProfilesFromProfilesIni() throws {
        let fixture = try ImportFixture()
        let base = "Library/Application Support/Firefox"
        _ = try fixture.firefoxHistory(at: "\(base)/Profiles/abc.default-release/places.sqlite")
        _ = try fixture.write("user_pref(\"a\", 1);\n", to: "\(base)/Profiles/old.default/prefs.js")
        let absolute = try fixture.firefoxHistory(at: "elsewhere/xyz.work/places.sqlite")
        _ = try fixture.write("""
            [Install4F96D1932A9F858E]
            Default=Profiles/abc.default-release
            Locked=1

            [Profile2]
            Name=work
            IsRelative=0
            Path=\(absolute.deletingLastPathComponent().path)

            [Profile1]
            Name=old
            IsRelative=1
            Path=Profiles/old.default

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release
            Default=1

            [Profile3]
            Name=gone
            IsRelative=1
            Path=Profiles/missing

            [General]
            StartWithLastProfile=1
            """, to: "\(base)/profiles.ini")

        let firefox = BrowserImport.discoverSources(home: fixture.home).filter { $0.browser == .firefox }
        #expect(firefox.map(\.profileName) == ["default-release", "work", "old"])
        #expect(firefox[0].historyFile.lastPathComponent == "places.sqlite")
        #expect(firefox[0].searchFile?.lastPathComponent == "search.json.mozlz4")
        #expect(firefox.map(\.hasHistory) == [true, true, false])
        #expect(firefox.map(\.hasSettings) == [false, false, true])
    }

    /// macOS refusing Chrome's folder leaves one source saying so, and a readable Brave is still found.
    @Test func aRefusedChromeFolderIsOneSourceAndHidesNoOthers() throws {
        let fixture = try ImportFixture()
        _ = try fixture.chromeHistory(at: "Library/Application Support/Google/Chrome/Default/History")
        _ = try fixture.chromeHistory(at: "Library/Application Support/BraveSoftware/Brave-Browser/Default/History")
        let chromeBase = fixture.home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chromeBase.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chromeBase.path) }
        // As root nothing is protected; skip rather than fail there.
        guard !FileManager.default.isReadableFile(atPath: chromeBase.path) else { return }

        let sources = BrowserImport.discoverSources(home: fixture.home)
        #expect(sources.map(\.browser) == [.safari, .chrome, .brave])
        let chrome = try #require(sources.first { $0.browser == .chrome })
        #expect(chrome.needsFullDiskAccess)
        #expect(chrome.profileName.isEmpty)
        #expect(chrome.title == "Google Chrome")
        #expect(!chrome.hasHistory && !chrome.hasSettings)
        let brave = try #require(sources.first { $0.browser == .brave })
        #expect(!brave.needsFullDiskAccess)
        #expect(brave.hasHistory)
    }

    /// A profiles.ini macOS refuses reads as a Firefox source that needs Full Disk Access, not as no Firefox.
    @Test func aRefusedFirefoxProfilesIniIsOneSource() throws {
        let fixture = try ImportFixture()
        let ini = try fixture.write("[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\n",
                                    to: "Library/Application Support/Firefox/profiles.ini")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ini.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ini.path) }
        // As root nothing is protected; skip rather than fail there.
        guard !FileManager.default.isReadableFile(atPath: ini.path) else { return }

        let firefox = BrowserImport.discoverSources(home: fixture.home).filter { $0.browser == .firefox }
        #expect(firefox.count == 1)
        #expect(firefox.first?.needsFullDiskAccess == true)
        #expect(firefox.first?.title == "Firefox")
    }
}

struct BrowserSettingsImportTests {
    func source(_ browser: ImportSource.Browser, settings: URL, search: URL? = nil) -> ImportSource {
        ImportSource(
            browser: browser, profileName: "", directory: settings.deletingLastPathComponent(),
            historyFile: settings.deletingLastPathComponent().appending(path: "history"), settingsFile: settings,
            searchFile: search, hasHistory: true, hasSettings: true)
    }

    func map(_ settings: BrowserSettings, current: PaddleConfig = PaddleConfig(), bar: Bool = true) -> SettingsImport {
        SettingsMapper.map(settings, current: current, currentShowBookmarksBar: bar)
    }

    // MARK: - Safari

    func writePlist(_ fixture: ImportFixture, _ dictionary: [String: Any], binary: Bool) throws -> URL {
        let url = try fixture.path("Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist")
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: binary ? .binary : .xml, options: 0).write(to: url)
        return url
    }

    @Test(arguments: [true, false]) func readsSafariPlists(binary: Bool) throws {
        let fixture = try ImportFixture()
        let url = try writePlist(fixture, [
            "SearchProviderShortName": "Google",
            "HomePage": "https://example.com/start",
            "NewWindowBehavior": 0,
            "NewTabBehavior": 0,
            "ShowFavoritesBar-v2": false,
        ], binary: binary)
        let settings = try BrowserSettingsReader.read(source(.safari, settings: url))
        #expect(settings.searchEngineName == "Google")
        #expect(settings.homepage == "https://example.com/start")
        #expect(settings.newTabPage == "https://example.com/start")
        #expect(settings.showBookmarksBar == false)
    }

    @Test func safariHomePageIsIgnoredWhenNewWindowsDontOpenIt() {
        let settings = BrowserSettingsReader.safariSettings([
            "HomePage": "https://www.apple.com/startpage/", "NewWindowBehavior": 4, "NewTabBehavior": 4,
        ])
        #expect(settings.homepage == nil)
        #expect(settings.newTabPage == nil)
        #expect(settings.reasons[.homepage] == "Safari's new windows don't open a home page.")
        #expect(settings.reasons[.searchEngine] != nil)
        #expect(settings.reasons[.bookmarksBar] != nil)
    }

    @Test func aMissingSafariPlistIsMissingAndAProtectedOneIsAccessDenied() throws {
        let fixture = try ImportFixture()
        let missing = source(.safari, settings: fixture.home.appending(path: "nope/com.apple.Safari.plist"))
        #expect(throws: BrowserImportError.missing("Safari's com.apple.Safari.plist")) { try BrowserSettingsReader.read(missing) }
        let url = try writePlist(fixture, ["HomePage": "https://example.com"], binary: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        guard !FileManager.default.isReadableFile(atPath: url.path) else { return }
        #expect(throws: BrowserImportError.accessDenied(.safari)) { try BrowserSettingsReader.read(source(.safari, settings: url)) }
    }

    // MARK: - Chrome

    @Test func readsChromePreferences() throws {
        let fixture = try ImportFixture()
        let url = try fixture.write("""
            {"homepage": "https://example.com/home", "homepage_is_newtabpage": false,
             "bookmark_bar": {"show_on_all_tabs": true},
             "default_search_provider_data": {"template_url_data": {"short_name": "Bing",
                "url": "https://www.bing.com/search?q={searchTerms}&form=QBLH"}}}
            """, to: "Library/Application Support/Google/Chrome/Default/Preferences")
        let settings = try BrowserSettingsReader.read(source(.chrome, settings: url))
        #expect(settings.searchEngineName == "Bing")
        #expect(settings.homepage == "https://example.com/home")
        #expect(settings.showBookmarksBar == true)
        #expect(settings.reasons[.newTabPage] != nil)
    }

    @Test func chromeStartupPagesCountWhenThereIsNoHomeButtonPage() {
        let settings = BrowserSettingsReader.chromiumSettings([
            "homepage_is_newtabpage": true,
            "session": ["restore_on_startup": 4, "startup_urls": ["https://example.org/a", "https://example.org/b"]],
        ], browserName: "Chrome")
        #expect(settings.homepage == "https://example.org/a")
        let plain = BrowserSettingsReader.chromiumSettings(["homepage_is_newtabpage": true], browserName: "Chrome")
        #expect(plain.homepage == nil)
        #expect(plain.reasons[.homepage] == "Chrome opens its new tab page, not a web address.")
        #expect(plain.reasons[.searchEngine] != nil)
    }

    // MARK: - Firefox

    @Test func parsesFirefoxPrefs() {
        let prefs = BrowserSettingsReader.parseFirefoxPrefs("""
            // Mozilla User Preferences
            user_pref("browser.startup.homepage", "https://example.com/a\\u0026b|https://example.org");
            user_pref("browser.toolbars.bookmarks.visibility", "always");
            user_pref("browser.newtabpage.enabled", false);
            user_pref("browser.startup.page", 3);
            user_pref("quoted", "say \\"hi\\" \\\\ there");
            user_pref("broken", "no end
            user_pref("object", {not: supported});
            """)
        #expect(prefs["browser.startup.homepage"] as? String == "https://example.com/a&b|https://example.org")
        #expect(prefs["browser.toolbars.bookmarks.visibility"] as? String == "always")
        #expect(prefs["browser.newtabpage.enabled"] as? Bool == false)
        #expect(prefs["browser.startup.page"] as? Int == 3)
        #expect(prefs["quoted"] as? String == "say \"hi\" \\ there")
        #expect(prefs["broken"] == nil)
        #expect(prefs["object"] == nil)
    }

    func firefoxSearchJSON(defaultID: String? = "ddg@search.mozilla.org", current: String? = nil) -> Data {
        var meta: [String: Any] = [:]
        if let defaultID { meta["defaultEngineId"] = defaultID }
        if let current { meta["current"] = current }
        let engines: [[String: Any]] = [
            ["id": "google@search.mozilla.org", "_name": "Google", "_isAppProvided": true,
             "_urls": [["template": "https://www.google.com/search", "params": [["name": "q", "value": "{searchTerms}"]]]]],
            ["id": "ddg@search.mozilla.org", "_name": "DuckDuckGo", "_isAppProvided": true,
             "_urls": [["template": "https://duckduckgo.com/", "params": [["name": "q", "value": "{searchTerms}"]]]]],
            ["id": "custom-1", "_name": "My Wiki", "_isAppProvided": false,
             "_urls": [["template": "https://wiki.example.com/search?q={searchTerms}"]]],
        ]
        return try! JSONSerialization.data(withJSONObject: ["version": 6, "engines": engines, "metaData": meta])
    }

    @Test func readsFirefoxSettingsAndTheDefaultEngineFromMozLZ4() throws {
        let fixture = try ImportFixture()
        let prefs = try fixture.write("""
            user_pref("browser.startup.homepage", "https://example.com/ff");
            user_pref("browser.toolbars.bookmarks.visibility", "never");
            """, to: "Library/Application Support/Firefox/Profiles/abc.default/prefs.js")
        let search = try fixture.path("Library/Application Support/Firefox/Profiles/abc.default/search.json.mozlz4")
        try ImportFixture.mozLZ4(firefoxSearchJSON()).write(to: search)
        let settings = try BrowserSettingsReader.read(source(.firefox, settings: prefs, search: search))
        #expect(settings.searchEngineName == "DuckDuckGo")
        #expect(settings.searchEngineURL == "https://duckduckgo.com/?q={searchTerms}")
        #expect(settings.homepage == "https://example.com/ff")
        #expect(settings.showBookmarksBar == false)
    }

    @Test func firefoxDefaultEngineByOldCurrentNameAndCustomEngines() {
        let old = try! JSONSerialization.jsonObject(with: firefoxSearchJSON(defaultID: nil, current: "Google")) as! [String: Any]
        #expect(BrowserSettingsReader.firefoxDefaultEngine(old)?.name == "Google")
        #expect(BrowserSettingsReader.firefoxDefaultEngine(old)?.url == "https://www.google.com/search?q={searchTerms}")
        let custom = try! JSONSerialization.jsonObject(with: firefoxSearchJSON(defaultID: "custom-1")) as! [String: Any]
        #expect(BrowserSettingsReader.firefoxDefaultEngine(custom)?.name == "My Wiki")
        let none = try! JSONSerialization.jsonObject(with: firefoxSearchJSON(defaultID: nil)) as! [String: Any]
        #expect(BrowserSettingsReader.firefoxDefaultEngine(none) == nil)
    }

    @Test func aCorruptFirefoxSearchFileIsReportedNotFatal() throws {
        let fixture = try ImportFixture()
        let prefs = try fixture.write("user_pref(\"browser.startup.homepage\", \"https://example.com/ff\");\n", to: "ff/prefs.js")
        let search = try fixture.path("ff/search.json.mozlz4")
        try Data("not mozlz4 at all".utf8).write(to: search)
        let settings = try BrowserSettingsReader.read(source(.firefox, settings: prefs, search: search))
        #expect(settings.homepage == "https://example.com/ff")
        #expect(settings.searchEngineName == nil)
        #expect(settings.reasons[.searchEngine]?.contains("couldn't be decoded") == true)
    }

    // MARK: - Mapping

    @Test func mapsAKnownEngineToItsSearchAndSuggestTemplates() {
        var settings = BrowserSettings()
        settings.searchEngineName = "Google"
        let result = map(settings)
        #expect(result.changes == [
            ConfigChange("searchTemplate", .string("https://www.google.com/search?q=%s")),
            ConfigChange("searchSuggestTemplate", .string("https://suggestqueries.google.com/complete/search?client=firefox&q=%s")),
        ])
        #expect(result.items.first { $0.setting == .searchEngine }?.status == .imported("Google (search and address-bar suggestions)"))
    }

    @Test func theURLWinsOverANameThatIsNotRecognized() {
        var settings = BrowserSettings()
        settings.searchEngineName = "Work search"
        settings.searchEngineURL = "https://kagi.com/search?q={searchTerms}"
        #expect(map(settings).changes.first?.value == .string("https://kagi.com/search?q=%s"))
    }

    @Test func anEngineThePaddleDoesNotOfferIsReportedAndNothingIsWritten() {
        var settings = BrowserSettings()
        settings.searchEngineName = "Yahoo"
        let result = map(settings)
        #expect(result.changes.isEmpty)
        guard case .skipped(let why)? = result.items.first(where: { $0.setting == .searchEngine })?.status else {
            Issue.record("expected a skipped search engine")
            return
        }
        #expect(why.contains("\"Yahoo\""))
        #expect(why.contains("DuckDuckGo"))
    }

    @Test func valuesAlreadyInPaddleAreUnchangedAndWriteNothing() {
        var settings = BrowserSettings()
        settings.searchEngineName = "DuckDuckGo"
        settings.homepage = "https://example.com"
        settings.showBookmarksBar = true
        let current = PaddleConfig(homepage: "https://example.com")
        let result = map(settings, current: current, bar: true)
        #expect(result.changes.isEmpty)
        #expect(result.showBookmarksBar == nil)
        #expect(result.importedCount == 0)
        #expect(result.items.first { $0.setting == .homepage }?.status == .unchanged("https://example.com"))
    }

    @Test func mapsPagesAndTheBookmarksBarSeparately() {
        var settings = BrowserSettings()
        settings.homepage = "https://example.com/home"
        settings.newTabPage = "https://example.com/new"
        settings.showBookmarksBar = false
        let result = map(settings, bar: true)
        #expect(result.changes == [
            ConfigChange("homepage", .string("https://example.com/home")),
            ConfigChange("newTabPage", .string("https://example.com/new")),
        ])
        #expect(result.showBookmarksBar == false)
        #expect(result.importedCount == 3)
    }

    @Test func everySettingGetsAnItemWithAReasonWhenSkipped() {
        let result = map(BrowserSettings())
        #expect(result.items.map(\.setting) == [.searchEngine, .homepage, .newTabPage, .bookmarksBar])
        #expect(result.items.allSatisfy { if case .skipped = $0.status { true } else { false } })
    }

    @Test func mappedChangesApplyThroughConfigFile() throws {
        // The same path Settings saves through, so its conflict rules and default handling apply.
        var settings = BrowserSettings()
        settings.searchEngineName = "Bing"
        settings.homepage = "https://example.com/home"
        let changes = map(settings).changes
        let disk = Data("{\"maxAwakeTabs\": 6}\n".utf8)
        let edited = try ConfigFile.apply(changes: changes, base: disk, disk: disk).get()
        let config = try PaddleConfig.decode(edited)
        #expect(config.searchTemplate == "https://www.bing.com/search?q=%s")
        #expect(config.searchSuggestTemplate == "https://api.bing.com/osjson.aspx?query=%s")
        #expect(config.homepage == "https://example.com/home")
        #expect(config.maxAwakeTabs == 6)
        // A hand edit to the same key since the base was read is a conflict, not an overwrite.
        let changed = Data("{\"homepage\": \"https://hand.example\"}\n".utf8)
        guard case .failure(.conflict(let paths)) = ConfigFile.apply(changes: changes, base: disk, disk: changed) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(paths == [["homepage"]])
    }
}
