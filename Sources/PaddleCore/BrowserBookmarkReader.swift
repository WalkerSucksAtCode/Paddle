import Foundation

/// The bookmarks found in another browser, ready to merge into the bookmark tree.
public struct BookmarkReadResult: Sendable {
    public var tree: BookmarkTree
    /// Bookmarks in `tree`.
    public var bookmarks: Int
    /// Folders in `tree`.
    public var folders: Int
    /// Bookmarks left out because their address isn't a web page (`javascript:`, `place:`, `about:`, `data:`).
    public var skippedNotWeb: Int

    public init(tree: BookmarkTree = BookmarkTree(), bookmarks: Int = 0, folders: Int = 0, skippedNotWeb: Int = 0) {
        self.tree = tree
        self.bookmarks = bookmarks
        self.folders = folders
        self.skippedNotWeb = skippedNotWeb
    }
}

/// Reads another browser's bookmarks: Chromium's `Bookmarks` JSON, Firefox's `moz_bookmarks` table in
/// `places.sqlite` (read from a copy, like history), Safari's `Bookmarks.plist`. Folders that end up empty are dropped.
public enum BrowserBookmarkReader {
    public static func read(_ source: ImportSource) throws -> BookmarkReadResult {
        guard !source.needsFullDiskAccess else { throw BrowserImportError.accessDenied(source.browser) }
        guard source.hasBookmarks, let file = source.bookmarksFile else {
            throw BrowserImportError.missing("\(source.browser.displayName)'s bookmarks")
        }
        var counter = Counter()
        var tree: BookmarkTree
        switch source.browser.family {
        case .chromium: tree = try readChromium(file, source.browser, &counter)
        case .firefox: tree = try readFirefox(file, source.browser, &counter)
        case .safari: tree = try readSafari(file, source.browser, &counter)
        }
        return BookmarkReadResult(
            tree: tree, bookmarks: count(tree.bar + tree.menu).0, folders: count(tree.bar + tree.menu).1,
            skippedNotWeb: counter.skipped)
    }

    private struct Counter {
        var skipped = 0

        /// A bookmark, or nil (and a count) when the address isn't a web page.
        mutating func bookmark(title: String, url: String) -> Bookmark? {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            guard !trimmed.isEmpty else { return nil }
            guard !NetscapeBookmarks.skippedSchemes.contains(where: lowered.hasPrefix) else {
                skipped += 1
                return nil
            }
            return Bookmark(title: title.isEmpty ? trimmed : title, url: trimmed)
        }
    }

    private static func count(_ items: [Bookmark]) -> (Int, Int) {
        var bookmarks = 0, folders = 0
        for item in items {
            if let children = item.children {
                folders += 1
                let inner = count(children)
                bookmarks += inner.0
                folders += inner.1
            } else {
                bookmarks += 1
            }
        }
        return (bookmarks, folders)
    }

    /// A folder, or nil when it ended up empty.
    private static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark? {
        children.isEmpty ? nil : .folder(title: title, children: children)
    }

    private static func fileError(_ error: any Error, _ browser: ImportSource.Browser, _ file: URL) -> BrowserImportError {
        ImportSQLite.translate(error, browser: browser, file: file.lastPathComponent)
    }

    // MARK: - Chromium

    private static func readChromium(_ file: URL, _ browser: ImportSource.Browser, _ counter: inout Counter) throws -> BookmarkTree {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw fileError(error, browser, file) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            throw BrowserImportError.unreadable("\(browser.displayName)'s Bookmarks file isn't in a form Paddle understands.")
        }
        func children(_ key: String) -> [Bookmark] {
            let nodes = ((roots[key] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
            return nodes.compactMap { chromiumNode($0, &counter) }
        }
        var tree = BookmarkTree()
        tree.bar = children("bookmark_bar")
        tree.menu = children("other")
        if let mobile = folder("Mobile Bookmarks", children("synced")) { tree.menu.append(mobile) }
        return tree
    }

    private static func chromiumNode(_ node: [String: Any], _ counter: inout Counter, depth: Int = 0) -> Bookmark? {
        guard depth < 100 else { return nil }
        let title = node["name"] as? String ?? ""
        switch node["type"] as? String {
        case "url":
            guard let url = node["url"] as? String else { return nil }
            return counter.bookmark(title: title, url: url)
        case "folder":
            let kids = ((node["children"] as? [[String: Any]]) ?? []).compactMap { chromiumNode($0, &counter, depth: depth + 1) }
            return folder(title, kids)
        default:
            return nil
        }
    }

    // MARK: - Firefox

    private struct FirefoxRow {
        var id: Int64
        var type: Int64
        var parent: Int64
        var position: Int64
        var title: String
        var guid: String
        var url: String?
        var placeTitle: String
    }

    private static func readFirefox(_ file: URL, _ browser: ImportSource.Browser, _ counter: inout Counter) throws -> BookmarkTree {
        let rows: [FirefoxRow]
        do {
            rows = try ImportSQLite.withCopy(of: file, browser: browser, what: "bookmarks database") { db in
                try ImportSQLite.run(db, """
                    SELECT b.id, b.type, b.parent, b.position, b.title, b.guid, p.url, p.title
                    FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
                    ORDER BY b.parent, b.position
                    """) { stmt in
                    FirefoxRow(
                        id: ImportSQLite.int(stmt, 0), type: ImportSQLite.int(stmt, 1), parent: ImportSQLite.int(stmt, 2),
                        position: ImportSQLite.int(stmt, 3), title: ImportSQLite.text(stmt, 4), guid: ImportSQLite.text(stmt, 5),
                        url: ImportSQLite.isNull(stmt, 6) ? nil : ImportSQLite.text(stmt, 6), placeTitle: ImportSQLite.text(stmt, 7))
                }
            }
        } catch let error as ImportSQLite.Failure {
            throw BrowserImportError.unreadable("This doesn't look like a readable bookmarks database (\(error.message)).")
        }
        let byParent = Dictionary(grouping: rows, by: \.parent)
        func children(of id: Int64, seen: Set<Int64> = []) -> [Bookmark] {
            // A corrupt database can point a folder at its own ancestor; the seen set turns the cycle into a stop.
            var seen = seen
            guard seen.insert(id).inserted else { return [] }
            return (byParent[id] ?? []).sorted { $0.position < $1.position }.compactMap { row -> Bookmark? in
                switch row.type {
                case 1:
                    guard let url = row.url else { return nil }
                    return counter.bookmark(title: row.title.isEmpty ? row.placeTitle : row.title, url: url)
                case 2:
                    return folder(row.title, children(of: row.id, seen: seen))
                default:
                    return nil // separators
                }
            }
        }
        func root(_ guid: String) -> [Bookmark] {
            rows.first { $0.guid == guid }.map { children(of: $0.id) } ?? []
        }
        var tree = BookmarkTree()
        tree.bar = root("toolbar_____")
        tree.menu = root("menu________")
        if let other = folder("Other Bookmarks", root("unfiled_____")) { tree.menu.append(other) }
        if let mobile = folder("Mobile Bookmarks", root("mobile______")) { tree.menu.append(mobile) }
        return tree
    }

    // MARK: - Safari

    private static func readSafari(_ file: URL, _ browser: ImportSource.Browser, _ counter: inout Counter) throws -> BookmarkTree {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw fileError(error, browser, file) }
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw BrowserImportError.unreadable("Safari's Bookmarks.plist isn't in a form Paddle understands.")
        }
        var tree = BookmarkTree()
        for list in (root["Children"] as? [[String: Any]]) ?? [] {
            guard list["WebBookmarkType"] as? String == "WebBookmarkTypeList" else { continue }
            if list["ShouldOmitFromUI"] as? Bool == true { continue }
            let title = list["Title"] as? String ?? ""
            if title == "com.apple.ReadingList" { continue }
            let kids = safariChildren(list, &counter)
            switch title {
            case "BookmarksBar": tree.bar += kids
            case "BookmarksMenu": tree.menu += kids
            default: if let other = folder(title, kids) { tree.menu.append(other) }
            }
        }
        return tree
    }

    private static func safariChildren(_ node: [String: Any], _ counter: inout Counter, depth: Int = 0) -> [Bookmark] {
        guard depth < 100 else { return [] }
        return ((node["Children"] as? [[String: Any]]) ?? []).compactMap { child -> Bookmark? in
            switch child["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = child["URLString"] as? String else { return nil }
                let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                return counter.bookmark(title: title, url: url)
            case "WebBookmarkTypeList":
                if child["ShouldOmitFromUI"] as? Bool == true { return nil }
                return folder(child["Title"] as? String ?? "", safariChildren(child, &counter, depth: depth + 1))
            default:
                return nil // the History proxy
            }
        }
    }
}
