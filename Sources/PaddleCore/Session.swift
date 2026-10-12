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

    public init(tabs: [TabRecord], selectedIndex: Int, frame: String? = nil) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.frame = frame
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

    public init(
        url: String, title: String, isPinned: Bool = false, interactionState: Data? = nil, id: String? = nil,
        lastActive: Date? = nil, stateFile: String? = nil
    ) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.interactionState = interactionState
        self.id = id
        self.lastActive = lastActive
        self.stateFile = stateFile
    }
}
