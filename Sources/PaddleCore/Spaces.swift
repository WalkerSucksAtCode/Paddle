import Foundation

/// The symbols a space can wear. Spaces are told apart by name and symbol, never by tint alone.
public enum SpaceSymbol: String, CaseIterable, Codable, Sendable {
    case home, work, study, code, music, games, shopping, travel, reading, star

    public var displayName: String {
        switch self {
        case .home: "Home"
        case .work: "Work"
        case .study: "Study"
        case .code: "Code"
        case .music: "Music"
        case .games: "Games"
        case .shopping: "Shopping"
        case .travel: "Travel"
        case .reading: "Reading"
        case .star: "Star"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .home: "house"
        case .work: "briefcase"
        case .study: "book"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .music: "music.note"
        case .games: "gamecontroller"
        case .shopping: "cart"
        case .travel: "airplane"
        case .reading: "newspaper"
        case .star: "star"
        }
    }
}

/// One space of a window: a named set of tabs (with its own pinned tabs and groups). In a `WindowRecord` the active
/// space's own tabs live in the window's `tabs`, `groups` and `selectedIndex`; `tabs` here are for inactive spaces.
public struct SpaceRecord: Codable, Sendable, Equatable {
    /// The name of the one space a window has until the user adds another, and of an older file's only space.
    public static let mainName = "Main"

    public var id: String
    public var name: String
    public var symbol: SpaceSymbol
    /// A `ColorPreset` raw value, or nil for no tint.
    public var tint: String?
    public var tabs: [TabRecord]
    public var selectedIndex: Int
    public var groups: [TabGroupRecord]
    /// The space's split views from before multi view; read and turned into `layouts`, written empty.
    public var splits: [SplitRecord]
    /// The space's multi views. Older files have none.
    public var layouts: [PaneLayout]

    /// The multi views to restore: `layouts`, then each old split record as a layout.
    public var allLayouts: [PaneLayout] { layouts + splits.map(PaneLayout.init(split:)) }

    public init(
        id: String = UUID().uuidString, name: String = SpaceRecord.mainName, symbol: SpaceSymbol = .home, tint: String? = nil,
        tabs: [TabRecord] = [], selectedIndex: Int = 0, groups: [TabGroupRecord] = [], splits: [SplitRecord] = [],
        layouts: [PaneLayout] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.groups = groups
        self.splits = splits
        self.layouts = layouts
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, tint, tabs, selectedIndex, groups, splits, layouts }

    /// Lenient, for hand-edited files: `id` is required; a missing name is "Main", an unknown symbol is Home, an
    /// unknown tint is none, and tabs or groups that don't decode are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? Self.mainName
        symbol = (try? c.decodeIfPresent(SpaceSymbol.self, forKey: .symbol)) ?? .home
        let rawTint = ((try? c.decodeIfPresent(String.self, forKey: .tint)) ?? nil)?.lowercased()
        tint = rawTint.flatMap { ColorPreset(rawValue: $0) }?.rawValue
        tabs = Self.lossy(TabRecord.self, in: c, forKey: .tabs)
        selectedIndex = (try? c.decodeIfPresent(Int.self, forKey: .selectedIndex)) ?? 0
        groups = Self.lossy(TabGroupRecord.self, in: c, forKey: .groups)
        splits = Self.lossy(SplitRecord.self, in: c, forKey: .splits)
        layouts = Self.lossy(PaneLayout.self, in: c, forKey: .layouts)
    }

    private static func lossy<T: Decodable>(_ type: T.Type, in c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([LossySpaceItem<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// An array element that is nil instead of failing the whole array.
struct LossySpaceItem<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension WindowRecord {
    /// Runs `body` on every tab record of the window: its own and those of its inactive spaces.
    mutating func updateTabs(_ body: (inout TabRecord) throws -> Void) rethrows {
        for t in tabs.indices { try body(&tabs[t]) }
        for s in otherSpaces.indices {
            for t in otherSpaces[s].tabs.indices { try body(&otherSpaces[s].tabs[t]) }
        }
    }
}
