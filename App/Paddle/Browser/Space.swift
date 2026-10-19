import Foundation
import PaddleCore

/// One space of a window: a named set of tabs. `BrowserModel` keeps the active space's tabs in its own `tabs` and
/// the others in stashes; this object holds only the name, symbol and tint.
@Observable
final class Space: Identifiable {
    let id: String
    var name: String
    var symbol: SpaceSymbol
    /// A tint for the window's strip and toolbar while the space is active; nil for none.
    var tint: ColorPreset?

    init(id: String = UUID().uuidString, name: String = SpaceRecord.mainName, symbol: SpaceSymbol = .home, tint: ColorPreset? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    convenience init(record: SpaceRecord) {
        self.init(
            id: record.id, name: record.name.isEmpty ? SpaceRecord.mainName : record.name, symbol: record.symbol,
            tint: record.tint.flatMap(ColorPreset.init(rawValue:))
        )
    }

    func record(tabs: [TabRecord] = [], selectedIndex: Int = 0, groups: [TabGroupRecord] = [], layouts: [PaneLayout] = []) -> SpaceRecord {
        SpaceRecord(
            id: id, name: name, symbol: symbol, tint: tint?.rawValue, tabs: tabs, selectedIndex: selectedIndex, groups: groups,
            layouts: layouts
        )
    }
}
