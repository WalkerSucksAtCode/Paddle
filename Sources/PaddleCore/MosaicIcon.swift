import Foundation

/// The icon a Mosaic wears in the tab strip, sidebar and Mosaic bar: an SF Symbol, saved by its name.
public struct MosaicIcon: Equatable, Hashable, Sendable {
    public var name: String

    /// Nil for a name with characters symbol names never have.
    public init?(_ name: String) {
        guard !name.isEmpty, name.count <= 80, name.first != ".", name.last != ".",
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." })
        else { return nil }
        self.name = name
    }
}

/// The SF Symbols the icon picker offers, with their categories and search words. Read from the system's own symbol
/// catalog (CoreGlyphs' plists: the order, categories and search keywords the SF Symbols app uses); `fallback`
/// when those can't be read. Localized variants (`character.ar`, `character.ja`) are left out.
public struct SymbolCatalog: Sendable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var categories: [String]
        /// Lowercased: the name's own words and the catalog's keywords.
        public var words: [String]
    }

    public var entries: [Entry]
    /// Category keys in the catalog's order, "all" and "whatsnew" left out.
    public var categories: [String]

    public init(entries: [Entry], categories: [String]) {
        self.entries = entries
        self.categories = categories
    }

    /// Where macOS keeps the catalog.
    public static let systemFolder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// The catalog in `folder` (`symbol_order.plist`, `symbol_categories.plist`, `symbol_search.plist`,
    /// `categories.plist`); nil when the order list can't be read. Missing categories or keywords leave those empty.
    public static func load(from folder: URL = systemFolder) -> SymbolCatalog? {
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        guard let order = plist("symbol_order.plist") as? [String], !order.isEmpty else { return nil }
        let categoriesByName = plist("symbol_categories.plist") as? [String: [String]] ?? [:]
        let keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        let categoryKeys = (plist("categories.plist") as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        return SymbolCatalog(order: order, categories: categoriesByName, keywords: keywords, categoryKeys: categoryKeys)
    }

    init(order: [String], categories categoriesByName: [String: [String]], keywords: [String: [String]], categoryKeys: [String]) {
        var seen = Set<String>()
        entries = order.compactMap { name in
            guard !Self.isLocalizedVariant(name), seen.insert(name).inserted else { return nil }
            let own = name.split(separator: ".").map(String.init)
            let words = own + (keywords[name] ?? []).map { $0.lowercased() }
            return Entry(name: name, categories: categoriesByName[name] ?? [], words: words)
        }
        let used = Set(entries.flatMap(\.categories))
        categories = categoryKeys.filter { $0 != "all" && $0 != "whatsnew" && used.contains($0) }
    }

    /// `character.ar`, `textformat.size.zh`, `0.circle.hi`: a script variant of another symbol.
    static func isLocalizedVariant(_ name: String) -> Bool {
        guard let last = name.split(separator: ".").last, name.contains(".") else { return false }
        return localeSuffixes.contains(String(last))
    }

    private static let localeSuffixes: Set<String> = [
        "ar", "he", "hi", "ja", "ko", "th", "zh", "zh.traditional", "rtl", "bn", "gu", "kn", "ml", "mr", "or", "pa", "ta",
        "te", "my", "km", "el", "ru", "sat", "mni", "si", "ur", "fa", "ne", "as", "ks", "sd", "tr", "traditional",
    ]

    /// The names matching `query` in `category` (nil: all), best first: whole name, then a name starting with the
    /// query, then a word of the name, then a keyword; within each, the catalog's order. Every word of a
    /// multi-word query must match something. An empty query lists the category in order; with no category, the
    /// `suggested` symbols come first (the catalog itself starts with numbered circles).
    public func search(_ query: String, category: String? = nil) -> [String] {
        let pool = category.map { key in entries.filter { $0.categories.contains(key) } } ?? entries
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else {
            guard category == nil else { return pool.map(\.name) }
            let known = Set(pool.map(\.name))
            let first = Self.suggested.filter(known.contains)
            let lead = Set(first)
            return first + pool.map(\.name).filter { !lead.contains($0) }
        }
        let whole = terms.joined(separator: ".")
        var ranked: [(rank: Int, index: Int, name: String)] = []
        for (index, entry) in pool.enumerated() {
            let name = entry.name
            let rank: Int
            if name == whole {
                rank = 0
            } else if name.hasPrefix(whole) {
                rank = 1
            } else if terms.allSatisfy({ term in entry.words.prefix(name.split(separator: ".").count).contains { $0.hasPrefix(term) } }) {
                rank = 2
            } else if terms.allSatisfy({ term in entry.words.contains { $0.hasPrefix(term) } }) {
                rank = 3
            } else {
                continue
            }
            ranked.append((rank, index, name))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.name)
    }

    /// The symbols the picker shows first, and all it has when the system catalog can't be read (`fallback`).
    public static let suggested = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "globe", "house.fill", "briefcase.fill",
        "book.fill", "graduationcap.fill", "newspaper.fill", "cart.fill", "bag.fill", "creditcard.fill", "gamecontroller.fill",
        "music.note", "film.fill", "tv.fill", "camera.fill", "photo.fill", "paintbrush.fill", "pencil", "hammer.fill",
        "wrench.and.screwdriver.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "cpu.fill", "chart.bar.fill",
        "chart.line.uptrend.xyaxis", "dollarsign.circle.fill", "bubble.left.and.bubble.right.fill", "envelope.fill",
        "phone.fill", "person.fill", "person.2.fill", "calendar", "clock.fill", "airplane", "car.fill", "map.fill",
        "sun.max.fill", "moon.fill", "cloud.fill", "snowflake", "pawprint.fill", "fork.knife", "cup.and.saucer.fill",
        "sportscourt.fill", "figure.run", "heart.text.square.fill", "cross.case.fill", "lock.fill", "key.fill", "flag.fill",
        "bell.fill", "tag.fill", "bookmark.fill", "lightbulb.fill", "puzzlepiece.fill", "sparkles", "crown.fill", "gift.fill",
        "square.grid.2x2.fill", "rectangle.split.2x2.fill",
    ]

    /// `suggested` alone, for when the system catalog can't be read.
    public static let fallback = SymbolCatalog(
        entries: suggested.map { Entry(name: $0, categories: [], words: $0.split(separator: ".").map(String.init)) }, categories: []
    )
}
