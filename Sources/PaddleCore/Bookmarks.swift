import Foundation

/// One entry in the bookmark tree: either a bookmark (`url` set, `children` nil) or a folder (`url` nil,
/// `children` set, possibly empty).
public struct Bookmark: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// The page address; nil for folders.
    public var url: String?
    /// The folder's contents; nil for bookmarks.
    public var children: [Bookmark]?
    public var isFolder: Bool { url == nil }

    public init(id: UUID = UUID(), title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
        self.children = nil
    }

    private init(id: UUID, title: String, children: [Bookmark]) {
        self.id = id
        self.title = title
        self.url = nil
        self.children = children
    }

    public static func folder(id: UUID = UUID(), title: String, children: [Bookmark] = []) -> Bookmark {
        Bookmark(id: id, title: title, children: children)
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, children }

    /// Lenient, for hand-written files: a missing `id` becomes a fresh one, a missing `title` the address (empty
    /// for folders), and a node with no `url` is a folder whose missing `children` are empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decodeIfPresent(String.self, forKey: .url)
        let decodedChildren = try container.decodeIfPresent([Bookmark].self, forKey: .children)
        children = url == nil ? (decodedChildren ?? []) : decodedChildren
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? url ?? ""
    }
}

/// All bookmarks, in two top-level sections (the Bookmarks Bar under the toolbar and the Bookmarks Menu),
/// each an ordered list of bookmarks and nested folders. Pure value type: the app owns the persistence.
public struct BookmarkTree: Codable, Sendable, Equatable {
    public enum Section: String, Codable, Sendable, CaseIterable {
        case bar
        case menu
    }

    /// Where a node sits: its section, the folder holding it (nil for the section root) and its index there.
    public struct Location: Equatable, Sendable {
        public var section: Section
        public var folder: UUID?
        public var index: Int

        public init(section: Section, folder: UUID?, index: Int) {
            self.section = section
            self.folder = folder
            self.index = index
        }
    }

    public var bar: [Bookmark]
    public var menu: [Bookmark]

    public init(bar: [Bookmark] = [], menu: [Bookmark] = []) {
        self.bar = bar
        self.menu = menu
    }

    private enum CodingKeys: String, CodingKey { case bar, menu }

    /// Missing keys decode as empty sections, so a hand-edited or older file still loads. A node whose id was
    /// already seen (bar before menu, depth first) gets a fresh one, so ids are unique.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bar = try container.decodeIfPresent([Bookmark].self, forKey: .bar) ?? []
        menu = try container.decodeIfPresent([Bookmark].self, forKey: .menu) ?? []
        var seen: Set<UUID> = []
        bar.makeIDsUnique(&seen)
        menu.makeIDsUnique(&seen)
    }

    // MARK: Lookup

    public func node(_ id: UUID) -> Bookmark? {
        bar.find(id) ?? menu.find(id)
    }

    public func location(of id: UUID) -> Location? {
        for section in Section.allCases {
            if let found = root(section).locate(id, parent: nil) {
                return Location(section: section, folder: found.parent, index: found.index)
            }
        }
        return nil
    }

    /// Bookmarks whose address equals `url` after `matchKey` normalization. Folders never match.
    public func bookmarks(for url: String) -> [Bookmark] {
        let key = Self.matchKey(url)
        return allBookmarks.filter { $0.url.map(Self.matchKey) == key }
    }

    /// Form of an address used only to compare it with others (stored strings are never rewritten): scheme and
    /// host lowercased, an empty path becomes "/", and the fragment dropped unless it starts with "/" or "!"
    /// (hash-routed apps such as `#/inbox` or `#!/x`). Text that does not parse as a URL is returned unchanged.
    public static func matchKey(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.scheme = components.scheme?.lowercased()
        if components.percentEncodedHost != nil {
            components.percentEncodedHost = components.percentEncodedHost?.lowercased()
            if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        }
        if let fragment = components.percentEncodedFragment, !(fragment.hasPrefix("/") || fragment.hasPrefix("!")) {
            components.fragment = nil
        }
        return components.string ?? url
    }

    /// Every bookmark, depth first, bar before menu. Folders are not included, only their contents.
    public var allBookmarks: [Bookmark] {
        bar.leaves + menu.leaves
    }

    /// Bookmarks where every whitespace-separated word of `query` appears in the title or the address,
    /// ignoring case (also for non-ASCII letters). An empty query matches nothing.
    public func search(_ query: String) -> [Bookmark] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return allBookmarks.filter { bookmark in
            let title = bookmark.title.lowercased()
            let url = (bookmark.url ?? "").lowercased()
            return words.allSatisfy { title.contains($0) || url.contains($0) }
        }
    }

    // MARK: Editing

    /// Adds `node` to a section root or to a folder in that section, at `index` (nil or out of range appends).
    /// An unknown folder id, or one that names a bookmark, falls back to the section root.
    public mutating func insert(_ node: Bookmark, into section: Section, folder: UUID? = nil, at index: Int? = nil) {
        place(node, into: section, folder: folder, at: index)
    }

    /// `insert`, reporting whether the node ended up in the tree.
    @discardableResult
    private mutating func place(_ node: Bookmark, into section: Section, folder: UUID?, at index: Int?) -> Bool {
        let target = folder.flatMap { root(section).find($0)?.isFolder == true ? $0 : nil }
        return withRoot(section) { items in
            guard let target else {
                items.insert(node, at: Self.clamp(index, count: items.count))
                return true
            }
            return items.insertNode(node, intoFolder: target, at: index)
        }
    }

    /// Removes a bookmark or folder (with everything in it) and returns it, or nil if `id` is unknown.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bookmark? {
        if let removed = bar.removeNode(id) { return removed }
        return menu.removeNode(id)
    }

    public mutating func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    /// Changes a bookmark's address. Does nothing for folders.
    public mutating func setURL(_ id: UUID, to url: String) {
        update(id) { if !$0.isFolder { $0.url = url } }
    }

    /// Moves a node to slot `index` of a section root or folder.
    ///
    /// `index` counts slots in the destination as it looks before the move, like SwiftUI's `onMove`: moving
    /// from 0 to 3 within one parent lands at 2. It is clamped to the destination. Moving a folder into itself
    /// or one of its descendants does nothing, and an unknown or non-folder destination means the section root.
    public mutating func move(_ id: UUID, to section: Section, folder: UUID?, at index: Int) {
        guard let node = node(id), let from = location(of: id) else { return }
        var destination = folder
        if let folder {
            if [node].find(folder) != nil { return }
            if root(section).find(folder)?.isFolder != true { destination = nil }
        }
        let count = destination.map { root(section).find($0)?.children?.count ?? 0 } ?? root(section).count
        var slot = max(0, min(index, count))
        if from.section == section, from.folder == destination, from.index < slot { slot -= 1 }
        remove(id)
        if !place(node, into: section, folder: destination, at: slot) {
            place(node, into: from.section, folder: from.folder, at: from.index)  // never lose the node
        }
    }

    /// Imports another tree: its bar items are appended to the bar, its menu items go into one new folder
    /// titled `folderTitle` appended to the menu (no folder if there are none). Bookmarks whose address is
    /// already anywhere in this tree, or earlier in the import, are skipped; folders left with no bookmarks
    /// (including ones that were empty in the import) are dropped.
    public mutating func merge(_ imported: BookmarkTree, folderTitle: String) {
        var known = Set(allBookmarks.compactMap { $0.url.map(Self.matchKey) })
        bar.append(contentsOf: imported.bar.accepting(into: &known))
        let menuItems = imported.menu.accepting(into: &known)
        if !menuItems.isEmpty {
            menu.append(.folder(title: folderTitle, children: menuItems))
        }
    }

    // MARK: Persistence

    public static func decode(_ data: Data) throws -> BookmarkTree {
        try JSONDecoder().decode(BookmarkTree.self, from: data)
    }

    /// Pretty-printed JSON with sorted keys, so the file diffs and hand-edits well.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Helpers

    private func root(_ section: Section) -> [Bookmark] {
        switch section {
        case .bar: bar
        case .menu: menu
        }
    }

    private mutating func withRoot<T>(_ section: Section, _ body: (inout [Bookmark]) -> T) -> T {
        switch section {
        case .bar: body(&bar)
        case .menu: body(&menu)
        }
    }

    private mutating func update(_ id: UUID, _ body: (inout Bookmark) -> Void) {
        if bar.update(id, body) { return }
        _ = menu.update(id, body)
    }

    fileprivate static func clamp(_ index: Int?, count: Int) -> Int {
        index.map { max(0, min($0, count)) } ?? count
    }
}

// MARK: - Recursive list helpers

private extension Array where Element == Bookmark {
    func find(_ id: UUID) -> Bookmark? {
        for item in self {
            if item.id == id { return item }
            if let hit = item.children?.find(id) { return hit }
        }
        return nil
    }

    func locate(_ id: UUID, parent: UUID?) -> (parent: UUID?, index: Int)? {
        for (index, item) in enumerated() {
            if item.id == id { return (parent, index) }
            if let hit = item.children?.locate(id, parent: item.id) { return hit }
        }
        return nil
    }

    /// Bookmarks only, depth first.
    var leaves: [Bookmark] {
        flatMap { $0.isFolder ? ($0.children ?? []).leaves : [$0] }
    }

    mutating func removeNode(_ id: UUID) -> Bookmark? {
        if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
        for index in indices {
            guard var children = self[index].children else { continue }
            if let removed = children.removeNode(id) {
                self[index].children = children
                return removed
            }
        }
        return nil
    }

    mutating func insertNode(_ node: Bookmark, intoFolder folder: UUID, at index: Int?) -> Bool {
        for position in indices {
            if self[position].id == folder, self[position].isFolder {
                var children = self[position].children ?? []
                children.insert(node, at: BookmarkTree.clamp(index, count: children.count))
                self[position].children = children
                return true
            }
            guard var children = self[position].children else { continue }
            if children.insertNode(node, intoFolder: folder, at: index) {
                self[position].children = children
                return true
            }
        }
        return false
    }

    mutating func update(_ id: UUID, _ body: (inout Bookmark) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                body(&self[index])
                return true
            }
            guard var children = self[index].children else { continue }
            if children.update(id, body) {
                self[index].children = children
                return true
            }
        }
        return false
    }

    /// Copy keeping each bookmark whose `matchKey` is not yet in `known` (adding it, so a repeat later in the list
    /// is skipped too). Folders left with no bookmarks, including ones that started empty, are dropped.
    func accepting(into known: inout Set<String>) -> [Bookmark] {
        var result: [Bookmark] = []
        for item in self {
            if let url = item.url {
                if known.insert(BookmarkTree.matchKey(url)).inserted { result.append(item) }
                continue
            }
            let kept = (item.children ?? []).accepting(into: &known)
            if kept.isEmpty { continue }
            var copy = item
            copy.children = kept
            result.append(copy)
        }
        return result
    }

    /// Gives a fresh id to every node whose id is already in `seen`, then records the ids; depth first.
    mutating func makeIDsUnique(_ seen: inout Set<UUID>) {
        for index in indices {
            if !seen.insert(self[index].id).inserted {
                let fresh = UUID()
                self[index].id = fresh
                seen.insert(fresh)
            }
            if var children = self[index].children {
                children.makeIDsUnique(&seen)
                self[index].children = children
            }
        }
    }
}

// MARK: - Netscape bookmark files

/// Reads and writes the "Netscape bookmark file" HTML that Safari, Firefox and Chrome export and import.
public enum NetscapeBookmarks {
    private static let barTitles: Set<String> = [
        "favorites", "favourites", "bookmarks bar", "bookmarks toolbar", "favorites bar", "favourites bar",
    ]
    static let skippedSchemes = ["javascript:", "place:", "about:", "data:"]

    /// Parses the bookmark HTML Safari, Firefox and Chrome export.
    ///
    /// A top-level folder marked `PERSONAL_TOOLBAR_FOLDER="true"` or titled like a bookmarks bar becomes the
    /// bar's contents; everything else at the top level goes to the menu. Never fails: damaged input yields
    /// whatever could be read.
    public static func parse(_ html: String) -> BookmarkTree {
        var builder = Builder()
        let tokens = tokenize(html)
        var position = 0
        while position < tokens.count {
            let token = tokens[position]
            position += 1
            switch token {
            case .text:
                break
            case let .close(name):
                if name == "dl" { builder.closeList() }
            case let .open(name, attributes):
                switch name {
                case "h3":
                    let title = collectTitle(tokens, &position, closing: "h3")
                    builder.beginFolder(title: title, isToolbar: attributes["personal_toolbar_folder"]?.lowercased() == "true")
                case "a":
                    let title = collectTitle(tokens, &position, closing: "a")
                    builder.addBookmark(title: title, href: attributes["href"])
                case "dl":
                    builder.openList()
                default:
                    break
                }
            }
        }
        return builder.finish()
    }

    /// Writes a file those browsers import; the bar becomes a PERSONAL_TOOLBAR_FOLDER="true" folder titled
    /// "Bookmarks Bar". An empty bar is left out.
    public static func export(_ tree: BookmarkTree) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        if !tree.bar.isEmpty {
            out += "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks Bar</H3>\n"
            writeList(tree.bar, depth: 1, into: &out)
        }
        writeItems(tree.menu, depth: 1, into: &out)
        out += "</DL><p>\n"
        return out
    }

    // MARK: Export helpers

    private static func writeList(_ items: [Bookmark], depth: Int, into out: inout String) {
        let indent = String(repeating: "    ", count: depth)
        out += "\(indent)<DL><p>\n"
        writeItems(items, depth: depth + 1, into: &out)
        out += "\(indent)</DL><p>\n"
    }

    private static func writeItems(_ items: [Bookmark], depth: Int, into out: inout String) {
        let indent = String(repeating: "    ", count: depth)
        for item in items {
            if let url = item.url {
                out += "\(indent)<DT><A HREF=\"\(escape(url))\">\(escape(item.title))</A>\n"
            } else {
                out += "\(indent)<DT><H3>\(escape(item.title))</H3>\n"
                writeList(item.children ?? [], depth: depth, into: &out)
            }
        }
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Parse state

    /// Assembles the folder structure from the stream of folder headings, bookmarks and list open/close tags.
    private struct Builder {
        struct Heading {
            var title: String
            var isToolbar: Bool
        }

        struct Frame {
            var items: [Bookmark] = []
            /// The folder this list belongs to; nil for lists with no heading (the outer one).
            var heading: Heading?
        }

        /// Folders nest at most this deep; a deeper list is read into the folder at the limit.
        static let maxDepth = 32
        /// Bookmarks and folders read before the rest of the file is ignored.
        static let maxNodes = 100_000

        var frames = [Frame()]
        /// A folder heading seen but not yet followed by its list.
        var pending: Heading?
        var toolbarIDs: Set<UUID> = []
        /// Open lists past `maxDepth` that did not get a frame; their closing tags are swallowed.
        var overflow = 0
        var nodeCount = 0

        mutating func beginFolder(title: String, isToolbar: Bool) {
            flushPending()
            pending = Heading(title: title, isToolbar: isToolbar)
        }

        mutating func addBookmark(title: String, href: String?) {
            flushPending()
            guard let href else { return }
            let url = href.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = url.lowercased()
            guard !url.isEmpty, !NetscapeBookmarks.skippedSchemes.contains(where: lowered.hasPrefix) else { return }
            guard nodeCount < Builder.maxNodes else { return }
            nodeCount += 1
            frames[frames.count - 1].items.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        }

        mutating func openList() {
            if frames.count >= Builder.maxDepth {
                pending = nil  // too deep: the heading is dropped and the items join the current folder
                overflow += 1
                return
            }
            frames.append(Frame(heading: pending))
            pending = nil
        }

        mutating func closeList() {
            flushPending()
            if overflow > 0 {
                overflow -= 1
                return
            }
            guard frames.count > 1 else { return }
            popFrame()
        }

        mutating func finish() -> BookmarkTree {
            flushPending()
            while frames.count > 1 { popFrame() }
            let items = frames[0].items
            // A flagged folder is the bar and nothing else is; without one, the first folder titled like a bar is.
            let hasFlagged = items.contains { $0.isFolder && toolbarIDs.contains($0.id) }
            let titled = hasFlagged ? nil : items.first { $0.isFolder && NetscapeBookmarks.barTitles.contains($0.title.lowercased()) }?.id
            var tree = BookmarkTree()
            for item in items {
                let isBar = hasFlagged ? toolbarIDs.contains(item.id) : item.id == titled
                if item.isFolder, isBar {
                    tree.bar.append(contentsOf: item.children ?? [])
                } else {
                    tree.menu.append(item)
                }
            }
            return tree
        }

        /// A heading with no list after it is an empty folder.
        private mutating func flushPending() {
            guard let heading = pending else { return }
            pending = nil
            appendFolder(heading, children: [])
        }

        /// Closes the innermost list: it becomes a folder in its parent, or is merged into it if it had no heading.
        private mutating func popFrame() {
            let frame = frames.removeLast()
            if let heading = frame.heading {
                appendFolder(heading, children: frame.items)
            } else {
                frames[frames.count - 1].items.append(contentsOf: frame.items)
            }
        }

        private mutating func appendFolder(_ heading: Heading, children: [Bookmark]) {
            guard nodeCount < Builder.maxNodes || !children.isEmpty else { return }
            nodeCount += 1
            let folder = Bookmark.folder(title: heading.title.trimmingCharacters(in: .whitespacesAndNewlines), children: children)
            if heading.isToolbar { toolbarIDs.insert(folder.id) }
            frames[frames.count - 1].items.append(folder)
        }
    }

    // MARK: Tokenizer

    private enum Token {
        case open(String, [String: String])
        case close(String)
        case text(String)
    }

    /// Text of a heading or link: everything up to its closing tag. Stops early, without consuming, at a tag
    /// that starts new structure, so a missing `</A>` does not swallow the rest of the file.
    private static func collectTitle(_ tokens: [Token], _ position: inout Int, closing: String) -> String {
        var title = ""
        while position < tokens.count {
            switch tokens[position] {
            case let .text(text):
                title += text
            case let .close(name):
                if name == closing {
                    position += 1
                    return title.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if name == "dl" || name == "dt" { return title.trimmingCharacters(in: .whitespacesAndNewlines) }
            case let .open(name, _):
                if ["a", "h3", "dl", "dt"].contains(name) { return title.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            position += 1
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits HTML into tags and text. Tag and attribute names are lowercased, attribute values and text have
    /// entities decoded. Comments and `<!...>` declarations are dropped; an unterminated tag ends the input.
    private static func tokenize(_ html: String) -> [Token] {
        let bytes = Array(html.utf8)
        var tokens: [Token] = []
        var i = 0
        var textStart = 0

        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
        func isLetter(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func flushText(upTo end: Int) {
            if end > textStart { tokens.append(.text(decodeEntities(string(textStart..<end)))) }
        }
        func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.utf8)
            return index + p.count <= bytes.count && Array(bytes[index..<index + p.count]) == p
        }

        while i < bytes.count {
            guard bytes[i] == 0x3C, i + 1 < bytes.count else {
                i += 1
                continue
            }
            let next = bytes[i + 1]
            if next == 0x21 {
                // Comment or declaration.
                flushText(upTo: i)
                if hasPrefix("<!--", at: i) {
                    var j = i + 4
                    while j < bytes.count, !hasPrefix("-->", at: j) { j += 1 }
                    i = min(j + 3, bytes.count)
                } else {
                    while i < bytes.count, bytes[i] != 0x3E { i += 1 }
                    i = min(i + 1, bytes.count)
                }
                textStart = i
                continue
            }
            let isClosing = next == 0x2F
            let nameStart = isClosing ? i + 2 : i + 1
            guard nameStart < bytes.count, isLetter(bytes[nameStart]) else {
                i += 1  // a stray "<" is just text
                continue
            }
            flushText(upTo: i)
            var j = nameStart
            while j < bytes.count, !isSpace(bytes[j]), bytes[j] != 0x2F, bytes[j] != 0x3E { j += 1 }
            let name = string(nameStart..<j).lowercased()
            var attributes: [String: String] = [:]
            while j < bytes.count, bytes[j] != 0x3E {
                if isSpace(bytes[j]) || bytes[j] == 0x2F {
                    j += 1
                    continue
                }
                let attributeStart = j
                while j < bytes.count, !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E, bytes[j] != 0x2F { j += 1 }
                if j == attributeStart {
                    j += 1  // an unexpected byte such as "=": skip it so the scan always advances
                    continue
                }
                let attributeName = string(attributeStart..<j).lowercased()
                while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                var value = ""
                if j < bytes.count, bytes[j] == 0x3D {
                    j += 1
                    while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                    if j < bytes.count, bytes[j] == 0x22 || bytes[j] == 0x27 {
                        let quote = bytes[j]
                        let valueStart = j + 1
                        j = valueStart
                        while j < bytes.count, bytes[j] != quote { j += 1 }
                        value = string(valueStart..<j)
                        j = min(j + 1, bytes.count)
                    } else {
                        let valueStart = j
                        while j < bytes.count, !isSpace(bytes[j]), bytes[j] != 0x3E { j += 1 }
                        value = string(valueStart..<j)
                    }
                }
                if attributes[attributeName] == nil { attributes[attributeName] = decodeEntities(value) }
            }
            tokens.append(isClosing ? .close(name) : .open(name, attributes))
            i = min(j + 1, bytes.count)
            textStart = i
        }
        flushText(upTo: bytes.count)
        return tokens
    }

    /// Replaces `&amp; &lt; &gt; &quot; &#39; &apos;` and numeric `&#NNN;` / `&#xHH;` references. Anything else
    /// that merely looks like a reference is left as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "&" else {
                out.append(scalar)
                i += 1
                continue
            }
            // Look for the closing ";" within a short distance.
            var end = i + 1
            while end < scalars.count, end - i <= 10, scalars[end] != ";" { end += 1 }
            if end < scalars.count, scalars[end] == ";",
               let decoded = entityValue(String(String.UnicodeScalarView(scalars[(i + 1)..<end]))) {
                out.append(decoded)
                i = end + 1
            } else {
                out.append(scalar)
                i += 1
            }
        }
        return String(out)
    }

    private static func entityValue(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard name.hasPrefix("#"), name.count > 1 else { return nil }
        let digits = name.dropFirst()
        let code: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            code = UInt32(digits.dropFirst(), radix: 16)
        } else {
            code = UInt32(digits, radix: 10)
        }
        guard let code else { return nil }
        // NUL and control characters (other than tab, LF, CR) have no place in a title or address.
        if code == 0 || (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) || code == 0x7F {
            return "\u{FFFD}"
        }
        return Unicode.Scalar(code)
    }
}
