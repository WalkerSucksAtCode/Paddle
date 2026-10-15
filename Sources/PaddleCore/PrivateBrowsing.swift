import Foundation

extension SessionRecord {
    /// What goes into session.json: private windows never do, and neither do windows with nothing left to save.
    public static func saving<Window>(
        _ windows: [Window], isPrivate: (Window) -> Bool, record: (Window) -> WindowRecord
    ) -> SessionRecord {
        SessionRecord(windows: windows.filter { !isPrivate($0) }.map(record).filter { !$0.allTabRecords.isEmpty })
    }
}

extension WindowRecord {
    /// A window's record with only the tabs worth restoring (`isSaved`). When the selected tab isn't saved, the
    /// nearest saved tab before it is selected instead (or the first). Only groups with a saved tab are kept.
    public static func saving<Tab>(
        _ tabs: [Tab], selected: (Tab) -> Bool, isSaved: (Tab) -> Bool, record: (Tab) -> TabRecord, frame: String?,
        groups: [TabGroupRecord] = [], profile: String? = nil, space: SpaceRecord? = nil, otherSpaces: [SpaceRecord] = [],
        spaceIndex: Int? = nil, splits: [SplitRecord] = []
    ) -> WindowRecord {
        var records: [TabRecord] = []
        var selectedIndex = 0
        for tab in tabs {
            if selected(tab) { selectedIndex = max(records.count - (isSaved(tab) ? 0 : 1), 0) }
            if isSaved(tab) { records.append(record(tab)) }
        }
        let used = Set(records.compactMap(\.groupID))
        return WindowRecord(
            tabs: records, selectedIndex: selectedIndex, frame: frame, groups: groups.filter { used.contains($0.id) }, profile: profile,
            space: space, otherSpaces: otherSpaces, spaceIndex: spaceIndex, splits: splits
        )
    }
}
