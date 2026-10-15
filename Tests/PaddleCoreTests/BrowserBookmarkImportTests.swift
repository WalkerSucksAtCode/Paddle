import Foundation
import Testing
@testable import PaddleCore

struct BrowserBookmarkImportTests {
    private func source(_ browser: ImportSource.Browser, file: URL, hasBookmarks: Bool = true) -> ImportSource {
        ImportSource(
            browser: browser, profileName: "", directory: file.deletingLastPathComponent(), historyFile: file, settingsFile: file,
            hasHistory: false, hasSettings: false, bookmarksFile: file, hasBookmarks: hasBookmarks)
    }

    private func titles(_ items: [Bookmark]) -> [String] { items.map(\.title) }

    @Test func readsChromiumBarOtherAndSynced() throws {
        let fixture = try ImportFixture()
        let file = try fixture.write("""
            {"roots": {
              "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
                {"type": "url", "name": "A", "url": "https://example.com/a"},
                {"type": "folder", "name": "Dev", "children": [
                  {"type": "folder", "name": "Empty", "children": []},
                  {"type": "url", "name": "Deep", "url": "https://example.com/deep"}]},
                {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"}]},
              "other": {"type": "folder", "name": "Other", "children": [
                {"type": "url", "name": "", "url": "https://example.org/o"}]},
              "synced": {"type": "folder", "name": "Mobile", "children": [
                {"type": "url", "name": "Phone", "url": "https://example.net/p"}]},
              "workspaces_v2": {"type": "folder", "name": "W", "children": [
                {"type": "url", "name": "Ignored", "url": "https://ignored.example/"}]}}}
            """, to: "Chrome/Default/Bookmarks")
        let result = try BrowserBookmarkReader.read(source(.chrome, file: file))
        #expect(titles(result.tree.bar) == ["A", "Dev"])
        #expect(titles(try #require(result.tree.bar[1].children)) == ["Deep"])
        #expect(titles(result.tree.menu) == ["https://example.org/o", "Mobile Bookmarks"])
        #expect(result.bookmarks == 4)
        #expect(result.folders == 2)
        #expect(result.skippedNotWeb == 1)
    }

    @Test func readsFirefoxRootsInPositionOrder() throws {
        let fixture = try ImportFixture()
        let file = try fixture.path("Firefox/Profiles/p/places.sqlite")
        try fixture.database(file, [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR)",
            "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT)",
            "INSERT INTO moz_places VALUES (1, 'https://example.com/a', 'Place A')",
            "INSERT INTO moz_places VALUES (2, 'https://example.com/b', 'Place B')",
            "INSERT INTO moz_places VALUES (3, 'place:type=6', 'Query')",
            "INSERT INTO moz_places VALUES (4, 'https://example.com/tagged', 'Tagged')",
            "INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________')",
            "INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'menu', 'menu________')",
            "INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____')",
            "INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 2, 'tags', 'tags________')",
            "INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____')",
            "INSERT INTO moz_bookmarks VALUES (6, 2, NULL, 1, 4, 'mobile', 'mobile______')",
            // Toolbar: second inserted first, a separator, a query, an empty folder.
            "INSERT INTO moz_bookmarks VALUES (10, 1, 2, 3, 2, 'B', 'g10')",
            "INSERT INTO moz_bookmarks VALUES (11, 1, 1, 3, 0, NULL, 'g11')",
            "INSERT INTO moz_bookmarks VALUES (12, 3, NULL, 3, 1, NULL, 'g12')",
            "INSERT INTO moz_bookmarks VALUES (13, 1, 3, 3, 3, 'Q', 'g13')",
            "INSERT INTO moz_bookmarks VALUES (14, 2, NULL, 3, 4, 'Empty', 'g14')",
            // Menu: a nested folder.
            "INSERT INTO moz_bookmarks VALUES (20, 2, NULL, 2, 0, 'Sub', 'g20')",
            "INSERT INTO moz_bookmarks VALUES (21, 1, 2, 20, 0, 'In sub', 'g21')",
            // Tags hold bookmark rows that must not be imported.
            "INSERT INTO moz_bookmarks VALUES (30, 2, NULL, 4, 0, 'tagname', 'g30')",
            "INSERT INTO moz_bookmarks VALUES (31, 1, 4, 30, 0, NULL, 'g31')",
            "INSERT INTO moz_bookmarks VALUES (40, 1, 2, 5, 0, 'Loose', 'g40')",
            "INSERT INTO moz_bookmarks VALUES (50, 1, 1, 6, 0, 'Phone', 'g50')",
        ])
        let result = try BrowserBookmarkReader.read(source(.firefox, file: file))
        #expect(titles(result.tree.bar) == ["Place A", "B"])
        #expect(titles(result.tree.menu) == ["Sub", "Other Bookmarks", "Mobile Bookmarks"])
        #expect(result.bookmarks == 5)
        #expect(result.folders == 3)
        #expect(result.skippedNotWeb == 1)
    }

    @Test func readsSafariPlist() throws {
        let fixture = try ImportFixture()
        func leaf(_ title: String, _ url: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title]]
        }
        func list(_ title: String, _ children: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children].merging(extra) { $1 }
        }
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                list("BookmarksBar", [leaf("Bar", "https://example.com/bar"), list("Empty", []), leaf("JS", "javascript:void(0)")]),
                list("BookmarksMenu", [leaf("Menu", "https://example.com/menu")]),
                list("com.apple.ReadingList", [leaf("Read", "https://example.com/read")]),
                list("Hidden", [leaf("H", "https://example.com/h")], extra: ["ShouldOmitFromUI": true]),
                list("Custom", [leaf("C", "https://example.com/c")]),
            ] as [[String: Any]],
        ]
        let file = try fixture.path("Library/Safari/Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)
        let result = try BrowserBookmarkReader.read(source(.safari, file: file))
        #expect(titles(result.tree.bar) == ["Bar"])
        #expect(titles(result.tree.menu) == ["Menu", "Custom"])
        #expect(result.bookmarks == 3)
        #expect(result.folders == 1)
        #expect(result.skippedNotWeb == 1)
    }

    @Test func reportsMissingAndProtectedFiles() throws {
        let fixture = try ImportFixture()
        let nowhere = fixture.home.appending(path: "none/Bookmarks")
        #expect(throws: BrowserImportError.self) { try BrowserBookmarkReader.read(source(.chrome, file: nowhere, hasBookmarks: false)) }
        #expect(throws: BrowserImportError.missing("Google Chrome's Bookmarks")) {
            try BrowserBookmarkReader.read(source(.chrome, file: nowhere))
        }
        #expect(throws: BrowserImportError.missing("Firefox's places.sqlite")) {
            try BrowserBookmarkReader.read(source(.firefox, file: fixture.home.appending(path: "none/places.sqlite")))
        }
        let locked = try fixture.write("{}", to: "Locked/Bookmarks")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(throws: BrowserImportError.accessDenied(.chrome)) { try BrowserBookmarkReader.read(source(.chrome, file: locked)) }
        let lockedPlist = try fixture.write("x", to: "Safari/Bookmarks.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedPlist.path)
        #expect(throws: BrowserImportError.accessDenied(.safari)) { try BrowserBookmarkReader.read(source(.safari, file: lockedPlist)) }
        var placeholder = source(.safari, file: nowhere)
        placeholder.needsFullDiskAccess = true
        #expect(throws: BrowserImportError.accessDenied(.safari)) { try BrowserBookmarkReader.read(placeholder) }
    }
}
