import Foundation
@testable import PaddleCore
import Testing

struct BookmarksTests {
    func mark(_ title: String, _ url: String? = nil) -> Bookmark {
        Bookmark(title: title, url: url ?? "https://example.com/\(title.lowercased())")
    }

    /// Compact text form of a list, ignoring ids: `A`, `Folder[A,B]`.
    func shape(_ items: [Bookmark]) -> String {
        items.map { item in
            if let children = item.children { return "\(item.title)[\(shape(children))]" }
            return item.title
        }.joined(separator: ",")
    }

    /// Like `shape` but with addresses, for parser tests.
    func detail(_ items: [Bookmark]) -> String {
        items.map { item in
            if let children = item.children { return "\(item.title)[\(detail(children))]" }
            return "\(item.title)=\(item.url ?? "")"
        }.joined(separator: ",")
    }

    // MARK: Editing

    @Test func insertAppendsAndIndexesIntoSectionsAndFolders() {
        let (a, b, c, d) = (mark("A"), mark("B"), mark("C"), mark("D"))
        let folder = Bookmark.folder(title: "F")
        var tree = BookmarkTree()
        tree.insert(a, into: .bar)
        tree.insert(b, into: .bar, at: 0)
        tree.insert(folder, into: .menu)
        tree.insert(c, into: .menu, folder: folder.id)
        tree.insert(d, into: .menu, folder: folder.id, at: 0)
        #expect(shape(tree.bar) == "B,A")
        #expect(shape(tree.menu) == "F[D,C]")
        // Out-of-range index appends; unknown folder and bookmark-as-folder fall back to the root.
        tree.insert(mark("E"), into: .bar, at: 99)
        tree.insert(mark("G"), into: .bar, folder: UUID())
        tree.insert(mark("H"), into: .bar, folder: a.id)
        #expect(shape(tree.bar) == "B,A,E,G,H")
        // A folder id from the other section is unknown here.
        tree.insert(mark("I"), into: .bar, folder: folder.id)
        #expect(shape(tree.bar) == "B,A,E,G,H,I")
    }

    @Test func removeReturnsNodeAndDeepNodes() {
        let inner = mark("Inner")
        let outer = Bookmark.folder(title: "Outer", children: [Bookmark.folder(title: "Mid", children: [inner])])
        var tree = BookmarkTree(bar: [mark("A")], menu: [outer])
        #expect(tree.remove(inner.id) == inner)
        #expect(shape(tree.menu) == "Outer[Mid[]]")
        #expect(tree.remove(UUID()) == nil)
        let removed = tree.remove(outer.id)
        #expect(removed?.title == "Outer")
        #expect(tree.menu.isEmpty)
        #expect(shape(tree.bar) == "A")
    }

    @Test func renameAndSetURL() {
        let a = mark("A")
        let folder = Bookmark.folder(title: "F", children: [a])
        var tree = BookmarkTree(bar: [], menu: [folder])
        tree.rename(a.id, to: "Renamed")
        tree.setURL(a.id, to: "https://new.example/")
        #expect(tree.node(a.id)?.title == "Renamed")
        #expect(tree.node(a.id)?.url == "https://new.example/")
        // Folders can be renamed but have no address to set.
        tree.rename(folder.id, to: "Folder")
        tree.setURL(folder.id, to: "https://nope.example/")
        #expect(tree.node(folder.id)?.title == "Folder")
        #expect(tree.node(folder.id)?.url == nil)
        #expect(tree.node(folder.id)?.isFolder == true)
        // Unknown ids are ignored.
        let before = tree
        tree.rename(UUID(), to: "x")
        tree.setURL(UUID(), to: "x")
        #expect(tree == before)
    }

    @Test func moveWithinSameParentUsesOnMoveSemantics() {
        let items = ["A", "B", "C", "D"].map { mark($0) }
        var tree = BookmarkTree(bar: items)
        tree.move(items[0].id, to: .bar, folder: nil, at: 3)
        #expect(shape(tree.bar) == "B,C,A,D")
        tree.move(items[0].id, to: .bar, folder: nil, at: 0)
        #expect(shape(tree.bar) == "A,B,C,D")
        tree.move(items[0].id, to: .bar, folder: nil, at: 4)
        #expect(shape(tree.bar) == "B,C,D,A")
        tree.move(items[0].id, to: .bar, folder: nil, at: 99)  // clamps
        #expect(shape(tree.bar) == "B,C,D,A")
        tree.move(items[3].id, to: .bar, folder: nil, at: 1)  // D from 2 to slot 1
        #expect(shape(tree.bar) == "B,D,C,A")
        // Dropping onto its own slot, or the one after it, changes nothing.
        let same = tree
        tree.move(items[3].id, to: .bar, folder: nil, at: 1)
        tree.move(items[3].id, to: .bar, folder: nil, at: 2)
        #expect(tree == same)
    }

    @Test func moveAcrossSectionsAndIntoFolders() {
        let (a, b, c) = (mark("A"), mark("B"), mark("C"))
        let folder = Bookmark.folder(title: "F", children: [c])
        var tree = BookmarkTree(bar: [a, b], menu: [folder])
        tree.move(a.id, to: .menu, folder: nil, at: 0)
        #expect(shape(tree.bar) == "B")
        #expect(shape(tree.menu) == "A,F[C]")
        tree.move(b.id, to: .menu, folder: folder.id, at: 0)
        #expect(shape(tree.menu) == "A,F[B,C]")
        #expect(tree.location(of: b.id) == BookmarkTree.Location(section: .menu, folder: folder.id, index: 0))
        // Out of a folder to the root, and within the folder from a before-removal slot.
        tree.move(c.id, to: .menu, folder: folder.id, at: 0)
        #expect(shape(tree.menu) == "A,F[C,B]")
        tree.move(c.id, to: .bar, folder: nil, at: 5)
        #expect(shape(tree.bar) == "C")
        #expect(shape(tree.menu) == "A,F[B]")
        // Unknown destination folder means the section root; unknown id is a no-op.
        tree.move(a.id, to: .bar, folder: UUID(), at: 0)
        #expect(shape(tree.bar) == "A,C")
        let before = tree
        tree.move(UUID(), to: .bar, folder: nil, at: 0)
        #expect(tree == before)
    }

    @Test func moveRefusesFolderIntoItselfOrDescendant() {
        let leaf = mark("Leaf")
        let inner = Bookmark.folder(title: "Inner", children: [leaf])
        let outer = Bookmark.folder(title: "Outer", children: [inner])
        let other = Bookmark.folder(title: "Other")
        var tree = BookmarkTree(bar: [outer, other])
        let before = tree
        tree.move(outer.id, to: .bar, folder: outer.id, at: 0)
        tree.move(outer.id, to: .bar, folder: inner.id, at: 0)
        #expect(tree == before)
        // Moving to a sibling folder, or an inner folder up, is fine.
        tree.move(inner.id, to: .bar, folder: other.id, at: 0)
        #expect(shape(tree.bar) == "Outer[],Other[Inner[Leaf]]")
        tree.move(other.id, to: .menu, folder: nil, at: 0)
        #expect(shape(tree.menu) == "Other[Inner[Leaf]]")
    }

    // MARK: Lookup

    @Test func nodeAndLocationFindNestedItems() {
        let leaf = mark("Leaf")
        let inner = Bookmark.folder(title: "Inner", children: [mark("X"), leaf])
        let outer = Bookmark.folder(title: "Outer", children: [inner])
        let top = mark("Top")
        let tree = BookmarkTree(bar: [top], menu: [outer])
        #expect(tree.node(leaf.id) == leaf)
        #expect(tree.node(outer.id)?.title == "Outer")
        #expect(tree.node(UUID()) == nil)
        #expect(tree.location(of: top.id) == BookmarkTree.Location(section: .bar, folder: nil, index: 0))
        #expect(tree.location(of: outer.id) == BookmarkTree.Location(section: .menu, folder: nil, index: 0))
        #expect(tree.location(of: inner.id) == BookmarkTree.Location(section: .menu, folder: outer.id, index: 0))
        #expect(tree.location(of: leaf.id) == BookmarkTree.Location(section: .menu, folder: inner.id, index: 1))
        #expect(tree.location(of: UUID()) == nil)
    }

    @Test func allBookmarksIsDepthFirstBarThenMenuWithoutFolders() {
        let tree = BookmarkTree(
            bar: [mark("A"), .folder(title: "F1", children: [mark("B"), .folder(title: "F2", children: [mark("C")]), mark("D")]), mark("E")],
            menu: [.folder(title: "F3"), mark("G"), .folder(title: "F4", children: [mark("H")])]
        )
        #expect(tree.allBookmarks.map(\.title) == ["A", "B", "C", "D", "E", "G", "H"])
        #expect(tree.allBookmarks.allSatisfy { !$0.isFolder })
    }

    @Test func bookmarksForURLMatchesExactlyAndSkipsFolders() {
        let one = mark("One", "https://example.com/page")
        let two = mark("Two", "https://example.com/page")
        let near = mark("Near", "https://example.com/page/")
        let tree = BookmarkTree(bar: [one, near], menu: [.folder(title: "https://example.com/page", children: [two])])
        #expect(tree.bookmarks(for: "https://example.com/page").map(\.id) == [one.id, two.id])
        #expect(tree.bookmarks(for: "https://example.com/pag").isEmpty)
    }

    @Test func searchMatchesAllWordsInTitleOrURLIgnoringCase() {
        let swift = mark("Swift Evolution", "https://github.com/apple/swift-evolution")
        let blog = mark("WebKit Blog", "https://webkit.org/blog/")
        let cafe = mark("Café Münster", "https://example.com/karte")
        let tree = BookmarkTree(bar: [swift], menu: [.folder(title: "Swift folder", children: [blog, cafe])])
        #expect(tree.search("swift").map(\.id) == [swift.id])  // folders never match
        #expect(tree.search("EVOLUTION github").map(\.id) == [swift.id])  // words spread over title and URL
        #expect(tree.search("webkit.org BLOG").map(\.id) == [blog.id])
        #expect(tree.search("swift blog").isEmpty)
        #expect(tree.search("MÜNSTER").map(\.id) == [cafe.id])
        #expect(tree.search("café").map(\.id) == [cafe.id])
        #expect(tree.search("").isEmpty)
        #expect(tree.search("   ").isEmpty)
    }

    // MARK: Merge

    @Test func mergeAppendsBarAndWrapsMenuInFolder() {
        var tree = BookmarkTree(bar: [mark("A")], menu: [mark("M")])
        let imported = BookmarkTree(bar: [mark("B"), mark("C")], menu: [mark("D"), .folder(title: "Sub", children: [mark("E")])])
        tree.merge(imported, folderTitle: "Imported from Chrome")
        #expect(shape(tree.bar) == "A,B,C")
        #expect(shape(tree.menu) == "M,Imported from Chrome[D,Sub[E]]")
        // No folder when the import has nothing for the menu.
        var barOnly = BookmarkTree()
        barOnly.merge(BookmarkTree(bar: [mark("Z")]), folderTitle: "Imported")
        #expect(shape(barOnly.bar) == "Z")
        #expect(barOnly.menu.isEmpty)
    }

    @Test func mergeSkipsDuplicatesAndDropsEmptiedFolders() {
        let existing = BookmarkTree(bar: [mark("A", "https://a.example/")], menu: [.folder(title: "F", children: [mark("B", "https://b.example/")])])
        var tree = existing
        let imported = BookmarkTree(
            bar: [mark("A again", "https://a.example/"), mark("New", "https://new.example/")],
            menu: [
                .folder(title: "Dupes only", children: [.folder(title: "Deep", children: [mark("B2", "https://b.example/")])]),
                .folder(title: "Mixed", children: [mark("B3", "https://b.example/"), mark("C", "https://c.example/")]),
                .folder(title: "Already empty"),
                mark("A3", "https://a.example/"),
            ]
        )
        tree.merge(imported, folderTitle: "Imp")
        #expect(shape(tree.bar) == "A,New")
        #expect(shape(tree.menu) == "F[B],Imp[Mixed[C]]")
        // Merging again adds nothing: no bookmarks, no empty folders, no second wrapper.
        var again = tree
        again.merge(imported, folderTitle: "Imp")
        #expect(again == tree)
    }

    // MARK: Persistence

    @Test func decodeDefaultsMissingKeysAndRoundTrips() throws {
        let empty = try BookmarkTree.decode(Data("{}".utf8))
        #expect(empty == BookmarkTree())
        let barOnly = try BookmarkTree.decode(Data("""
        {"bar":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"A","url":"https://a.example/"}]}
        """.utf8))
        #expect(barOnly.bar.count == 1)
        #expect(barOnly.bar.first?.children == nil)
        #expect(barOnly.menu.isEmpty)

        let tree = BookmarkTree(
            bar: [mark("A")],
            menu: [.folder(title: "F", children: [mark("B"), .folder(title: "Empty")])]
        )
        let data = try tree.encoded()
        #expect(try BookmarkTree.decode(data) == tree)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"))  // pretty-printed
        #expect(try tree.encoded() == data)  // sorted keys: stable output
        #expect(throws: (any Error).self) { try BookmarkTree.decode(Data("not json".utf8)) }
    }

    // MARK: Netscape import

    @Test func parsesSafariExport() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!--This is an automatically generated file.
        It will be read and overwritten.
        Do Not Edit! -->
        <Title>Bookmarks</Title>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 FOLDED ADD_DATE="1700000000">Favorites</H3>
            <DL><p>
                <DT><A HREF="https://www.apple.com/" ADD_DATE="1700000001">Apple</A>
                <DT><A HREF="https://news.ycombinator.com/">Hacker News</A>
            </DL><p>
            <DT><H3 FOLDED>Reading</H3>
            <DL><p>
                <DT><A HREF="https://example.com/read?a=1&amp;b=2">Read &amp; Learn</A>
                <DT><H3 FOLDED>Deep</H3>
                <DL><p>
                    <DT><A HREF="https://deep.example/">Deep page</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="https://top.example/">Top level</A>
        </DL><p>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "Apple=https://www.apple.com/,Hacker News=https://news.ycombinator.com/")
        #expect(detail(tree.menu) == "Reading[Read & Learn=https://example.com/read?a=1&b=2,Deep[Deep page=https://deep.example/]],Top level=https://top.example/")
    }

    @Test func parsesFirefoxExport() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'none'; img-src data: *; object-src 'none'"></meta>
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks Menu</H1>

        <DL><p>
            <DT><H3 ADD_DATE="1600000000" LAST_MODIFIED="1600000001">Mozilla Firefox</H3>
            <DL><p>
                <DT><A HREF="https://support.mozilla.org/products/firefox" ADD_DATE="1600000002" ICON="data:image/png;base64,iVBORw0KGgo=">Help and Tutorials</A>
                <DT><A HREF='https://www.mozilla.org/about/' ICON_URI='fake-favicon-uri:https://www.mozilla.org/about/'>About &#39;Us&#39;</A>
            </DL><p>
            <DT><H3 ADD_DATE="1600000003" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
            <DD>Add bookmarks to this folder to see them displayed on the Bookmarks Toolbar
            <DL><p>
                <DT><A HREF="https://bar.example/?q=a&amp;r=b">Bar &lt;one&gt;</A>
                <DT><A HREF="place:parent=1234&amp;type=6&amp;sort=14">Recent Tags</A>
                <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
                <DT><A HREF="about:config">Config</A>
                <DT><A HREF="">Nothing</A>
                <DT><A HREF="data:text/html,hi">Data</A>
                <DT><H3>Nested</H3>
                <DL><p>
                    <DT><A HREF="https://nested.example/">&#x41;&#66;C &quot;quoted&quot; &apos;x&apos; &unknown; &</A>
                </DL><p>
            </DL><p>
            <DT><H3>Other Bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://other.example/">Other</A>
            </DL><p>
        </DL>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "Bar <one>=https://bar.example/?q=a&r=b,Nested[ABC \"quoted\" 'x' &unknown; &=https://nested.example/]")
        #expect(detail(tree.menu) == "Mozilla Firefox[Help and Tutorials=https://support.mozilla.org/products/firefox,About 'Us'=https://www.mozilla.org/about/],Other Bookmarks[Other=https://other.example/]")
    }

    @Test func parsesChromeExport() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1650000000" LAST_MODIFIED="1650000001" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://github.com/" ADD_DATE="1650000002" ICON="data:image/png;base64,AAAA">GitHub</A>
                <DT><H3 ADD_DATE="1650000003" LAST_MODIFIED="1650000004">Work</H3>
                <DL><p>
                    <DT><A HREF="https://work.example/" ADD_DATE="1650000005">Work site</A>
                </DL><p>
            </DL><p>
            <DT><H3 ADD_DATE="1650000006" LAST_MODIFIED="1650000007">Other bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://later.example/" ADD_DATE="1650000008">Later</A>
            </DL><p>
        </DL><p>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "GitHub=https://github.com/,Work[Work site=https://work.example/]")
        #expect(detail(tree.menu) == "Other bookmarks[Later=https://later.example/]")
    }

    @Test func parsesLowercaseTagsAndBareBarTitle() {
        // No <p> tags, lowercase names, a "Favourites Bar" folder recognised by title alone, </DT> present.
        let html = """
        <dl>
          <dt><h3>  favourites BAR </h3></dt>
          <dl>
            <dt><a href = "https://one.example/" >One</a></dt>
          </dl>
          <dt><a href=https://two.example/ class=x>Two</a></dt>
        </dl>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "One=https://one.example/")
        #expect(detail(tree.menu) == "Two=https://two.example/")
        // Only top-level folders count as the bar.
        let nested = NetscapeBookmarks.parse("<DL><DT><H3>Stuff</H3><DL><DT><H3>Favorites</H3><DL><DT><A HREF=\"https://x.example/\">X</A></DL></DL></DL>")
        #expect(nested.bar.isEmpty)
        #expect(detail(nested.menu) == "Stuff[Favorites[X=https://x.example/]]")
    }

    @Test func malformedInputDoesNotCrash() {
        // No closing tags at all.
        let open = NetscapeBookmarks.parse("""
        <DL><p>
        <DT><H3>Folder
        <DL><p>
        <DT><A HREF="https://a.example/">Unclosed link
        <DT><A HREF="https://b.example/">Second
        """)
        #expect(detail(open.menu) == "Folder[Unclosed link=https://a.example/,Second=https://b.example/]")

        // Heading with no list, stray closers, truncated tags and attributes, odd bytes.
        let stray = NetscapeBookmarks.parse("</DL></DL><DL><DT><H3>Empty</H3><DT><A HREF=\"https://c.example/\">C</A></DL></DL>")
        #expect(detail(stray.menu) == "Empty[],C=https://c.example/")

        let junk = [
            "", "<", "<<<>>>", "<A", "<A HREF", "<A HREF=", "<A HREF=\"", "<A HREF=\"https://x.example/\"",
            "<DT><A HREF=\"https://x.example/\">Title</", "<!--", "<!-- unterminated", "<!DOCTYPE", "&", "&#;", "&#xZZ;", "&#1114112;",
            "<A =>x</A>", "<DL><H3 ==\"\" 'x'>t</H3>", "\u{0}\u{1}<A HREF=\"https://y.example/\">\u{FFFD}</A>",
        ]
        for text in junk { _ = NetscapeBookmarks.parse(text) }
        #expect(NetscapeBookmarks.parse("").allBookmarks.isEmpty)
        #expect(NetscapeBookmarks.parse("<A HREF=\"https://x.example/\"").allBookmarks.map(\.url) == ["https://x.example/"])
    }

    // MARK: Netscape export

    @Test func exportRoundTripsNastyCharacters() {
        let tree = BookmarkTree(
            bar: [
                Bookmark(title: "Tom & Jerry <\"fun\"> 'times'", url: "https://example.com/?a=1&b=<2>&c=\"3\""),
                .folder(title: "R&D \"labs\" <x>", children: [Bookmark(title: "Ünïcode 日本語 🎌", url: "https://example.com/日本語?x=&amp;y")]),
                .folder(title: "Empty folder"),
            ],
            menu: [
                .folder(title: "Menu >folder<", children: [.folder(title: "Deeper", children: [Bookmark(title: "&lt;already&gt;", url: "https://deep.example/#frag")])]),
                Bookmark(title: "Plain", url: "https://plain.example/"),
            ]
        )
        let html = NetscapeBookmarks.export(tree)
        #expect(html.contains("PERSONAL_TOOLBAR_FOLDER=\"true\""))
        #expect(html.contains("Bookmarks Bar"))
        #expect(!html.contains("<\"fun\">"))  // escaped in the file
        let parsed = NetscapeBookmarks.parse(html)
        #expect(detail(parsed.bar) == detail(tree.bar))
        #expect(detail(parsed.menu) == detail(tree.menu))
    }

    @Test func exportOmitsEmptyBarAndHandlesEmptyTree() {
        let empty = NetscapeBookmarks.export(BookmarkTree())
        #expect(!empty.contains("PERSONAL_TOOLBAR_FOLDER"))
        #expect(NetscapeBookmarks.parse(empty) == BookmarkTree())
        let menuOnly = BookmarkTree(menu: [mark("A")])
        let parsed = NetscapeBookmarks.parse(NetscapeBookmarks.export(menuOnly))
        #expect(detail(parsed.menu) == detail(menuOnly.menu))
        #expect(parsed.bar.isEmpty)
    }

    // MARK: Lenient decode

    @Test func decodeIsLenientAboutIDAndTitle() throws {
        let news = try BookmarkTree.decode(Data(#"{"bar":[{"title":"News","url":"https://n.example/"}]}"#.utf8))
        #expect(news.bar.count == 1)
        #expect(news.bar[0].title == "News")

        let bare = try BookmarkTree.decode(Data(#"{"menu":[{"url":"https://u.example/"}]}"#.utf8))
        #expect(bare.menu[0].title == "https://u.example/")
        #expect(bare.menu[0].children == nil)

        let id = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
        let work = try BookmarkTree.decode(Data(#"{"bar":[{"id":"\#(id)","title":"Work"}]}"#.utf8))
        #expect(work.bar[0].isFolder)
        #expect(work.bar[0].children == [])
        #expect(work.bar[0].id.uuidString == id)
        let untitledFolder = try BookmarkTree.decode(Data(#"{"bar":[{"children":[]}]}"#.utf8))
        #expect(untitledFolder.bar[0].title == "")

        // Encoding is unchanged: same keys, nothing extra.
        let text = String(decoding: try news.encoded(), as: UTF8.self)
        #expect(text.contains("\"title\""))
        #expect(!text.contains("children"))
    }

    @Test func decodeMakesDuplicateIDsUnique() throws {
        let id = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
        let json = """
        {"bar":[{"id":"\(id)","title":"First","url":"https://1.example/"},
                {"id":"\(id)","title":"Second","url":"https://2.example/"}],
         "menu":[{"id":"\(id)","title":"F","children":[{"id":"\(id)","title":"Deep","url":"https://3.example/"}]}]}
        """
        let tree = try BookmarkTree.decode(Data(json.utf8))
        #expect(tree.bar[0].id.uuidString == id)
        let ids = [tree.bar[0].id, tree.bar[1].id, tree.menu[0].id, tree.menu[0].children![0].id]
        #expect(Set(ids).count == 4)
        #expect(tree.node(tree.menu[0].children![0].id)?.title == "Deep")
    }

    @Test func moveIntoFolderWithNilChildrenKeepsTheNode() {
        var broken = Bookmark.folder(title: "Broken")
        broken.children = nil
        let a = mark("A")
        var tree = BookmarkTree(bar: [a], menu: [broken])
        tree.move(a.id, to: .menu, folder: broken.id, at: 0)
        #expect(tree.bar.isEmpty)
        #expect(shape(tree.menu) == "Broken[A]")
        #expect(tree.allBookmarks.count == 1)
        tree.insert(mark("B"), into: .menu, folder: broken.id)
        #expect(shape(tree.menu) == "Broken[A,B]")
    }

    @Test func mergeIsIdempotentAndSkipsEmptyFolders() {
        let imported = BookmarkTree(menu: [.folder(title: "Other Bookmarks"), mark("Only", "https://only.example/")])
        var tree = BookmarkTree()
        tree.merge(imported, folderTitle: "Imported")
        #expect(shape(tree.menu) == "Imported[Only]")
        let once = tree
        tree.merge(imported, folderTitle: "Imported")
        #expect(tree == once)

        // Nothing but empty folders: no wrapper at all.
        var none = BookmarkTree()
        none.merge(BookmarkTree(bar: [.folder(title: "E1")], menu: [.folder(title: "E2")]), folderTitle: "Imported")
        #expect(none == BookmarkTree())
    }

    @Test func mergeSkipsRepeatsWithinOneImport() {
        let imported = BookmarkTree(
            bar: [mark("Bar copy", "https://x.example/")],
            menu: [.folder(title: "F", children: [mark("Menu copy", "https://x.example/"), mark("Y", "https://y.example/"), mark("Y2", "https://y.example/")])]
        )
        var tree = BookmarkTree()
        tree.merge(imported, folderTitle: "Imp")
        #expect(shape(tree.bar) == "Bar copy")
        #expect(shape(tree.menu) == "Imp[F[Y]]")
        #expect(tree.allBookmarks.count == 2)
    }

    @Test func flaggedFolderIsTheOnlyBar() {
        let html = """
        <DL><p>
        <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3>
        <DL><p><DT><A HREF="https://r.example/">r</A></DL><p>
        <DT><H3>Favorites</H3>
        <DL><p><DT><A HREF="https://f.example/">f</A></DL><p>
        </DL><p>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "r=https://r.example/")
        #expect(detail(tree.menu) == "Favorites[f=https://f.example/]")
    }

    @Test func onlyFirstTitleMatchedFolderIsTheBarWithoutAFlag() {
        let html = """
        <DL><p>
        <DT><H3>Favorites</H3><DL><p><DT><A HREF="https://a.example/">a</A></DL><p>
        <DT><H3>Bookmarks Bar</H3><DL><p><DT><A HREF="https://b.example/">b</A></DL><p>
        </DL><p>
        """
        let tree = NetscapeBookmarks.parse(html)
        #expect(detail(tree.bar) == "a=https://a.example/")
        #expect(detail(tree.menu) == "Bookmarks Bar[b=https://b.example/]")
    }

    private func depth(_ items: [Bookmark]) -> Int {
        1 + (items.map { depth($0.children ?? []) }.max() ?? 0) - (items.isEmpty ? 1 : 0)
    }

    @Test func deeplyNestedImportIsCappedAndStillMergesAndEncodes() throws {
        let html = String(repeating: "<DT><H3>a</H3><DL><p>", count: 20_000)
        let tree = NetscapeBookmarks.parse(html)
        #expect(depth(tree.menu) <= 32)
        #expect(depth(tree.menu) > 1)
        var target = BookmarkTree()
        target.merge(tree, folderTitle: "Imp")
        _ = try target.encoded()

        // Overflowing lists keep the closing tags balanced: items after them land in the right folder.
        let deep = String(repeating: "<DT><H3>a</H3><DL><p>", count: 40)
            + "<DT><A HREF=\"https://deep.example/\">deep</A>"
            + String(repeating: "</DL><p>", count: 40)
            + "<DT><A HREF=\"https://top.example/\">top</A>"
        let parsed = NetscapeBookmarks.parse(deep)
        #expect(parsed.menu.last?.url == "https://top.example/")
        #expect(depth(parsed.menu) <= 32)
        #expect(parsed.allBookmarks.count == 2)
    }

    @Test func importIgnoresNodesBeyondTheCap() {
        let html = "<DL>" + String(repeating: "<DT><A HREF=\"https://x.example/\">x</A>", count: 100_050) + "</DL>"
        let tree = NetscapeBookmarks.parse(html)
        #expect(tree.menu.count == 100_000)
    }

    @Test func numericReferencesToControlCharactersBecomeReplacement() {
        #expect(NetscapeBookmarks.decodeEntities("a&#0;b&#1;c&#x1F;d&#127;e") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e")
        #expect(NetscapeBookmarks.decodeEntities("a&#9;b&#10;c&#13;d&#65;") == "a\tb\nc\rdA")
    }

    @Test func matchKeyNormalizesForComparisonOnly() {
        let tree = BookmarkTree(bar: [mark("Plain", "https://example.com/"), mark("Page", "https://a.example/p"), mark("Inbox", "https://a.example/#/inbox")])
        #expect(tree.bookmarks(for: "https://Example.com").map(\.title) == ["Plain"])
        #expect(tree.bookmarks(for: "https://a.example/p#section").map(\.title) == ["Page"])
        #expect(tree.bookmarks(for: "https://a.example/#/inbox").map(\.title) == ["Inbox"])
        #expect(tree.bookmarks(for: "https://a.example/#/sent").isEmpty)
        #expect(BookmarkTree.matchKey("HTTPS://A.Example") == "https://a.example/")
        #expect(BookmarkTree.matchKey("https://a.example/#!/x") == "https://a.example/#!/x")
        #expect(BookmarkTree.matchKey("https://a.example/Path?Q=1#frag") == "https://a.example/Path?Q=1")
        // Stored strings are not rewritten.
        #expect(tree.bar[0].url == "https://example.com/")
    }
}
