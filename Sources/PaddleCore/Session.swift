import Foundation

/// Saved browsing session, restored at launch. Tabs come back asleep except the selected one,
/// so restoring 50 tabs costs one web process, not 50.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var windows: [WindowRecord]

    public init(windows: [WindowRecord]) {
        self.windows = windows
    }
}

public struct WindowRecord: Codable, Sendable, Equatable {
    public var tabs: [TabRecord]
    public var selectedIndex: Int
    /// `NSStringFromRect` form of the window frame.
    public var frame: String?
    /// The window's tab groups; tabs name theirs by `TabRecord.groupID`. Files from before groups have none.
    public var groups: [TabGroupRecord]
    /// The window's profile id (`ProfilesFile`); nil is the default profile. Files from before profiles have none.
    public var profile: String?

    public init(tabs: [TabRecord], selectedIndex: Int, frame: String? = nil, groups: [TabGroupRecord] = [], profile: String? = nil) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.frame = frame
        self.groups = groups
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey { case tabs, selectedIndex, frame, groups, profile }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decode([TabRecord].self, forKey: .tabs)
        selectedIndex = try c.decode(Int.self, forKey: .selectedIndex)
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        groups = try c.decodeIfPresent([TabGroupRecord].self, forKey: .groups) ?? []
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? nil
    }
}

public struct TabRecord: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var isPinned: Bool
    /// WebKit's opaque back/forward state (`WKWebView.interactionState`). Held in memory; session.json names a
    /// file in sessions/ instead (`stateFile`). Files from before that kept it inline here, and still load.
    public var interactionState: Data?
    /// The tab's session id, a UUID kept across launches so its state file keeps its name (`SessionStore`).
    public var id: String?
    /// When the tab was last selected or busy; `SessionRecord.cappingStates` keeps history for the most recent.
    public var lastActive: Date?
    /// The tab's state file in sessions/, as `SessionStore.save` wrote it; nil in memory.
    public var stateFile: String?
    /// The title the user gave the tab (Rename Tab…); it replaces the page's title in the strip.
    public var customTitle: String?
    /// The id of the `TabGroupRecord` this tab belongs to.
    public var groupID: String?

    public init(
        url: String, title: String, isPinned: Bool = false, interactionState: Data? = nil, id: String? = nil,
        lastActive: Date? = nil, stateFile: String? = nil, customTitle: String? = nil, groupID: String? = nil
    ) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.interactionState = interactionState
        self.id = id
        self.lastActive = lastActive
        self.stateFile = stateFile
        self.customTitle = customTitle
        self.groupID = groupID
    }
}
