import Foundation

extension SessionRecord {
    /// What goes into session.json: private windows never do, and neither do windows with nothing left to save.
    public static func saving<Window>(
        _ windows: [Window], isPrivate: (Window) -> Bool, record: (Window) -> WindowRecord
    ) -> SessionRecord {
        SessionRecord(windows: windows.filter { !isPrivate($0) }.map(record).filter { !$0.tabs.isEmpty })
    }
}

extension WindowRecord {
    /// A window's record with only the tabs worth restoring (`isSaved`). When the selected tab isn't saved, the
    /// nearest saved tab before it is selected instead (or the first).
    public static func saving<Tab>(
        _ tabs: [Tab], selected: (Tab) -> Bool, isSaved: (Tab) -> Bool, record: (Tab) -> TabRecord, frame: String?
    ) -> WindowRecord {
        var records: [TabRecord] = []
        var selectedIndex = 0
        for tab in tabs {
            if selected(tab) { selectedIndex = max(records.count - (isSaved(tab) ? 0 : 1), 0) }
            if isSaved(tab) { records.append(record(tab)) }
        }
        return WindowRecord(tabs: records, selectedIndex: selectedIndex, frame: frame)
    }
}
