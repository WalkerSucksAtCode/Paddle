import Foundation
@testable import PaddleCore
import Testing

/// Writes a Chromium SNSS session file: the header, then commands with the pickle padding Chrome uses.
struct SNSSBuilder {
    var data = Data()

    init(version: Int32 = 3) {
        data.append(contentsOf: Self.le(0x5353_4E53))
        data.append(contentsOf: Self.le(version))
    }

    static func le(_ value: Int32) -> [UInt8] {
        let v = UInt32(bitPattern: value)
        return [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }

    mutating func command(_ id: UInt8, _ payload: [UInt8]) {
        let size = payload.count + 1
        data.append(contentsOf: [UInt8(size & 0xFF), UInt8(size >> 8)])
        data.append(id)
        data.append(contentsOf: payload)
    }

    mutating func ints(_ id: UInt8, _ values: Int32...) {
        command(id, values.flatMap(Self.le))
    }

    mutating func tab(_ tab: Int32, window: Int32, index: Int32, pinned: Bool = false) {
        ints(0, window, tab)
        ints(2, tab, index)
        if pinned { command(12, Self.le(tab) + [1, 0, 0, 0]) }
    }

    mutating func navigation(tab: Int32, index: Int32, url: String, title: String = "") {
        var body = Self.le(tab) + Self.le(index)
        let urlBytes = Array(url.utf8)
        body += Self.le(Int32(urlBytes.count)) + urlBytes + [UInt8](repeating: 0, count: (4 - urlBytes.count % 4) % 4)
        let units = Array(title.utf16)
        body += Self.le(Int32(units.count))
        for unit in units { body += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        if units.count % 2 == 1 { body += [0, 0] }
        command(6, Self.le(Int32(body.count)) + body)
    }

    mutating func page(tab: Int32, window: Int32, index: Int32, url: String, title: String = "", pinned: Bool = false) {
        self.tab(tab, window: window, index: index, pinned: pinned)
        navigation(tab: tab, index: 0, url: url, title: title)
        ints(7, tab, 0)
    }
}

struct BrowserSessionImportTests {
    private func chromeSource(_ fixture: ImportFixture) throws -> ImportSource {
        let dir = try fixture.path("profile/x").deletingLastPathComponent()
        return source(.chrome, dir)
    }

    private func source(_ browser: ImportSource.Browser, _ dir: URL) -> ImportSource {
        ImportSource(
            browser: browser, profileName: "Test", directory: dir, historyFile: dir.appending(path: "History"),
            settingsFile: dir.appending(path: "Preferences"), hasHistory: false, hasSettings: false, hasOpenTabs: true)
    }

    private func writeSession(_ builder: SNSSBuilder, _ fixture: ImportFixture, as name: String = "Sessions/Session_13") throws {
        try builder.data.write(to: fixture.path("profile/\(name)"))
    }

    // MARK: - Chromium

    @Test func replaysWindowsTabsPinsSelectionAndClosures() throws {
        let fixture = try ImportFixture()
        var s = SNSSBuilder()
        // Window 1: tab 10 web, 11 settings page (selected), 12 pinned, 13 closed, 14 with a pruned history.
        s.page(tab: 10, window: 1, index: 0, url: "https://a.test/", title: "Alpha é")
        s.page(tab: 11, window: 1, index: 1, url: "chrome://settings/")
        s.page(tab: 12, window: 1, index: 2, url: "https://c.test/", pinned: true)
        s.page(tab: 13, window: 1, index: 3, url: "https://closed.test/")
        s.ints(16, 13, 0, 0, 0)
        s.tab(14, window: 1, index: 3)
        for i in 0..<3 { s.navigation(tab: 14, index: Int32(i), url: "https://p.test/\(i)") }
        s.ints(7, 14, 2)
        s.ints(24, 14, 0, 1)
        s.ints(7, 14, 1)
        s.ints(8, 1, 1)
        // Window 2: two tabs, the second selected.
        s.page(tab: 20, window: 2, index: 0, url: "https://w2.test/")
        s.page(tab: 21, window: 2, index: 1, url: "http://w2.test/b")
        s.ints(8, 2, 1)
        // Window 3 is a popup, window 4 was closed.
        s.page(tab: 30, window: 3, index: 0, url: "https://popup.test/")
        s.ints(9, 3, 1)
        s.page(tab: 40, window: 4, index: 0, url: "https://gone.test/")
        s.ints(17, 4)
        // A record cut off by the end of the file.
        s.data.append(contentsOf: [100, 0, 6, 1, 2, 3])
        try writeSession(s, fixture)

        let result = try BrowserSessionReader.read(chromeSource(fixture))
        #expect(result.tabs == 5)
        #expect(result.skippedNotWeb == 1)
        #expect(!result.truncated)
        #expect(result.windows.count == 2)
        #expect(result.windows[0].tabs.map(\.url) == ["https://c.test/", "https://a.test/", "https://p.test/2"])
        #expect(result.windows[0].tabs.map(\.isPinned) == [true, false, false])
        #expect(result.windows[0].tabs[1].title == "Alpha é")
        #expect(result.windows[0].selectedIndex == 1)
        #expect(result.windows[1].tabs.map(\.url) == ["https://w2.test/", "http://w2.test/b"])
        #expect(result.windows[1].selectedIndex == 1)
    }

    @Test func refusesOtherVersions() throws {
        let fixture = try ImportFixture()
        try writeSession(SNSSBuilder(version: 5), fixture)
        #expect(throws: BrowserImportError.unreadable(
            "This session file uses a format Paddle can't read (version 5); newer Chrome versions encrypt it.")
        ) { try BrowserSessionReader.read(chromeSource(fixture)) }
    }

    @Test func picksTheLargestNumberNotTheNewestFile() throws {
        let fixture = try ImportFixture()
        var old = SNSSBuilder()
        old.page(tab: 1, window: 1, index: 0, url: "https://nine.test/")
        var new = SNSSBuilder()
        new.page(tab: 1, window: 1, index: 0, url: "https://ten.test/")
        var tabs = SNSSBuilder()
        tabs.page(tab: 1, window: 1, index: 0, url: "https://tabs.test/")
        try writeSession(new, fixture, as: "Sessions/Session_10")
        try writeSession(old, fixture, as: "Sessions/Session_9")
        try writeSession(tabs, fixture, as: "Sessions/Tabs_99999")
        let result = try BrowserSessionReader.read(chromeSource(fixture))
        #expect(result.windows.first?.tabs.first?.url == "https://ten.test/")
    }

    @Test func fallsBackToCurrentSessionAndReportsMissing() throws {
        let fixture = try ImportFixture()
        #expect(throws: BrowserImportError.missing("The last session")) { try BrowserSessionReader.read(chromeSource(fixture)) }
        var s = SNSSBuilder()
        s.page(tab: 1, window: 1, index: 0, url: "https://old.test/")
        try writeSession(s, fixture, as: "Current Session")
        let result = try BrowserSessionReader.read(chromeSource(fixture))
        #expect(result.tabs == 1)
    }

    @Test func capsTabsAndMovesTheSelection() throws {
        let fixture = try ImportFixture()
        var s = SNSSBuilder()
        for i in 0..<520 { s.page(tab: Int32(i), window: 1, index: Int32(i), url: "https://t.test/\(i)") }
        s.ints(8, 1, 510)
        try writeSession(s, fixture)
        let result = try BrowserSessionReader.read(chromeSource(fixture))
        #expect(result.tabs == BrowserSessionReader.tabCap)
        #expect(result.truncated)
        #expect(result.windows[0].tabs.count == 500)
        #expect(result.windows[0].selectedIndex == 499)
    }

    @Test func safariIsRefused() throws {
        let fixture = try ImportFixture()
        #expect(throws: BrowserImportError.unreadable("Paddle can't read Safari's open tabs yet.")) {
            try BrowserSessionReader.read(source(.safari, fixture.home))
        }
    }

    // MARK: - Firefox

    private func firefoxSource(_ fixture: ImportFixture) -> ImportSource { source(.firefox, fixture.home.appending(path: "profile")) }

    private func writeFirefox(_ object: Any, _ fixture: ImportFixture, as name: String) throws {
        let json = try JSONSerialization.data(withJSONObject: object)
        try ImportFixture.mozLZ4(json).write(to: fixture.path("profile/\(name)"))
    }

    private func entry(_ url: String, _ title: String = "") -> [String: Any] { ["url": url, "title": title] }

    @Test func firefoxSelectedPinnedHiddenAndNotWeb() throws {
        let fixture = try ImportFixture()
        let session: [String: Any] = [
            "windows": [[
                "selected": 2,
                "tabs": [
                    ["index": 1, "entries": [entry("https://a.test/", "A")]],
                    ["pinned": true, "index": 1, "entries": [entry("https://b1.test/"), entry("https://b2.test/")]],
                    ["hidden": true, "entries": [entry("https://hidden.test/")]],
                    ["entries": [entry("about:newtab")]],
                ],
            ]],
            "_closedWindows": [["tabs": [["entries": [entry("https://closed.test/")]]]]],
        ]
        try writeFirefox(session, fixture, as: "sessionstore.jsonlz4")
        let result = try BrowserSessionReader.read(firefoxSource(fixture))
        #expect(result.windows.count == 1)
        #expect(result.windows[0].tabs.map(\.url) == ["https://b1.test/", "https://a.test/"])
        #expect(result.windows[0].tabs.map(\.isPinned) == [true, false])
        #expect(result.windows[0].selectedIndex == 0)
        #expect(result.tabs == 2)
        #expect(result.skippedNotWeb == 1)
    }

    @Test func firefoxClampsTheEntryIndex() throws {
        let fixture = try ImportFixture()
        let entries = [entry("https://e1.test/"), entry("https://e2.test/")]
        let session: [String: Any] = ["windows": [["selected": 1, "tabs": [
            ["index": 9, "entries": entries], ["index": 0, "entries": entries], ["entries": entries],
        ]]]]
        try writeFirefox(session, fixture, as: "sessionstore.jsonlz4")
        let result = try BrowserSessionReader.read(firefoxSource(fixture))
        #expect(result.windows[0].tabs.map(\.url) == ["https://e2.test/", "https://e1.test/", "https://e2.test/"])
    }

    @Test func firefoxFilePreferenceOrder() throws {
        func session(_ url: String) -> [String: Any] { ["windows": [["tabs": [["entries": [entry(url)]]]]]] }
        func firstURL(_ fixture: ImportFixture) throws -> String? {
            try BrowserSessionReader.read(firefoxSource(fixture)).windows.first?.tabs.first?.url
        }
        let fixture = try ImportFixture()
        try writeFirefox(session("https://previous.test/"), fixture, as: "sessionstore-backups/previous.jsonlz4")
        #expect(try firstURL(fixture) == "https://previous.test/")
        try writeFirefox(session("https://recovery.test/"), fixture, as: "sessionstore-backups/recovery.jsonlz4")
        #expect(try firstURL(fixture) == "https://recovery.test/")
        try writeFirefox(session("https://primary.test/"), fixture, as: "sessionstore.jsonlz4")
        #expect(try firstURL(fixture) == "https://primary.test/")
    }

    @Test func firefoxFallsBackToTheBakFileOnce() throws {
        let fixture = try ImportFixture()
        try Data("not mozlz4".utf8).write(to: fixture.path("profile/sessionstore.jsonlz4"))
        #expect(throws: BrowserImportError.unreadable("Paddle couldn't read Firefox's last session.")) {
            try BrowserSessionReader.read(firefoxSource(fixture))
        }
        let session: [String: Any] = ["windows": [["tabs": [["entries": [entry("https://bak.test/")]]]]]]
        try writeFirefox(session, fixture, as: "sessionstore-backups/recovery.baklz4")
        #expect(try BrowserSessionReader.read(firefoxSource(fixture)).windows.first?.tabs.first?.url == "https://bak.test/")
    }
}
