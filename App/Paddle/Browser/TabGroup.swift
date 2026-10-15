import Foundation
import PaddleCore

/// A named, coloured run of tabs in one window. Tabs name their group by `Tab.groupID`; `BrowserModel` keeps a
/// group's members adjacent and drops the group when its last tab leaves.
@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: TabGroupColor
    /// Collapsed: the strip shows only the group's label, not its tabs.
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String = "", color: TabGroupColor = .grey, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }

    convenience init?(record: TabGroupRecord) {
        guard let id = UUID(uuidString: record.id) else { return nil }
        self.init(id: id, name: record.name, color: record.color, isCollapsed: record.collapsed)
    }

    var record: TabGroupRecord {
        TabGroupRecord(id: id.uuidString, name: name, color: color, collapsed: isCollapsed)
    }
}
